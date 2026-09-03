CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    label TEXT NOT NULL,
    public_key BLOB NOT NULL,
    encrypted_keys BLOB NOT NULL,
    last_counter INTEGER NOT NULL DEFAULT 0,
    revoked_at TEXT
);

CREATE TABLE IF NOT EXISTS session_index (
    provider TEXT NOT NULL,
    native_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    project_path TEXT,
    updated_at TEXT NOT NULL,
    status TEXT NOT NULL,
    PRIMARY KEY (provider, native_id)
);

CREATE TABLE IF NOT EXISTS projects (
    id TEXT PRIMARY KEY,
    provider TEXT NOT NULL,
    canonical_path TEXT NOT NULL,
    display_path TEXT NOT NULL,
    title TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    available INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS event_buffer (
    conversation_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    encrypted_event BLOB NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (conversation_id, sequence)
);

CREATE TABLE IF NOT EXISTS transfers (
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    direction TEXT NOT NULL,
    target_path TEXT NOT NULL,
    bytes_completed INTEGER NOT NULL DEFAULT 0,
    expected_sha256 TEXT,
    status TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    device_id TEXT NOT NULL,
    provider TEXT,
    conversation_id TEXT,
    action TEXT NOT NULL,
    target_path TEXT,
    result TEXT NOT NULL,
    metadata TEXT NOT NULL DEFAULT '{}'
);
