import '../migrations.dart';

/// Money recorded by hand and the exchange currencies (`money.md`).
///
/// A payment is never edited or deleted: a void keeps the row (M-8). `amount` is in minor units of
/// `currency`, the company's main one when it was written (M-5). `ticket_id` is the invoice a
/// payment names (M-6), whose code is read from `pos_invoices` when answered. `date` is when the
/// money moved and `created` when it was typed in; both are instants to the millisecond, so they
/// compare as text.
const m006Money = Migration(6, "money", r"""
CREATE TABLE money_payments (
  id            TEXT PRIMARY KEY,
  concept       TEXT NOT NULL,
  direction     TEXT NOT NULL CHECK (direction IN ('in', 'out')),
  amount        INTEGER NOT NULL CHECK (amount > 0),
  currency      TEXT NOT NULL,
  method        TEXT NOT NULL,
  account_id    TEXT,
  reference     TEXT,
  counterpart   TEXT,
  ticket_id     TEXT REFERENCES pos_invoices (id),
  note          TEXT,
  date          TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'recorded' CHECK (status IN ('recorded', 'voided')),
  void_reason   TEXT,
  voided_by     TEXT,
  voided_at     TEXT,
  registered_by TEXT NOT NULL,
  device        TEXT,
  created       TEXT NOT NULL,
  created_hlc   TEXT NOT NULL,
  updated_hlc   TEXT NOT NULL
) STRICT;

CREATE INDEX money_payments_date ON money_payments (date, id);
CREATE INDEX money_payments_ticket ON money_payments (ticket_id) WHERE ticket_id IS NOT NULL;

-- The exchange currencies (M-50 to M-53): one row per currency ever added, `active` 0 once taken
-- off, so adding it again brings the same row back with its custom figure. A rate is not money: it
-- is `1 main = rate`, kept as a real.
CREATE TABLE money_currencies (
  currency    TEXT PRIMARY KEY,
  mode        TEXT NOT NULL CHECK (mode IN ('official', 'custom')),
  custom      REAL CHECK (custom IS NULL OR custom > 0),
  active      INTEGER NOT NULL DEFAULT 1,
  updated_hlc TEXT NOT NULL
) STRICT;
""");
