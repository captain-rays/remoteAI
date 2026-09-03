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
