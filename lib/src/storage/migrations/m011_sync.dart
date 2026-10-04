import '../migrations.dart';

/// The edge sync with the cloud (plan §9, `task-edge-sync-backend.md`).
///
/// - `sync_link`: one row once the master is enrolled: the edge device, its key pair (the private
///   half sealed), the backend's grant keys, where each direction stands (`pushed_seq` in the oplog,
///   the pull `cursor`), and `pulled_hlc`, the clock when the last pull ended: a field written here
///   after it and changed in the cloud too is a true concurrent edit (§9.3).
/// - `sync_ids`: the `cloud_id ↔ local_id` map; neither side adopts the other's ids.
/// - `sync_fields`: each synced field's stamp and whether it was written here, the clock both sides
///   settle a field by. Every field of a synced record has one.
/// - `sync_pulled`: the cloud's `commandId`s already applied, so a page read twice applies once.
/// - `sync_rejected`: a change either side refused, kept for the owner, never retried.
/// - `sync_conflicts`: the conflicts inbox: the value that lost a true concurrent edit.
const m011Sync = Migration(11, "sync", r"""
CREATE TABLE sync_link (
  one         INTEGER PRIMARY KEY CHECK (one = 1),
  device      TEXT NOT NULL,
  company     TEXT NOT NULL,
  site        TEXT NOT NULL,
  endpoint    TEXT NOT NULL,
  public_key  TEXT NOT NULL,
  private_key TEXT NOT NULL,
  edge_keys   TEXT NOT NULL DEFAULT '[]',
  allowance   TEXT NOT NULL,
  phase       TEXT NOT NULL CHECK (phase IN ('download', 'upload', 'live')),
  revoked     INTEGER NOT NULL DEFAULT 0,
  pushed_seq  INTEGER NOT NULL DEFAULT 0,
  indexed_seq INTEGER NOT NULL DEFAULT 0,
  cursor      TEXT,
  pulled_hlc  TEXT,
  last_sync   TEXT,
  last_error  TEXT,
  enrolled    TEXT NOT NULL
) STRICT;

CREATE TABLE sync_ids (
  entity   TEXT NOT NULL,
  local_id TEXT NOT NULL,
  cloud_id TEXT NOT NULL,
  PRIMARY KEY (entity, local_id)
) STRICT;

CREATE UNIQUE INDEX sync_ids_cloud ON sync_ids (entity, cloud_id);

CREATE TABLE sync_fields (
  entity    TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  field     TEXT NOT NULL,
  hlc       TEXT NOT NULL,
  local     INTEGER NOT NULL,
  PRIMARY KEY (entity, entity_id, field)
) STRICT;

CREATE TABLE sync_pulled (
  command_id TEXT PRIMARY KEY,
  at         TEXT NOT NULL
) STRICT;

CREATE TABLE sync_rejected (
  command_id TEXT PRIMARY KEY,
  direction  TEXT NOT NULL CHECK (direction IN ('push', 'pull')),
  entity     TEXT NOT NULL,
  entity_id  TEXT NOT NULL,
  reason     TEXT NOT NULL,
  data       TEXT NOT NULL DEFAULT '{}',
  at         TEXT NOT NULL
) STRICT;

CREATE TABLE sync_conflicts (
  id         TEXT PRIMARY KEY,
  entity     TEXT NOT NULL,
  entity_id  TEXT NOT NULL,
  field      TEXT NOT NULL,
  kept       TEXT NOT NULL,
  kept_side  TEXT NOT NULL CHECK (kept_side IN ('master', 'cloud')),
  lost       TEXT NOT NULL,
  kept_hlc   TEXT NOT NULL,
  lost_hlc   TEXT NOT NULL,
  at         TEXT NOT NULL,
  status     TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'dismissed', 'restored'))
) STRICT;

CREATE INDEX sync_conflicts_open ON sync_conflicts (status, at);
""");
