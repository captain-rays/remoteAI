use std::fs;
use std::io::{self, Read};
use std::path::{Component, Path, PathBuf};

use chrono::{DateTime, Utc};
use thiserror::Error;

use crate::protocol::{FileEntry, FileKind};

const MAX_PREVIEW_BYTES: usize = 1_048_576;

#[derive(Debug, Error)]
pub enum FilesError {
    #[error("path is outside the configured root")]
    PathOutsideRoot,
    #[error("path does not exist")]
    NotFound,
    #[error("path is not a directory")]
    NotDirectory,
    #[error("permission denied")]
    PermissionDenied,
    #[error("filesystem error: {0}")]
    Io(#[from] io::Error),
}

#[derive(Debug, Clone)]
pub struct FileService {
    root: PathBuf,
}

impl FileService {
    pub fn new(root: impl AsRef<Path>) -> Self {
        Self {
            root: root
                .as_ref()
                .canonicalize()
                .unwrap_or_else(|_| root.as_ref().to_owned()),
        }
    }

    pub fn list(
        &self,
        relative: &Path,
        include_sensitive: bool,
    ) -> Result<Vec<FileEntry>, FilesError> {
        let directory = self.resolve_existing(relative)?;
        let metadata = fs::symlink_metadata(&directory)?;
        if !metadata.is_dir() {
            return Err(FilesError::NotDirectory);
        }
        let mut entries = Vec::new();
        for item in fs::read_dir(directory)? {
            let item = item?;
            let path = item.path();
            let entry = self.entry(&path)?;
            if entry.hidden && !include_sensitive {
                continue;
            }
            entries.push(entry);
        }
        entries.sort_by(|left, right| left.name.cmp(&right.name));
        Ok(entries)
    }

    pub fn metadata(&self, relative: &Path) -> Result<Option<FileEntry>, FilesError> {
        let path = match self.resolve_existing(relative) {
            Ok(path) => path,
            Err(FilesError::NotFound) => return Ok(None),
            Err(error) => return Err(error),
        };
        Ok(Some(self.entry(&path)?))
    }

    pub fn preview(&self, relative: &Path, max_bytes: usize) -> Result<Vec<u8>, FilesError> {
        let path = self.resolve_existing(relative)?;
        let metadata = fs::symlink_metadata(&path)?;
        if !metadata.is_file() {
            return Err(FilesError::NotFound);
        }
        let mut file = fs::File::open(path)?;
        let mut buffer = vec![0; max_bytes.min(MAX_PREVIEW_BYTES)];
        let read = file.read(&mut buffer)?;
        buffer.truncate(read);
        Ok(buffer)
    }

    fn resolve_existing(&self, relative: &Path) -> Result<PathBuf, FilesError> {
        let candidate = if relative.is_absolute() {
            relative.to_owned()
        } else {
            self.root.join(relative)
        };
        let joined = normalize_path(&candidate);
        if !joined.starts_with(&self.root) {
            return Err(FilesError::PathOutsideRoot);
        }
        let canonical = joined.canonicalize().map_err(|error| {
            if error.kind() == io::ErrorKind::NotFound {
                FilesError::NotFound
            } else if error.kind() == io::ErrorKind::PermissionDenied {
                FilesError::PermissionDenied
            } else {
                FilesError::Io(error)
            }
        })?;
        if !canonical.starts_with(&self.root) {
            return Err(FilesError::PathOutsideRoot);
        }
        Ok(canonical)
    }

    fn entry(&self, path: &Path) -> Result<FileEntry, FilesError> {
        let metadata = fs::symlink_metadata(path)?;
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default()
            .to_owned();
        let kind = if metadata.file_type().is_symlink() {
            FileKind::Symlink
        } else if metadata.is_dir() {
            FileKind::Directory
        } else {
            FileKind::File
        };
        let readable = match fs::File::open(path) {
            Ok(_) => true,
            Err(error) if error.kind() == io::ErrorKind::PermissionDenied => false,
            Err(_) => false,
        };
        Ok(FileEntry {
            path: path.to_string_lossy().into_owned(),
            name: name.clone(),
            kind,
            size: metadata.is_file().then_some(metadata.len()),
            modified_at: metadata.modified().ok().map(DateTime::<Utc>::from),
            hidden: name.starts_with('.'),
            readable,
            sensitive: is_sensitive(path) || name.starts_with('.'),
        })
    }
}

fn normalize_path(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

fn is_sensitive(path: &Path) -> bool {
    path.components().any(|component| match component {
        Component::Normal(value) => matches!(
            value.to_str(),
            Some(".ssh" | ".codex" | ".claude" | "Keychains")
        ),
        _ => false,
    })
}
