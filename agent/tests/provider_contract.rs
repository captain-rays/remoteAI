use std::path::PathBuf;

use remote_ai_agent::adapters::mock::MockAdapter;
use remote_ai_agent::adapters::{ConversationPage, ProviderAdapter};
use remote_ai_agent::protocol::{
    ApprovalDecision, ConversationEvent, ConversationKind, ProviderId,
};

async fn exercise_contract(adapter: &dyn ProviderAdapter) {
    assert!(adapter.status().await.available);
    assert!(adapter.list_conversations().await.unwrap().is_empty());

    let id = adapter
        .start(
            ConversationKind::Project,
            Some(PathBuf::from("/tmp/fixture-project")),
        )
        .await
        .unwrap();
    adapter.resume(&id).await.unwrap();
    let page: ConversationPage = adapter.load_conversation(&id, None).await.unwrap();
    assert_eq!(page.conversation_id, id);

    let mut events = adapter.subscribe();
    adapter
        .send(&id, "hello".into(), vec![PathBuf::from("README.md")])
        .await
        .unwrap();

    assert!(matches!(
        events.recv().await.unwrap(),
        ConversationEvent::Delta { .. }
    ));
    assert!(matches!(
        events.recv().await.unwrap(),
        ConversationEvent::ToolStarted(_)
    ));
    assert!(matches!(
        events.recv().await.unwrap(),
        ConversationEvent::ApprovalRequested(_)
    ));
    assert!(matches!(
        events.recv().await.unwrap(),
        ConversationEvent::TurnCompleted(_)
    ));

    adapter
        .decide_approval("approval-1", ApprovalDecision::AllowOnce)
        .await
        .unwrap();
    assert!(matches!(
        events.recv().await.unwrap(),
        ConversationEvent::ApprovalResolved(_)
    ));

    adapter.interrupt(&id).await.unwrap();
    assert!(matches!(
        events.recv().await.unwrap(),
        ConversationEvent::TurnInterrupted(_)
    ));
}

#[tokio::test]
async fn deterministic_mock_satisfies_provider_contract() {
    let adapter = MockAdapter::new(ProviderId::Codex);
    exercise_contract(&adapter).await;
}
