use remote_ai_agent::protocol::{
    ApprovalRequest, Catalog, ConversationEvent, EventEnvelope, FileEntry, ProtocolError,
    ProviderId, ProviderStatus, validate_protocol_version,
};

#[test]
fn decodes_shared_protocol_fixtures() {
    let status: ProviderStatus = serde_json::from_str(include_str!(
        "../../protocol/v1/fixtures/provider-status.json"
    ))
    .unwrap();
    assert_eq!(status.provider, ProviderId::Codex);
    assert!(status.available);

    let catalog: Catalog =
        serde_json::from_str(include_str!("../../protocol/v1/fixtures/catalog.json")).unwrap();
    assert_eq!(catalog.projects.len(), 1);
    assert_eq!(catalog.conversations.len(), 1);

    let approval: ApprovalRequest = serde_json::from_str(include_str!(
        "../../protocol/v1/fixtures/approval-request.json"
    ))
    .unwrap();
    assert_eq!(approval.provider, ProviderId::Claude);

    let entry: FileEntry =
        serde_json::from_str(include_str!("../../protocol/v1/fixtures/file-entry.json")).unwrap();
    assert_eq!(entry.name, "README.md");
}

#[test]
fn unknown_events_are_explicitly_unsupported() {
    let lines: Vec<_> = include_str!("../../protocol/v1/fixtures/conversation-events.jsonl")
        .lines()
        .map(|line| serde_json::from_str::<EventEnvelope>(line).unwrap())
        .collect();
    assert!(matches!(
        &lines[0].event,
        ConversationEvent::Delta { text } if text == "hello"
    ));
    assert!(matches!(
        &lines[1].event,
        ConversationEvent::Unsupported { raw_type, .. } if raw_type == "future.event"
    ));
}

#[test]
fn rejects_unsupported_major_version_with_structured_error() {
    assert_eq!(
        validate_protocol_version(2),
        Err(ProtocolError::UpgradeRequired {
            supported: 1,
            received: 2,
        })
    );
}
