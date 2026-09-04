use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use remote_ai_agent::files::{FileService, FilesError};
use tempfile::tempdir;

#[test]
fn lists_metadata_and_bounded_previews_without_path_escape() {
    let root = tempdir().unwrap();
    fs::create_dir(root.path().join("folder")).unwrap();
    fs::write(root.path().join("visible.txt"), "hello").unwrap();
    fs::write(root.path().join(".hidden"), "secret").unwrap();
    let service = FileService::new(root.path());

    let entries = service.list(Path::new("."), false).unwrap();
    assert!(
        entries
            .iter()
            .any(|entry| entry.name == "visible.txt" && !entry.hidden)
    );
    assert!(!entries.iter().any(|entry| entry.name == ".hidden"));
    assert_eq!(
        service.preview(Path::new("visible.txt"), 10).unwrap(),
        b"hello"
    );
    assert!(matches!(
        service.preview(Path::new("../../etc/passwd"), 10),
        Err(FilesError::PathOutsideRoot)
    ));
}

#[test]
fn hidden_and_sensitive_entries_require_explicit_opt_in_and_permissions_are_checked() {
    let root = tempdir().unwrap();
    fs::create_dir(root.path().join(".sensitive")).unwrap();
    fs::write(root.path().join(".sensitive/token"), "do-not-show").unwrap();
    fs::write(root.path().join("unreadable"), "nope").unwrap();
    fs::set_permissions(
        root.path().join("unreadable"),
        fs::Permissions::from_mode(0o000),
    )
    .unwrap();
    let service = FileService::new(root.path());

    let normal = service.list(Path::new("."), false).unwrap();
    assert!(!normal.iter().any(|entry| entry.name == ".sensitive"));
    let explicit = service.list(Path::new("."), true).unwrap();
    assert!(
        explicit
            .iter()
            .any(|entry| entry.name == ".sensitive" && entry.sensitive)
    );
    assert!(service.metadata(Path::new("unreadable")).unwrap().is_some());
}
