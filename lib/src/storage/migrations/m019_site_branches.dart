import '../migrations.dart';

/// A master is one site of its cloud company (the backend's branches):
///
/// - `site_prices`: a product's own price at this site where it is not the catalog's (the edge
///   `price`, pulled only, `pos.md` POS-7b). `price` and `discount` are decimal text as the cloud
///   sends them; `inherits_discount` 1 leaves the product's `DISCOUNT` cell in force. Kept by the
///   product, one row each; `deleted` when the site went back to the catalog's.
/// - `sync_members.branches`: the cloud site ids the person may work in, JSON, null for every one;
///   `sync_members.at`: the structure that replaces the base in a site, JSON by site id
///   (`session.md`).
const m019SiteBranches = Migration(19, "site branches", r"""
CREATE TABLE site_prices (
  id                TEXT PRIMARY KEY,
  product_id        TEXT NOT NULL,
  price             TEXT,
  discount          TEXT,
  inherits_discount INTEGER NOT NULL DEFAULT 1,
  deleted           INTEGER NOT NULL DEFAULT 0,
  updated_hlc       TEXT NOT NULL
) STRICT;

CREATE INDEX site_prices_product ON site_prices (product_id) WHERE deleted = 0;

ALTER TABLE sync_members ADD COLUMN branches TEXT;
ALTER TABLE sync_members ADD COLUMN at TEXT NOT NULL DEFAULT '{}';
""");
