-- Which provider accounts this agent knows about.
--
-- Names only. The credentials themselves are in the login keychain, under
-- the service live.jaco.remoteai.accounts, because they are bearer tokens and
-- this file is an ordinary SQLite database. Nothing secret belongs here.
CREATE TABLE provider_accounts (
    provider TEXT NOT NULL,
    label TEXT NOT NULL,
    -- What the CLI called the account when it was saved: an email, or the
    -- sign-in method. Shown next to the label; never used as an identifier.
    display TEXT,
    created_at TEXT NOT NULL,
    is_current INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (provider, label)
);
