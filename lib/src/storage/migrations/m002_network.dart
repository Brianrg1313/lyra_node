import '../migrations.dart';

/// What the LAN needs (plan §5, `session.md` session.devices and session.session): paired
/// devices, sessions and their spent refresh tokens, the event stream clients subscribe to, and
/// uploaded files.
///
/// The installation CA lives in `meta` (`ca.*` keys): the database is the encrypted keyring's
/// vault for it (plan §5.3).
const m002Network = Migration(2, "network", r"""
CREATE TABLE devices (
  id               TEXT PRIMARY KEY,
  name             TEXT NOT NULL,
  platform         TEXT NOT NULL,
  kind             TEXT NOT NULL CHECK (kind IN ('master', 'native', 'web')),
  code             TEXT NOT NULL,
  public_key       BLOB NOT NULL,
  cert_fingerprint TEXT,
  app_version      TEXT,
  paired           TEXT NOT NULL,
  paired_by        TEXT REFERENCES accounts (id),
  last_seen        TEXT,
  last_account     TEXT,
  revoked          TEXT,
  created_hlc      TEXT NOT NULL,
  updated_hlc      TEXT NOT NULL,
  deleted          INTEGER NOT NULL DEFAULT 0,
  origin           TEXT
) STRICT;

CREATE UNIQUE INDEX devices_code ON devices (code);
CREATE UNIQUE INDEX devices_cert ON devices (cert_fingerprint) WHERE cert_fingerprint IS NOT NULL;

CREATE TABLE sessions (
  id              TEXT PRIMARY KEY,
  account         TEXT NOT NULL REFERENCES accounts (id),
  device          TEXT NOT NULL REFERENCES devices (id),
  scope           TEXT NOT NULL CHECK (scope IN ('full', 'pos')),
  refresh_hash    TEXT NOT NULL,
  refresh_expires TEXT NOT NULL,
  created         TEXT NOT NULL,
  last_used       TEXT NOT NULL,
  ended           TEXT,
  end_reason      TEXT
) STRICT;

CREATE UNIQUE INDEX sessions_refresh ON sessions (refresh_hash);
CREATE INDEX sessions_account ON sessions (account) WHERE ended IS NULL;
CREATE INDEX sessions_device ON sessions (device) WHERE ended IS NULL;

CREATE TABLE refresh_spent (
  hash    TEXT PRIMARY KEY,
  session TEXT NOT NULL REFERENCES sessions (id),
  spent   TEXT NOT NULL
) STRICT;

CREATE TABLE events (
  seq      INTEGER PRIMARY KEY AUTOINCREMENT,
  at       TEXT NOT NULL,
  name     TEXT NOT NULL,
  data     TEXT NOT NULL,
  audience TEXT
) STRICT;

CREATE INDEX events_at ON events (at);

CREATE TABLE files (
  id           TEXT PRIMARY KEY,
  purpose      TEXT NOT NULL,
  content_type TEXT NOT NULL,
  size         INTEGER NOT NULL,
  owner        TEXT NOT NULL REFERENCES accounts (id),
  permission   TEXT,
  created      TEXT NOT NULL,
  referenced   INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE INDEX files_orphans ON files (created) WHERE referenced = 0;
""");
