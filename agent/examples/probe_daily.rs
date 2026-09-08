// Scratch probe: what the mainline code returns for Claude's Chats list.
use remote_ai_agent::adapters::ProviderAdapter;
use remote_ai_agent::adapters::claude::ClaudeAdapter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let home = std::env::var("HOME").unwrap();
    let adapter = ClaudeAdapter::new("/opt/homebrew/bin/claude", &home);
    let daily = adapter.list_daily_conversations().await?;
    println!("daily/chats: {}", daily.len());
    for c in daily.iter().take(20) {
        println!(
            "  [{:?}] {:<44} src={:?} write={:?}",
            c.kind,
            c.title.chars().take(42).collect::<String>(),
            c.source,
            c.write_state
        );
    }
    Ok(())
}
