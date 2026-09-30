import '../migrations.dart';

/// The company and its one site (`business.md`, plan D6). One row each: the `one` column can only
/// hold 1 and is unique, so a second company can't exist even by mistake.
///
/// A site point is stored in millionths of a degree (B-11: 6 decimals), so no rounding of a
/// `REAL` ever moves it.
const m003Business = Migration(3, "business", r"""
CREATE TABLE company (
  id                 TEXT PRIMARY KEY,
  one                INTEGER NOT NULL DEFAULT 1 UNIQUE CHECK (one = 1),
  name               TEXT NOT NULL,
  legal_name         TEXT,
  nickname           TEXT,
  caption            TEXT,
  logo               TEXT REFERENCES files (id),
  activity           TEXT,
  tax_id             TEXT,
  country            TEXT NOT NULL,
  language           TEXT NOT NULL,
  currency           TEXT NOT NULL,
  phone              TEXT,
  website            TEXT,
  incorporation_date TEXT,
  timezone           TEXT,
  created            TEXT NOT NULL,
  created_hlc        TEXT NOT NULL,
  updated_hlc        TEXT NOT NULL,
  deleted            INTEGER NOT NULL DEFAULT 0,
  origin             TEXT
) STRICT;

CREATE TABLE site (
  id          TEXT PRIMARY KEY,
  one         INTEGER NOT NULL DEFAULT 1 UNIQUE CHECK (one = 1),
  name        TEXT NOT NULL,
  legal_name  TEXT,
  tax_id      TEXT,
  phone       TEXT,
  address     TEXT,
  landmark    TEXT,
  city        TEXT,
  region      TEXT,
  postal_code TEXT,
  latitude    INTEGER,
  longitude   INTEGER,
  storefront  INTEGER NOT NULL DEFAULT 1,
  online      INTEGER NOT NULL DEFAULT 0,
  created_hlc TEXT NOT NULL,
  updated_hlc TEXT NOT NULL,
  deleted     INTEGER NOT NULL DEFAULT 0,
  origin      TEXT,
  CHECK ((latitude IS NULL) = (longitude IS NULL))
) STRICT;
""");
