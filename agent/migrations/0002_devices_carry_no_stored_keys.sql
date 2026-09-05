-- Session keys are derived per connection from the Mac's private key and the
-- device's public key, so there is nothing secret to keep in this row. The
-- column was never written; drop it rather than leave a name that implies
-- keys are stored at rest.
ALTER TABLE devices DROP COLUMN encrypted_keys;
