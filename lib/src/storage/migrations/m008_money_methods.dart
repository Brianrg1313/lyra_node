import '../migrations.dart';

/// The company's payment accounts (`money.md` money.method).
///
/// `holder`, `document` and `account` are one JSON object in `sealed`, encrypted with the
/// `payments` sealed key (M-45); the rest is plain. `code` is the rail and never changes (M-40);
/// `method` is its settlement kind, copied so a payment's check doesn't need the catalogue.
/// `currency` null is the main currency. A fixed fee is an amount of the account's currency and a
/// percent a percent, both kept as decimal text (`1.5`, `2.5`). Removing sets `active` 0 (M-44).
const m008MoneyMethods = Migration(8, "money_methods", r"""
CREATE TABLE money_methods (
  id           TEXT PRIMARY KEY,
  code         TEXT NOT NULL,
  method       TEXT NOT NULL,
  label        TEXT,
  institution  TEXT,
  sealed       BLOB,
  instructions TEXT,
  currency     TEXT,
  fee_type     TEXT NOT NULL DEFAULT 'none' CHECK (fee_type IN ('none', 'fixed', 'percent')),
  fee_fixed    TEXT,
  fee_percent  TEXT,
  position     INTEGER NOT NULL,
  active       INTEGER NOT NULL DEFAULT 1,
  created      TEXT NOT NULL,
  created_hlc  TEXT NOT NULL,
  updated_hlc  TEXT NOT NULL
) STRICT;

CREATE INDEX money_methods_active ON money_methods (active, position);
""");
