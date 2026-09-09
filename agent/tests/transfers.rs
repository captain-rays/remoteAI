use std::fs;
use std::path::Path;

use remote_ai_agent::crypto::CryptoBox;
use remote_ai_agent::transfers::{ConflictPolicy, TransferError, TransferManager};
use sha2::{Digest, Sha256};
use tempfile::tempdir;

#[tokio::test]
async fn upload_verifies_hash_and_atomically_finishes() {
    let root = tempdir().unwrap();
    let manager = TransferManager::new(root.path());
    let content = b"chunk-onechunk-two";
    let digest = format!("{:x}", Sha256::digest(content));
    let transfer = manager
        .create_upload(Path::new("target.txt"), Some(digest), None)
        .await
        .unwrap();
    manager
        .write_chunk(&transfer.id, 0, b"chunk-one")
        .await
        .unwrap();
    manager
        .write_chunk(&transfer.id, 9, b"chunk-two")
        .await
        .unwrap();
    manager.finish(&transfer.id).await.unwrap();
    assert_eq!(fs::read(root.path().join("target.txt")).unwrap(), content);
}

#[tokio::test]
async fn conflicts_cancel_resume_and_range_download_are_explicit() {
    let root = tempdir().unwrap();
    fs::write(root.path().join("same.txt"), "old").unwrap();
    let manager = TransferManager::new(root.path());
    assert!(matches!(
        manager
            .create_upload(Path::new("same.txt"), None, None)
            .await,
        Err(TransferError::Conflict { .. })
    ));
    let keep = manager
        .create_upload(Path::new("same.txt"), None, Some(ConflictPolicy::KeepBoth))
        .await
        .unwrap();
    assert!(keep.destination.ends_with("same (1).txt"));
    manager.write_chunk(&keep.id, 0, b"new").await.unwrap();
    manager.cancel(&keep.id).await.unwrap();
    assert_eq!(fs::read(root.path().join("same.txt")).unwrap(), b"old");

    let overwrite = manager
        .create_upload(Path::new("same.txt"), None, Some(ConflictPolicy::Overwrite))
        .await
        .unwrap();
    manager
        .write_chunk(&overwrite.id, 0, b"replacement")
        .await
        .unwrap();
    manager.finish(&overwrite.id).await.unwrap();
    assert_eq!(
        fs::read(root.path().join("same.txt")).unwrap(),
        b"replacement"
    );

    fs::write(root.path().join("download.txt"), "0123456789").unwrap();
    assert_eq!(
        manager
            .read_range(Path::new("download.txt"), 2, 6)
            .await
            .unwrap(),
        b"2345"
    );
}

#[tokio::test]
async fn encrypted_chunks_are_authenticated_before_writing() {
    let root = tempdir().unwrap();
    let manager = TransferManager::new(root.path());
    let transfer = manager
        .create_upload(Path::new("encrypted.txt"), None, None)
        .await
        .unwrap();
    let crypto = CryptoBox::new([3; 32], *b"CHNK");
    let mut receiver = crypto.receiver();
    let aad = b"transfer-1";
    let ciphertext = crypto.encrypt(1, aad, b"secret chunk").unwrap();
    manager
        .write_encrypted_chunk(&transfer.id, 0, 1, aad, &ciphertext, &mut receiver)
        .await
        .unwrap();
    manager.finish(&transfer.id).await.unwrap();
    assert_eq!(
        fs::read(root.path().join("encrypted.txt")).unwrap(),
        b"secret chunk"
    );
}

#[cfg(unix)]
#[tokio::test]
async fn accepts_root_absolute_upload_and_rejects_symlink_escape() {
    let parent = tempdir().unwrap();
    let root = parent.path().join("root");
    let sibling = parent.path().join("sibling");
    fs::create_dir(&root).unwrap();
    fs::create_dir(&sibling).unwrap();
    fs::write(sibling.join("outside.txt"), "outside").unwrap();
    std::os::unix::fs::symlink(&sibling, root.join("link")).unwrap();
    let manager = TransferManager::new(&root);
    let absolute = root.canonicalize().unwrap().join("inside.txt");
    let transfer = manager.create_upload(&absolute, None, None).await.unwrap();
    manager
        .write_chunk(&transfer.id, 0, b"inside")
        .await
        .unwrap();
    manager.finish(&transfer.id).await.unwrap();
    assert_eq!(fs::read(&absolute).unwrap(), b"inside");
    assert!(matches!(
        manager
            .create_upload(Path::new("link/escape.txt"), None, None)
            .await,
        Err(TransferError::PathOutsideRoot)
    ));
    assert!(matches!(
        manager
            .create_upload(&parent.path().join("outside.txt"), None, None)
            .await,
        Err(TransferError::PathOutsideRoot)
    ));
}

/// The phone attaches a photo to a message, and the directory it belongs in
/// does not exist yet: a dated inbox, or a project's uploads folder on the
/// first file. The parents are created on the way, the same as any tool that
/// writes a path.
#[tokio::test]
async fn an_upload_creates_the_directories_it_needs() {
    let root = tempdir().unwrap();
    let manager = TransferManager::new(root.path());
    let destination = root
        .path()
        .canonicalize()
        .unwrap()
        .join("Library/Application Support/RemoteAI/uploads/2026-09-09/photo.jpeg");

    let transfer = manager
        .create_upload(&destination, None, None)
        .await
        .unwrap();
    manager.write_chunk(&transfer.id, 0, b"jpeg").await.unwrap();
    manager.finish(&transfer.id).await.unwrap();

    assert_eq!(fs::read(&destination).unwrap(), b"jpeg");
}

/// Creating the parents must not become a way out of the root: a symlink
/// pointing outside is still refused, and nothing is created behind it.
#[tokio::test]
async fn creating_directories_cannot_escape_the_root() {
    let parent = tempdir().unwrap();
    let root = parent.path().join("root");
    let sibling = parent.path().join("sibling");
    fs::create_dir(&root).unwrap();
    fs::create_dir(&sibling).unwrap();
    std::os::unix::fs::symlink(&sibling, root.join("link")).unwrap();
    let manager = TransferManager::new(&root);

    assert!(matches!(
        manager
            .create_upload(Path::new("link/deep/escape.txt"), None, None)
            .await,
        Err(TransferError::PathOutsideRoot)
    ));
    assert!(
        !sibling.join("deep").exists(),
        "a refused upload created directories outside the root"
    );
}
