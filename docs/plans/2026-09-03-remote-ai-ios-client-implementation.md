# Remote AI iOS Client Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an iPhone app and a local macOS agent that securely control existing Codex and Claude sessions, expose separate daily/project views, handle approvals, and transfer files only on explicit user action.

**Architecture:** A Rust agent listens only on localhost and is published through Cloudflare Tunnel. It normalizes Codex app-server and Claude stream-json into one encrypted WebSocket protocol, while chunked HTTPS endpoints handle explicit file transfers. A native SwiftUI app consumes that protocol and keeps only a read-only mobile cache.

**Tech Stack:** Rust 2024, Tokio, Axum, Serde, SQLite/sqlx, p256 + HKDF + AES-GCM; Swift 5.9+, SwiftUI, URLSessionWebSocketTask, CryptoKit, SwiftData; XcodeGen; Cloudflare Tunnel.

---

## Before implementation

The repository currently contains only the approved design document. On the development Mac, `codex 0.144.4`, `claude 2.1.210`, Swift 5.9.2, and `cloudflared 2026.2.0` are available. Rust, Cargo, XcodeGen, and a selected full Xcode installation are not currently available.

Install full Xcode manually, open it once to accept its license, then run:

```bash
rtk sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
rtk brew install rustup-init xcodegen
rtk rustup-init -y --profile minimal
```

Open a new shell before continuing. Verify:

```bash
rtk xcodebuild -version
rtk rustc --version
rtk cargo --version
rtk xcodegen --version
rtk codex --version
rtk claude --version
rtk cloudflared --version
```

Expected: every command exits successfully. Do not begin feature work while the toolchain check is failing.

### Task 1: Bootstrap the monorepo and CI-style local checks

**Files:**
- Create: `.gitignore`
- Create: `rust-toolchain.toml`
- Create: `Cargo.toml`
- Create: `agent/Cargo.toml`
- Create: `agent/src/lib.rs`
- Create: `agent/src/main.rs`
- Create: `ios/project.yml`
- Create: `ios/RemoteAI/App/RemoteAIApp.swift`
- Create: `ios/RemoteAITests/BootstrapTests.swift`
- Create: `scripts/check.sh`
- Create: `README.md`

**Step 1: Write the failing bootstrap test**

Create `ios/RemoteAITests/BootstrapTests.swift`:

```swift
import XCTest
@testable import RemoteAI

final class BootstrapTests: XCTestCase {
    func testAppNameIsStable() {
        XCTAssertEqual(AppMetadata.name, "RemoteAI")
    }
}
```

Create a minimal Rust unit test in `agent/src/lib.rs` that references a not-yet-defined `agent_name()`.

**Step 2: Verify both tests fail**

```bash
rtk cargo test --workspace
rtk xcodegen generate --spec ios/project.yml
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Expected: Rust fails because `agent_name` is missing; Swift fails because `AppMetadata` is missing.

**Step 3: Add the minimal application shells**

Use one Cargo workspace with an `agent` binary/library. Add `AppMetadata` and a three-tab placeholder SwiftUI app. Configure the iOS target for iOS 17 and automatic signing. `scripts/check.sh` must run formatting checks, Rust tests, regenerate the Xcode project, and run iOS tests.

**Step 4: Run the checks**

```bash
rtk cargo fmt --all --check
rtk cargo test --workspace
rtk xcodegen generate --spec ios/project.yml
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Expected: all pass.

**Step 5: Commit**

```bash
rtk git add .gitignore rust-toolchain.toml Cargo.toml agent ios scripts README.md
rtk git commit -m "chore: bootstrap RemoteAI workspace"
```

### Task 2: Define the versioned cross-platform protocol

**Files:**
- Create: `protocol/v1/schema.json`
- Create: `protocol/v1/fixtures/provider-status.json`
- Create: `protocol/v1/fixtures/catalog.json`
- Create: `protocol/v1/fixtures/conversation-events.jsonl`
- Create: `protocol/v1/fixtures/approval-request.json`
- Create: `protocol/v1/fixtures/file-entry.json`
- Create: `agent/src/protocol.rs`
- Create: `agent/tests/protocol_fixtures.rs`
- Create: `ios/RemoteAI/Core/ProtocolModels.swift`
- Create: `ios/RemoteAITests/ProtocolFixtureTests.swift`

**Step 1: Add failing fixture-decoding tests**

Rust and Swift tests must decode the same fixtures into these core concepts:

```text
ProviderId: codex | claude
ConversationKind: daily | project
ProviderStatus
ProjectSummary
ConversationSummary
ConversationEvent
ApprovalRequest
FileEntry
RequestEnvelope / ResponseEnvelope / EventEnvelope
```

Every envelope must contain `protocolVersion`, `messageId`, and `kind`; events also contain `sequence` and `conversationId`.

**Step 2: Run tests and verify failure**

```bash
rtk cargo test -p remote-ai-agent --test protocol_fixtures
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RemoteAITests/ProtocolFixtureTests test
```

Expected: types or decoders are missing.

**Step 3: Implement strict Codable/Serde models**

Unknown event payloads must decode to an explicit `.unsupported(rawType:)` case rather than crash. Reject unsupported major protocol versions with a structured `upgrade_required` error.

**Step 4: Run tests**

Run the two commands from Step 2. Expected: all fixture tests pass in both languages.

**Step 5: Commit**

```bash
rtk git add protocol agent/src/protocol.rs agent/tests/protocol_fixtures.rs ios/RemoteAI/Core ios/RemoteAITests/ProtocolFixtureTests.swift
rtk git commit -m "feat: define RemoteAI protocol v1"
```

### Task 3: Add Agent configuration, storage, and provider discovery

**Files:**
- Create: `agent/src/config.rs`
- Create: `agent/src/store.rs`
- Create: `agent/src/discovery.rs`
- Create: `agent/migrations/0001_initial.sql`
- Create: `agent/tests/config_and_store.rs`
- Modify: `agent/src/lib.rs`
- Modify: `agent/src/main.rs`

**Step 1: Write failing tests**

Cover:

- the default bind address is exactly `127.0.0.1:8787`;
- state defaults to `~/Library/Application Support/RemoteAI` but is overrideable in tests;
- database file and private-key files are created with owner-only permissions;
- `codex` and `claude` discovery records executable path and version;
- a missing provider is returned as unavailable without failing Agent startup.

**Step 2: Verify failure**

```bash
rtk cargo test -p remote-ai-agent config_and_store
```

Expected: missing config/store/discovery modules.

**Step 3: Implement minimal configuration and SQLite schema**

Create tables for `devices`, `session_index`, `projects`, `event_buffer`, `transfers`, and `audit_log`. Store metadata only; never store vendor credentials or duplicate full vendor transcripts.

**Step 4: Run tests**

```bash
rtk cargo test -p remote-ai-agent config_and_store
```

Expected: pass, including permission assertions on macOS.

**Step 5: Commit**

```bash
rtk git add agent/src agent/migrations agent/tests/config_and_store.rs
rtk git commit -m "feat: add agent configuration and storage"
```

### Task 4: Implement one-time pairing and message encryption

**Files:**
- Create: `agent/src/crypto.rs`
- Create: `agent/src/pairing.rs`
- Create: `agent/tests/pairing_crypto.rs`
- Create: `ios/RemoteAI/Core/CryptoBox.swift`
- Create: `ios/RemoteAI/Core/KeychainStore.swift`
- Create: `ios/RemoteAI/Core/PairingPayload.swift`
- Create: `ios/RemoteAITests/CryptoVectorTests.swift`
- Create: `protocol/v1/fixtures/crypto-vectors.json`

**Step 1: Write failing cross-language vector tests**

Vectors must cover P-256 ECDH, HKDF-SHA256 directional keys, AES-256-GCM encryption, and nonce derivation from a four-byte direction prefix plus an eight-byte monotonic counter.

**Step 2: Verify failure**

```bash
rtk cargo test -p remote-ai-agent pairing_crypto
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RemoteAITests/CryptoVectorTests test
```

Expected: crypto implementations are missing.

**Step 3: Implement pairing**

The Mac generates a persistent P-256 key and a five-minute, single-use pairing secret. The QR payload contains only `origin`, `macId`, `macPublicKey`, `pairingSecret`, and `expiresAt`. The phone generates its own P-256 key, derives directional keys, and stores private material in Keychain. The Mac stores only the paired public key, derived key material, device label, and revocation state.

Authenticated frames use the counter and all routing metadata as AES-GCM associated data. Reject expired QR payloads, reused secrets, counters less than or equal to the last accepted counter, and revoked devices.

**Step 4: Run tests**

Run both commands from Step 2. Expected: Rust and Swift produce/consume the same vectors; replay and tamper tests pass.

**Step 5: Commit**

```bash
rtk git add protocol/v1/fixtures/crypto-vectors.json agent/src agent/tests/pairing_crypto.rs ios/RemoteAI/Core ios/RemoteAITests/CryptoVectorTests.swift
rtk git commit -m "feat: add secure device pairing"
```

### Task 5: Build the authenticated HTTP/WebSocket gateway

**Files:**
- Create: `agent/src/gateway.rs`
- Create: `agent/src/event_buffer.rs`
- Create: `agent/tests/gateway.rs`
- Modify: `agent/src/main.rs`
- Create: `ios/RemoteAI/Core/AgentClient.swift`
- Create: `ios/RemoteAI/Core/WebSocketTransport.swift`
- Create: `ios/RemoteAITests/WebSocketTransportTests.swift`

**Step 1: Write failing gateway tests**

Test `GET /v1/health`, `POST /v1/pair`, authenticated `GET /v1/ws`, heartbeat, duplicate request IDs, ordered event sequencing, and resume from `lastSequence`. A revoked device and a plaintext business frame must be rejected.

**Step 2: Verify failure**

```bash
rtk cargo test -p remote-ai-agent gateway
```

Expected: routes do not exist.

**Step 3: Implement the gateway and mobile transport**

Use Axum with a bounded per-conversation event ring. The Swift client must expose connection states `disconnected`, `connecting`, `paired`, `online`, and `recovering`, and reconnect with capped exponential backoff while the app is foregrounded.

**Step 4: Run focused and full tests**

```bash
rtk cargo test -p remote-ai-agent gateway
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RemoteAITests/WebSocketTransportTests test
```

Expected: pass; reconnect tests receive each event exactly once.

**Step 5: Commit**

```bash
rtk git add agent/src agent/tests/gateway.rs ios/RemoteAI/Core ios/RemoteAITests/WebSocketTransportTests.swift
rtk git commit -m "feat: add encrypted realtime gateway"
```

### Task 6: Define the provider adapter and complete it with a mock

**Files:**
- Create: `agent/src/adapters/mod.rs`
- Create: `agent/src/adapters/mock.rs`
- Create: `agent/tests/provider_contract.rs`
- Modify: `agent/src/lib.rs`

**Step 1: Write the failing provider contract test**

The async trait must support:

```rust
async fn status(&self) -> ProviderStatus;
async fn list_conversations(&self) -> Result<Vec<ConversationSummary>>;
async fn load_conversation(&self, id: &str, cursor: Option<String>) -> Result<ConversationPage>;
async fn start(&self, kind: ConversationKind, cwd: Option<PathBuf>) -> Result<String>;
async fn resume(&self, id: &str) -> Result<()>;
async fn send(&self, id: &str, text: String, attachments: Vec<PathBuf>) -> Result<()>;
async fn decide_approval(&self, request_id: &str, decision: ApprovalDecision) -> Result<()>;
async fn interrupt(&self, id: &str) -> Result<()>;
fn subscribe(&self) -> broadcast::Receiver<ConversationEvent>;
```

**Step 2: Verify failure**

```bash
rtk cargo test -p remote-ai-agent provider_contract
```

**Step 3: Implement the trait and deterministic mock**

The mock must emit text deltas, a tool event, an approval request, a completion event, and an interrupt event. It is the default dependency for all gateway and iOS UI tests.

**Step 4: Run tests**

```bash
rtk cargo test -p remote-ai-agent provider_contract
```

Expected: every adapter capability passes one shared contract suite.

**Step 5: Commit**

```bash
rtk git add agent/src/adapters agent/src/lib.rs agent/tests/provider_contract.rs
rtk git commit -m "feat: add provider adapter contract"
```

### Task 7: Implement the Codex app-server adapter

**Files:**
- Create: `scripts/export-codex-schema.sh`
- Create: `agent/vendor/codex-schema/.gitkeep`
- Create: `agent/src/adapters/codex.rs`
- Create: `agent/tests/codex_adapter.rs`
- Create: `agent/tests/fixtures/codex/*.jsonl`
- Modify: `agent/src/adapters/mod.rs`

**Step 1: Export and pin the local protocol schema**

```bash
rtk codex app-server generate-json-schema --experimental --out agent/vendor/codex-schema
rtk codex --version > agent/vendor/codex-schema/CODEX_VERSION
```

Review the generated v2 method schemas for `thread/list`, `thread/read`, `thread/start`, `thread/resume`, `turn/start`, `turn/interrupt`, message deltas, and command/file approval requests. Commit the version marker and only the schema files directly consumed by the adapter.

**Step 2: Write failing transcript tests**

Feed recorded, sanitized JSON-RPC fixtures to the adapter. Assert mapping for daily/project conversation summaries, paged turns, streaming text, command/file approvals, completion, and interruption. A new unknown notification must map to `.unsupported` and not terminate the process.

**Step 3: Verify failure**

```bash
rtk cargo test -p remote-ai-agent codex_adapter
```

**Step 4: Implement minimal JSON-RPC subprocess support**

Spawn `codex app-server --stdio`, initialize once, correlate request IDs, drain stderr separately, and restart with backoff after an unexpected exit. Use native thread IDs and always start/resume with phone-mediated approvals enabled; never use bypass modes.

Classify a thread as `daily` when its normalized cwd is the user home directory or absent; otherwise group it under a project keyed by normalized cwd.

**Step 5: Run contract and smoke tests**

```bash
rtk cargo test -p remote-ai-agent codex_adapter provider_contract
rtk cargo test -p remote-ai-agent --test codex_adapter -- --ignored --nocapture
```

Expected: fixture tests pass; ignored smoke test lists at least one real Codex thread without modifying it.

**Step 6: Commit**

```bash
rtk git add scripts/export-codex-schema.sh agent/vendor agent/src/adapters agent/tests
rtk git commit -m "feat: integrate Codex app server"
```

### Task 8: Implement the Claude stream-json adapter

**Files:**
- Create: `agent/src/adapters/claude.rs`
- Create: `agent/tests/claude_adapter.rs`
- Create: `agent/tests/fixtures/claude/*.jsonl`
- Modify: `agent/src/adapters/mod.rs`

**Step 1: Capture sanitized protocol fixtures**

Use a disposable temporary directory and a harmless prompt. Run Claude with `--print --input-format stream-json --output-format stream-json --include-partial-messages --include-hook-events --permission-mode manual`. Remove message content, credentials, and absolute personal paths before committing fixtures.

**Step 2: Write failing fixture tests**

Cover session creation, `--resume <session-id>`, partial text, tool lifecycle, permission/control request, control response, completion, error, and cancellation. Verify the adapter never starts Claude with `--dangerously-skip-permissions`.

**Step 3: Verify failure**

```bash
rtk cargo test -p remote-ai-agent claude_adapter
```

**Step 4: Implement the adapter**

Keep one managed subprocess per active Claude session, use stream-json stdin/stdout, drain stderr, persist only the native session ID and index metadata, and map control requests into the common approval model. Discover historical metadata from Claude's supported project/session sources without mutating vendor files.

Use the same daily/project rule as Codex: home or missing cwd is daily; another normalized cwd is a project.

**Step 5: Run tests and read-only smoke test**

```bash
rtk cargo test -p remote-ai-agent claude_adapter provider_contract
rtk cargo test -p remote-ai-agent --test claude_adapter -- --ignored --nocapture
```

Expected: fixtures pass; smoke test lists sessions and resumes only a disposable test session.

**Step 6: Commit**

```bash
rtk git add agent/src/adapters agent/tests/claude_adapter.rs agent/tests/fixtures/claude
rtk git commit -m "feat: integrate Claude Code"
```

### Task 9: Build separate daily and project catalogs

**Files:**
- Create: `agent/src/catalog.rs`
- Create: `agent/tests/catalog.rs`
- Modify: `agent/src/gateway.rs`
- Modify: `agent/src/store.rs`

**Step 1: Write failing catalog tests**

Assert that:

- providers are never mixed in one response;
- daily sessions are separate from projects;
- the same path produces distinct Codex and Claude project records;
- project identity uses canonical path while display preserves a friendly path;
- missing/unavailable paths remain visible but are marked unavailable;
- sorting is most-recent-first and stable.

**Step 2: Verify failure**

```bash
rtk cargo test -p remote-ai-agent catalog
```

**Step 3: Implement catalog routes**

Add `provider.status`, `conversations.daily.list`, `projects.list`, `projects.conversations.list`, `conversation.history`, `conversation.start`, and `conversation.resume` gateway operations. Rebuild only lightweight indexes on Agent startup or explicit refresh.

**Step 4: Run tests**

```bash
rtk cargo test -p remote-ai-agent catalog gateway
```

Expected: pass with separate provider/project boundaries.

**Step 5: Commit**

```bash
rtk git add agent/src agent/tests/catalog.rs
rtk git commit -m "feat: add provider-specific conversation catalogs"
```

### Task 10: Add safe file browsing and explicit transfers

**Files:**
- Create: `agent/src/files.rs`
- Create: `agent/src/transfers.rs`
- Create: `agent/tests/files.rs`
- Create: `agent/tests/transfers.rs`
- Modify: `agent/src/gateway.rs`
- Modify: `protocol/v1/schema.json`

**Step 1: Write failing filesystem tests using temporary directories**

Cover directory listing, hidden files, symlinks, unreadable entries, metadata, bounded text preview, range download, encrypted upload chunks, SHA-256 verification, cancellation, resume, and path traversal. Confirm no test reads or writes outside its temporary root.

**Step 2: Write failing conflict tests**

An existing destination must return `conflict` before any target change. Only explicit `keep_both` or `overwrite` may continue. `keep_both` must generate a deterministic available name; `overwrite` must use a sibling temporary file and atomic rename.

**Step 3: Verify failure**

```bash
rtk cargo test -p remote-ai-agent files transfers
```

**Step 4: Implement routes and enforce no-sync invariants**

Implement `files.list`, `files.metadata`, `files.preview`, `transfers.create`, chunk upload/download, `transfers.finish`, and `transfers.cancel`. Do not add filesystem watchers, recurring jobs, automatic conflict resolution, or background transfer scheduling.

Hide a documented list of system-sensitive directories by default, but allow an explicit `includeSensitive=true` request from a paired device. Always enforce the current macOS user's actual permissions.

**Step 5: Run tests**

```bash
rtk cargo test -p remote-ai-agent files transfers
```

Expected: all pass; traversal, implicit overwrite, and incomplete-file assertions remain rejected.

**Step 6: Commit**

```bash
rtk git add agent/src agent/tests protocol/v1/schema.json
rtk git commit -m "feat: add explicit secure file transfers"
```

### Task 11: Add auditing, health diagnostics, and tunnel guidance

**Files:**
- Create: `agent/src/audit.rs`
- Create: `agent/src/diagnostics.rs`
- Create: `agent/src/tunnel.rs`
- Create: `agent/tests/audit_and_diagnostics.rs`
- Create: `docs/cloudflare-setup.md`
- Modify: `agent/src/gateway.rs`

**Step 1: Write failing redaction and health tests**

Audit rows must include timestamp, device, provider, conversation, action, target path, and result, but redact message bodies, pairing secrets, auth headers, API keys, cookies, and file contents. Diagnostics must report Agent/provider/cloudflared versions and reachability without exposing credentials.

**Step 2: Verify failure**

```bash
rtk cargo test -p remote-ai-agent audit_and_diagnostics
```

**Step 3: Implement audit and diagnostics**

Expose authenticated operations for paged audit viewing, provider health, tunnel health, and device revocation. The Tunnel module detects `cloudflared` and reports configuration; it must not create Cloudflare accounts or domains.

Document Named Tunnel setup for a stable hostname and Quick Tunnel for temporary testing. Keep the Agent bound to localhost in both cases.

**Step 4: Run tests**

```bash
rtk cargo test -p remote-ai-agent audit_and_diagnostics
```

Expected: pass, including secret-redaction fixtures.

**Step 5: Commit**

```bash
rtk git add agent/src agent/tests/audit_and_diagnostics.rs docs/cloudflare-setup.md
rtk git commit -m "feat: add audit and tunnel diagnostics"
```

### Task 12: Implement the iOS app state and provider switcher

**Files:**
- Create: `ios/RemoteAI/App/AppModel.swift`
- Create: `ios/RemoteAI/App/AppDependencies.swift`
- Create: `ios/RemoteAI/Features/Shell/RootView.swift`
- Create: `ios/RemoteAI/Features/Shell/ProviderSwitcher.swift`
- Create: `ios/RemoteAI/Features/Shell/ConnectionBanner.swift`
- Create: `ios/RemoteAI/Core/CacheStore.swift`
- Create: `ios/RemoteAITests/AppModelTests.swift`
- Modify: `ios/RemoteAI/App/RemoteAIApp.swift`

**Step 1: Write failing state tests**

Test first-launch default Codex, persistence of last provider, strict provider filtering, foreground-only reconnect, offline read-only mode, and recovery from an unsupported event.

**Step 2: Verify failure**

```bash
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RemoteAITests/AppModelTests test
```

**Step 3: Implement app state and shell**

Use one `@MainActor @Observable` AppModel. Place `Codex | Claude` above a `TabView` containing Chat, Projects, Files, and Settings. Switching provider must invalidate visible provider-scoped lists before loading the new provider; never show a merged fallback.

Use SwiftData only for provider-scoped summary/history cache and user preferences. Do not cache credentials or downloaded file contents in SwiftData.

**Step 4: Run tests**

Run Step 2. Expected: pass.

**Step 5: Commit**

```bash
rtk git add ios/RemoteAI ios/RemoteAITests/AppModelTests.swift
rtk git commit -m "feat: add iOS app shell and provider switching"
```

### Task 13: Implement daily chats, projects, and conversation UI

**Files:**
- Create: `ios/RemoteAI/Features/Conversations/DailyConversationListView.swift`
- Create: `ios/RemoteAI/Features/Conversations/ConversationView.swift`
- Create: `ios/RemoteAI/Features/Conversations/ConversationViewModel.swift`
- Create: `ios/RemoteAI/Features/Conversations/EventViews.swift`
- Create: `ios/RemoteAI/Features/Conversations/ApprovalCard.swift`
- Create: `ios/RemoteAI/Features/Projects/ProjectListView.swift`
- Create: `ios/RemoteAI/Features/Projects/ProjectDetailView.swift`
- Create: `ios/RemoteAITests/ConversationViewModelTests.swift`
- Create: `ios/RemoteAIUITests/ProviderSeparationUITests.swift`

**Step 1: Write failing view-model tests**

Cover paged history, ordered delta assembly, duplicate-event suppression, approval allow/deny, stopping a run, failed-send retry, offline restrictions, and new daily/project session creation.

**Step 2: Write failing provider-separation UI test**

Launch against the mock Agent. Verify Codex daily sessions and projects are visible, switch to Claude, and assert no Codex titles remain. Enter a project and verify only that project's sessions appear.

**Step 3: Verify failure**

```bash
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RemoteAITests/ConversationViewModelTests test
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RemoteAIUITests/ProviderSeparationUITests test
```

**Step 4: Implement the screens**

Daily Chat shows only unbound sessions. Projects shows folder records; project detail shows only sessions under that provider/path. Conversation UI renders text, status, command, file change, tool, error, and approval events. Approval cards expose only “Allow once” and “Deny.” The stop button is visible only during an active turn.

**Step 5: Run tests**

Run both Step 3 commands. Expected: pass.

**Step 6: Commit**

```bash
rtk git add ios/RemoteAI/Features ios/RemoteAITests ios/RemoteAIUITests
rtk git commit -m "feat: add conversations and projects UI"
```

### Task 14: Implement iOS file browsing and manual transfer UI

**Files:**
- Create: `ios/RemoteAI/Features/Files/FileBrowserView.swift`
- Create: `ios/RemoteAI/Features/Files/FileBrowserViewModel.swift`
- Create: `ios/RemoteAI/Features/Files/FilePreviewView.swift`
- Create: `ios/RemoteAI/Features/Files/TransferSheet.swift`
- Create: `ios/RemoteAI/Core/TransferClient.swift`
- Create: `ios/RemoteAITests/FileBrowserViewModelTests.swift`
- Create: `ios/RemoteAIUITests/ManualTransferUITests.swift`

**Step 1: Write failing tests**

Cover path navigation, search, recent/favorite directories, sensitive-directory reveal confirmation, document-picker upload, download export, progress, cancellation, retry, keep-both, overwrite confirmation, and offline disabling.

Add a negative test that leaves the app idle and asserts the mock Agent receives zero transfer requests. This is the permanent regression test for “no automatic sync.”

**Step 2: Verify failure**

```bash
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RemoteAITests/FileBrowserViewModelTests test
```

**Step 3: Implement manual file flows**

Use `fileImporter` for phone uploads and `fileExporter`/share sheet for downloads. Start a transfer only from an explicit button action. Encrypt each chunk before upload and decrypt after download. Show destination path before confirmation; never start work from lifecycle or background callbacks.

**Step 4: Run unit and UI tests**

```bash
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RemoteAITests/FileBrowserViewModelTests test
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RemoteAIUITests/ManualTransferUITests test
```

Expected: pass; idle/no-sync test observes no requests.

**Step 5: Commit**

```bash
rtk git add ios/RemoteAI/Features/Files ios/RemoteAI/Core/TransferClient.swift ios/RemoteAITests ios/RemoteAIUITests
rtk git commit -m "feat: add explicit iOS file transfers"
```

### Task 15: Implement pairing, settings, and diagnostics UI

**Files:**
- Create: `ios/RemoteAI/Features/Pairing/PairingScannerView.swift`
- Create: `ios/RemoteAI/Features/Pairing/PairingViewModel.swift`
- Create: `ios/RemoteAI/Features/Settings/SettingsView.swift`
- Create: `ios/RemoteAI/Features/Settings/AuditLogView.swift`
- Create: `ios/RemoteAI/Features/Settings/DiagnosticsView.swift`
- Create: `ios/RemoteAITests/PairingViewModelTests.swift`
- Create: `ios/RemoteAIUITests/PairingAndRevocationUITests.swift`
- Modify: `ios/project.yml`

**Step 1: Write failing tests**

Test valid QR pairing, expired QR rejection, wrong Mac key, secret reuse, keychain persistence, device revocation, cache clearing, and redacted audit display.

**Step 2: Verify failure**

```bash
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:RemoteAITests/PairingViewModelTests test
```

**Step 3: Implement UI**

Add camera permission text and QR scanning. Settings shows Mac/Agent/provider/cloudflared versions, endpoint, online state, cache controls, transfer history, audit rows, and a destructive confirmation before revoking the phone key.

**Step 4: Run tests**

Run Step 2 plus the pairing UI test. Expected: pass.

**Step 5: Commit**

```bash
rtk git add ios
rtk git commit -m "feat: add pairing and diagnostics UI"
```

### Task 16: Add end-to-end harness and real CLI acceptance scripts

**Files:**
- Create: `agent/src/bin/mock-agent.rs`
- Create: `scripts/e2e-simulator.sh`
- Create: `scripts/smoke-codex.sh`
- Create: `scripts/smoke-claude.sh`
- Create: `tests/e2e/README.md`
- Create: `tests/e2e/fixtures/`
- Modify: `README.md`

**Step 1: Write a failing end-to-end script**

The simulator scenario must pair, select Codex, open a daily session, switch to a Codex project, stream a response, decide one approval, switch to Claude without mixed rows, upload one fixture, download it, and compare SHA-256 hashes.

**Step 2: Verify failure**

```bash
rtk scripts/e2e-simulator.sh
```

Expected: fail until the mock Agent and launch arguments are wired.

**Step 3: Implement deterministic harness**

The mock Agent must use a temporary root, fixed fixtures, and no network beyond localhost. Acceptance scripts for real CLIs must default to read-only listing; any session creation requires an explicit `--allow-create-disposable-session` flag.

**Step 4: Run full automated verification**

```bash
rtk cargo fmt --all --check
rtk cargo clippy --workspace --all-targets -- -D warnings
rtk cargo test --workspace
rtk xcodegen generate --spec ios/project.yml
rtk xcodebuild -project ios/RemoteAI.xcodeproj -scheme RemoteAI -destination 'platform=iOS Simulator,name=iPhone 16' test
rtk scripts/e2e-simulator.sh
```

Expected: all commands exit 0.

**Step 5: Run controlled real integrations**

```bash
rtk scripts/smoke-codex.sh
rtk scripts/smoke-claude.sh
```

Expected: both report installed version, list daily/project metadata, and make no file or session changes.

**Step 6: Commit**

```bash
rtk git add agent/src/bin scripts tests README.md
rtk git commit -m "test: add end-to-end and CLI acceptance coverage"
```

### Task 17: Verify the cellular-network development release

**Files:**
- Create: `docs/development-runbook.md`
- Create: `docs/security-checklist.md`
- Modify: `README.md`

**Step 1: Document the exact run path**

Include Agent startup, QR pairing, Named Tunnel configuration, Xcode signing, physical-iPhone installation, log locations, revocation, recovery, and clean shutdown. State prominently that there is no automatic file synchronization.

**Step 2: Run security checks**

Verify Agent binds only to `127.0.0.1`, plaintext business frames are rejected, credentials are absent from logs/database/mobile cache, expired pairing fails, revoked devices cannot reconnect, path traversal fails, and overwrite always requires confirmation.

**Step 3: Execute the approved acceptance scenario**

On a physical iPhone using cellular data:

1. Pair with the Mac through the tunnel.
2. Select Codex and continue one existing daily session.
3. Open one Codex project and its existing session.
4. Complete one harmless phone-mediated approval.
5. Switch to Claude and verify the lists are entirely Claude-specific.
6. Continue one existing Claude session.
7. Upload and download a disposable file manually and verify its hash.
8. Leave the App idle and verify no transfer occurs.
9. Disconnect/reconnect the tunnel during a streaming response and verify ordered recovery.

**Step 4: Run final automated verification**

```bash
rtk scripts/check.sh
rtk git status --short
```

Expected: checks pass and the working tree is clean.

**Step 5: Commit the runbooks**

```bash
rtk git add README.md docs/development-runbook.md docs/security-checklist.md
rtk git commit -m "docs: add development and security runbooks"
```

## Implementation rules

- Follow `@superpowers:test-driven-development` for every feature or bug fix.
- Use `@superpowers:systematic-debugging` whenever a test or integration behaves unexpectedly.
- Use `@superpowers:verification-before-completion` before claiming a task or the release is complete.
- Never read or copy vendor authentication secrets into RemoteAI storage.
- Never bypass Codex or Claude permission systems.
- Never add file watchers, scheduled synchronization, lifecycle-triggered transfers, or implicit conflict resolution.
- Keep all destructive filesystem tests inside verified temporary directories.
- If a vendor CLI schema changes, update sanitized fixtures and compatibility checks before changing the adapter.
