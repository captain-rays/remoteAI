use std::path::PathBuf;

use chrono::{TimeZone, Utc};
use remote_ai_agent::catalog::build_catalog;
use remote_ai_agent::protocol::{ConversationKind, ConversationSummary, ProviderId};

fn conversation(
    provider: ProviderId,
    id: &str,
    kind: ConversationKind,
    path: Option<&str>,
    seconds: i64,
) -> ConversationSummary {
    ConversationSummary {
        id: id.into(),
        provider,
        kind,
        title: id.into(),
        project_id: None,
        project_path: path.map(str::to_owned),
        updated_at: Utc.timestamp_opt(seconds, 0).single().unwrap(),
        status: "idle".into(),
        write_state: None,
        write_block_code: None,
    }
}

#[test]
fn catalog_keeps_provider_daily_and_project_boundaries() {
    let home = PathBuf::from("/Users/test");
    let sessions = vec![
        conversation(ProviderId::Codex, "daily", ConversationKind::Daily, None, 3),
        conversation(
            ProviderId::Codex,
            "project",
            ConversationKind::Project,
            Some("/tmp/project"),
            2,
        ),
        conversation(
            ProviderId::Claude,
            "other-provider",
            ConversationKind::Daily,
            None,
            4,
        ),
    ];
    let catalog = build_catalog(ProviderId::Codex, &home, sessions).unwrap();
    assert_eq!(catalog.conversations.len(), 2);
    assert!(
        catalog
            .conversations
            .iter()
            .all(|conversation| conversation.provider == ProviderId::Codex)
    );
    assert_eq!(catalog.conversations[0].kind, ConversationKind::Daily);
    assert_eq!(catalog.projects.len(), 1);
    assert_eq!(catalog.projects[0].canonical_path, "/tmp/project");
}

#[test]
fn same_path_has_distinct_provider_project_ids_and_missing_paths_stay_visible() {
    let home = PathBuf::from("/Users/test");
    let path = "/definitely/missing/project";
    let codex = build_catalog(
        ProviderId::Codex,
        &home,
        vec![conversation(
            ProviderId::Codex,
            "c",
            ConversationKind::Project,
            Some(path),
            1,
        )],
    )
    .unwrap();
    let claude = build_catalog(
        ProviderId::Claude,
        &home,
        vec![conversation(
            ProviderId::Claude,
            "a",
            ConversationKind::Project,
            Some(path),
            1,
        )],
    )
    .unwrap();
    assert_ne!(codex.projects[0].id, claude.projects[0].id);
    assert_eq!(codex.projects[0].display_path, path);
    assert!(!codex.projects[0].available);
}

#[test]
fn sorting_is_most_recent_first_and_stable_for_ties() {
    let catalog = build_catalog(
        ProviderId::Codex,
        PathBuf::from("/Users/test"),
        vec![
            conversation(ProviderId::Codex, "b", ConversationKind::Daily, None, 1),
            conversation(ProviderId::Codex, "a", ConversationKind::Daily, None, 2),
            conversation(ProviderId::Codex, "c", ConversationKind::Daily, None, 2),
        ],
    )
    .unwrap();
    assert_eq!(
        catalog
            .conversations
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        vec!["a", "c", "b"]
    );
}
