import '../migrations.dart';

/// POS tickets (`pos.md`): an invoice is a document from its first line, kept when cancelled.
///
/// Money is in minor units of `currency`, percents are decimal strings (README, money). A line's
/// figures are computed from its frozen `price`, `qty` and `tax_rate` on every read, so nothing
/// stored can disagree with them. A line's id is also the id of its hold in `stock_holds` (owner
/// `invoice`), which is where its `held` is read from: the stock screen can shrink a hold under a
/// line (ST-22) without writing to the ticket.
const m005Pos = Migration(5, "pos", r"""
CREATE TABLE pos_invoices (
  id           TEXT PRIMARY KEY,
  ticket       TEXT NOT NULL COLLATE NOCASE UNIQUE,
  status       TEXT NOT NULL,
  device       TEXT NOT NULL,
  seller       TEXT NOT NULL,
  closed_by    TEXT,
  cancelled_by TEXT,
  default_tax  TEXT NOT NULL,
  currency     TEXT NOT NULL,
  payment      TEXT,
  note         TEXT,
  handover     TEXT,
  opened       TEXT NOT NULL,
  closed       TEXT,
  cancelled    TEXT,
  origin       TEXT NOT NULL DEFAULT 'live',
  created_hlc  TEXT NOT NULL,
  updated_hlc  TEXT NOT NULL
) STRICT;

CREATE INDEX pos_invoices_open ON pos_invoices (status, device, opened);
CREATE INDEX pos_invoices_closed ON pos_invoices (status, closed);

CREATE TABLE pos_lines (
  id          TEXT PRIMARY KEY,
  invoice_id  TEXT NOT NULL REFERENCES pos_invoices (id),
  position    INTEGER NOT NULL,
  product_id  TEXT,
  table_id    TEXT,
  tracked     INTEGER NOT NULL DEFAULT 0,
  name        TEXT NOT NULL,
  sku         TEXT,
  qty         INTEGER NOT NULL CHECK (qty > 0),
  price       INTEGER NOT NULL CHECK (price >= 0),
  list        INTEGER,
  discount    TEXT,
  tax_rate    TEXT NOT NULL
) STRICT;

CREATE INDEX pos_lines_invoice ON pos_lines (invoice_id, position);
CREATE INDEX pos_lines_table ON pos_lines (table_id);

-- The next ticket number of each device (POS-40): never reused, so it only grows.
CREATE TABLE pos_series (
  device_id TEXT PRIMARY KEY,
  next      INTEGER NOT NULL
) STRICT;
""");
