import '../migrations.dart';

/// Product tables, their fields and records (`inventory.md`), and the stock ledger (`stock.md`).
///
/// A record's cells are one JSON object `{fieldId: value}` (I-20): fields come and go at run
/// time, so they can't be columns. Stock is never a cell: movements are the truth and
/// `stock_balances` is their projection, rewritten in the same transaction (ST-3).
const m004Inventory = Migration(4, "inventory", r"""
CREATE TABLE inventory_tables (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL,
  description  TEXT,
  color        TEXT NOT NULL,
  is_primary   INTEGER NOT NULL DEFAULT 0,
  next_counter INTEGER NOT NULL DEFAULT 1,
  import_stage TEXT,
  created      TEXT NOT NULL,
  updated      TEXT NOT NULL,
  last_record  TEXT,
  created_hlc  TEXT NOT NULL,
  updated_hlc  TEXT NOT NULL,
  deleted      INTEGER NOT NULL DEFAULT 0,
  origin       TEXT
) STRICT;

-- At most one live primary table (I-3).
CREATE UNIQUE INDEX inventory_tables_primary ON inventory_tables (is_primary) WHERE is_primary = 1 AND deleted = 0;

CREATE TABLE inventory_fields (
  id          TEXT PRIMARY KEY,
  table_id    TEXT NOT NULL REFERENCES inventory_tables (id),
  name        TEXT NOT NULL,
  description TEXT,
  type        TEXT NOT NULL,
  position    INTEGER NOT NULL,
  width       INTEGER,
  options     TEXT NOT NULL DEFAULT '[]',
  unit        TEXT NOT NULL DEFAULT '',
  visibility  TEXT NOT NULL DEFAULT 'visible',
  summary     INTEGER NOT NULL DEFAULT 0,
  hand_typed  INTEGER NOT NULL DEFAULT 1,
  created     TEXT NOT NULL,
  updated     TEXT NOT NULL,
  created_hlc TEXT NOT NULL,
  updated_hlc TEXT NOT NULL
) STRICT;

CREATE INDEX inventory_fields_table ON inventory_fields (table_id, position);

CREATE TABLE inventory_records (
  id          TEXT PRIMARY KEY,
  table_id    TEXT NOT NULL REFERENCES inventory_tables (id),
  data        TEXT NOT NULL DEFAULT '{}',
  created     TEXT NOT NULL,
  updated     TEXT NOT NULL,
  created_by  TEXT,
  updated_by  TEXT,
  created_hlc TEXT NOT NULL,
  updated_hlc TEXT NOT NULL,
  deleted     INTEGER NOT NULL DEFAULT 0,
  origin      TEXT
) STRICT;

CREATE INDEX inventory_records_table ON inventory_records (table_id, deleted, id);

CREATE TABLE stock_movements (
  id           TEXT PRIMARY KEY,
  product_id   TEXT NOT NULL,
  table_id     TEXT NOT NULL,
  operation    TEXT NOT NULL,
  reason       TEXT,
  quantity     INTEGER NOT NULL CHECK (quantity > 0),
  note         TEXT,
  actor        TEXT,
  device       TEXT,
  source       TEXT NOT NULL,
  invoice_id   TEXT,
  product_name TEXT,
  sku          TEXT,
  at           TEXT NOT NULL,
  hlc          TEXT NOT NULL,
  command_id   TEXT
) STRICT;

CREATE INDEX stock_movements_product ON stock_movements (product_id, hlc);

CREATE TABLE stock_balances (
  product_id   TEXT PRIMARY KEY,
  table_id     TEXT NOT NULL,
  on_hand      INTEGER NOT NULL DEFAULT 0,
  reserved     INTEGER NOT NULL DEFAULT 0,
  returns      INTEGER NOT NULL DEFAULT 0,
  needs_review INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE TABLE stock_holds (
  id         TEXT PRIMARY KEY,
  product_id TEXT NOT NULL,
  table_id   TEXT NOT NULL,
  sku        TEXT,
  qty        INTEGER NOT NULL CHECK (qty >= 0),
  status     TEXT NOT NULL,
  owner_kind TEXT NOT NULL,
  owner_id   TEXT,
  created    TEXT NOT NULL,
  expires    TEXT
) STRICT;

CREATE INDEX stock_holds_product ON stock_holds (product_id, status, created);
""");
