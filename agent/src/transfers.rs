use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{self, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use sha2::{Digest, Sha256};
use thiserror::Error;
use tokio::sync::Mutex;
use uuid::Uuid;

use crate::crypto::CryptoReceiver;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConflictPolicy {
    KeepBoth,
    Overwrite,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum TransferError {
    #[error("destination already exists; explicit conflict policy is required")]
    Conflict {
        destination: String,
        existing_size: u64,
    },
    #[error("transfer is unknown")]
    UnknownTransfer,
    #[error("chunk offset does not match resumable transfer")]
    InvalidOffset,
    #[error("sha-256 does not match expected digest")]
    HashMismatch,
    #[error("encrypted chunk authentication failed")]
    Authentication,
    #[error("path is outside transfer root")]
    PathOutsideRoot,
    #[error("filesystem error: {0}")]
    Io(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadTransfer {
    pub id: String,
    pub destination: PathBuf,
}

#[derive(Debug)]
struct PendingUpload {
    destination: PathBuf,
    temporary: PathBuf,
    expected_sha256: Option<String>,
}

#[derive(Clone, Debug)]
pub struct TransferManager {
    root: PathBuf,
    pending: Arc<Mutex<HashMap<String, PendingUpload>>>,
}

impl TransferManager {
    pub fn new(root: impl AsRef<Path>) -> Self {
        Self {
            root: root
                .as_ref()
                .canonicalize()
                .unwrap_or_else(|_| root.as_ref().to_owned()),
            pending: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn create_upload(
        &self,
        destination: &Path,
        expected_sha256: Option<String>,
        policy: Option<ConflictPolicy>,
    ) -> Result<UploadTransfer, TransferError> {
        let destination = self.prepare_destination(destination)?;
        let destination = if destination.exists() {
            let existing_size = fs::metadata(&destination).map_err(io_error)?.len();
            match policy {
                None => {
                    return Err(TransferError::Conflict {
                        destination: destination.display().to_string(),
                        existing_size,
                    });
                }
                Some(ConflictPolicy::KeepBoth) => unique_destination(&destination),
                Some(ConflictPolicy::Overwrite) => destination,
            }
        } else {
            destination
        };
        let id = Uuid::new_v4().to_string();
        let temporary = destination.with_file_name(format!(".{}.remoteai-part", id));
        if let Some(parent) = temporary.parent() {
            fs::create_dir_all(parent).map_err(io_error)?;
        }
        OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .map_err(io_error)?;
        self.pending.lock().await.insert(
            id.clone(),
            PendingUpload {
                destination: destination.clone(),
                temporary,
                expected_sha256,
            },
        );
        Ok(UploadTransfer { id, destination })
    }

    pub async fn write_chunk(
        &self,
        id: &str,
        offset: u64,
        bytes: &[u8],
    ) -> Result<(), TransferError> {
        let pending = self.pending.lock().await;
        let upload = pending.get(id).ok_or(TransferError::UnknownTransfer)?;
        let mut file = OpenOptions::new()
            .write(true)
            .open(&upload.temporary)
            .map_err(io_error)?;
        let length = file.metadata().map_err(io_error)?.len();
        if offset > length {
            return Err(TransferError::InvalidOffset);
        }
        file.seek(SeekFrom::Start(offset)).map_err(io_error)?;
        file.write_all(bytes).map_err(io_error)?;
        file.flush().map_err(io_error)
    }

    pub async fn write_encrypted_chunk(
        &self,
        id: &str,
        offset: u64,
        counter: u64,
        associated_data: &[u8],
        ciphertext: &[u8],
        receiver: &mut CryptoReceiver,
    ) -> Result<(), TransferError> {
        let plaintext = receiver
            .decrypt(counter, associated_data, ciphertext)
            .map_err(|_| TransferError::Authentication)?;
        self.write_chunk(id, offset, &plaintext).await
    }

    pub async fn finish(&self, id: &str) -> Result<(), TransferError> {
        let mut pending = self.pending.lock().await;
        let upload = pending.remove(id).ok_or(TransferError::UnknownTransfer)?;
        if let Some(expected) = upload.expected_sha256 {
            let bytes = fs::read(&upload.temporary).map_err(io_error)?;
            if format!("{:x}", Sha256::digest(bytes)) != expected {
                let _ = fs::remove_file(upload.temporary);
                return Err(TransferError::HashMismatch);
            }
        }
        fs::rename(&upload.temporary, &upload.destination).map_err(io_error)
    }

    pub async fn cancel(&self, id: &str) -> Result<(), TransferError> {
        let upload = self
            .pending
            .lock()
            .await
            .remove(id)
            .ok_or(TransferError::UnknownTransfer)?;
        fs::remove_file(upload.temporary).map_err(io_error)
    }

    pub async fn read_range(
        &self,
        path: &Path,
        start: u64,
        end: u64,
    ) -> Result<Vec<u8>, TransferError> {
        let path = self.resolve_existing(path)?;
        if end < start {
            return Err(TransferError::InvalidOffset);
        }
        let bytes = fs::read(path).map_err(io_error)?;
        let start = usize::try_from(start).map_err(|_| TransferError::InvalidOffset)?;
        let end = usize::try_from(end).map_err(|_| TransferError::InvalidOffset)?;
        if start > bytes.len() {
            return Ok(Vec::new());
        }
        Ok(bytes[start..end.min(bytes.len())].to_vec())
    }

    /// Resolve an upload's destination, creating the directories it needs.
    ///
    /// A phone attaching a file names a directory that often does not exist
    /// yet — a dated inbox, or a project's uploads folder on the first file.
    /// Refusing those would mean asking the reader to go and make the folder
    /// by hand before they can send a photo.
    fn prepare_destination(&self, relative: &Path) -> Result<PathBuf, TransferError> {
        let candidate = if relative.is_absolute() {
            relative.to_owned()
        } else {
            self.root.join(relative)
        };
        let path = normalize_path(&candidate);
        if !path.starts_with(&self.root) {
            return Err(TransferError::PathOutsideRoot);
        }
        let parent = path.parent().ok_or(TransferError::PathOutsideRoot)?;
        if !parent.is_dir() {
            // Creating them must not become a way out of the root: the
            // deepest directory that does exist has to be inside it, or a
            // symlink could put new directories anywhere on the Mac.
            let anchor = parent
                .ancestors()
                .find(|candidate| candidate.is_dir())
                .ok_or(TransferError::PathOutsideRoot)?;
            if !anchor
                .canonicalize()
                .map_err(io_error)?
                .starts_with(&self.root)
            {
                return Err(TransferError::PathOutsideRoot);
            }
            fs::create_dir_all(parent).map_err(io_error)?;
        }
        let canonical_parent = parent.canonicalize().map_err(io_error)?;
        if !canonical_parent.starts_with(&self.root) {
            return Err(TransferError::PathOutsideRoot);
        }
        Ok(canonical_parent.join(path.file_name().ok_or(TransferError::PathOutsideRoot)?))
    }

    fn resolve_existing(&self, relative: &Path) -> Result<PathBuf, TransferError> {
        let candidate = if relative.is_absolute() {
            relative.to_owned()
        } else {
            self.root.join(relative)
        };
        let path = normalize_path(&candidate);
        if !path.starts_with(&self.root) {
            return Err(TransferError::PathOutsideRoot);
        }
        let canonical = path.canonicalize().map_err(io_error)?;
        if canonical.starts_with(&self.root) {
            Ok(canonical)
        } else {
            Err(TransferError::PathOutsideRoot)
        }
    }
}

fn normalize_path(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

fn unique_destination(destination: &Path) -> PathBuf {
    let stem = destination
        .file_stem()
        .and_then(|name| name.to_str())
        .unwrap_or("file");
    let extension = destination.extension().and_then(|name| name.to_str());
    for index in 1.. {
        let name = match extension {
            Some(extension) => format!("{stem} ({index}).{extension}"),
            None => format!("{stem} ({index})"),
        };
        let candidate = destination.with_file_name(name);
        if !candidate.exists() {
            return candidate;
        }
    }
    unreachable!()
}

fn io_error(error: io::Error) -> TransferError {
    TransferError::Io(error.to_string())
}
