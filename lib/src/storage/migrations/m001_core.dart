import '../migrations.dart';

/// The engine's own tables: installation facts, the oplog, command idempotence, the audit
/// chain, and local accounts with their grants (`session.md` session.account).
///
/// Every entity table carries `created_hlc`, `updated_hlc`, `deleted` (tombstone) and `origin`
/// (the device that wrote it), as plan §8.1 requires. Log tables (oplog, commands, audit) are
/// append-only and don't.
const m001Core = Migration(1, "core", r"""
CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
) STRICT;

CREATE TABLE oplog (
  seq       INTEGER PRIMARY KEY AUTOINCREMENT,
  hlc       TEXT NOT NULL,
  entity    TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  kind      TEXT NOT NULL,
  payload   TEXT NOT NULL,
  actor     TEXT,
  device    TEXT,
  command   TEXT
) STRICT;

CREATE INDEX oplog_entity ON oplog (entity, entity_id);

CREATE TABLE commands (
  id        TEXT PRIMARY KEY,
  op        TEXT NOT NULL,
  args_hash TEXT NOT NULL,
  answer    TEXT NOT NULL,
  at        TEXT NOT NULL
) STRICT;

CREATE INDEX commands_at ON commands (at);

CREATE TABLE audit (
  seq    INTEGER PRIMARY KEY,
  at     TEXT NOT NULL,
  kind   TEXT NOT NULL,
  actor  TEXT,
  device TEXT,
  data   TEXT NOT NULL,
  prev   TEXT NOT NULL,
  hash   TEXT NOT NULL
) STRICT;

CREATE TABLE accounts (
  id                   TEXT PRIMARY KEY,
  username             TEXT NOT NULL,
  email                TEXT,
  first_name           TEXT NOT NULL,
  last_name            TEXT NOT NULL,
  sex                  TEXT CHECK (sex IN ('female', 'male', 'other')),
  birthday             TEXT,
  picture              TEXT,
  password             TEXT,
  pin                  TEXT,
  status               TEXT NOT NULL CHECK (status IN ('pending', 'active', 'disabled')),
  must_change_password INTEGER NOT NULL DEFAULT 0,
  failed_attempts      INTEGER NOT NULL DEFAULT 0,
  locked_until         TEXT,
  created              TEXT NOT NULL,
  last_sign_in         TEXT,
  created_hlc          TEXT NOT NULL,
  updated_hlc          TEXT NOT NULL,
  deleted              INTEGER NOT NULL DEFAULT 0,
  origin               TEXT
) STRICT;

CREATE UNIQUE INDEX accounts_username ON accounts (lower(username));
CREATE UNIQUE INDEX accounts_email ON accounts (lower(email)) WHERE email IS NOT NULL;

CREATE TABLE grants (
  account    TEXT NOT NULL REFERENCES accounts (id),
  permission TEXT NOT NULL,
  PRIMARY KEY (account, permission)
) STRICT;
""");
