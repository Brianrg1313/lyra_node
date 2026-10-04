import '../migrations.dart';

/// The cloud's permission system (`session.md` session.permissions): the backend's per-person
/// document instead of a list of the app's area ids.
///
/// - `members`: one row per account. `access` is membership; `sections` the structure as JSON,
///   normalized to the catalog on write (null: no document, no permission); `template_*` where it
///   was copied from; `custom` changed by hand since.
/// - `permission_templates`: the company's own templates (the global ones are code,
///   `PermissionPresets`).
/// - `permission_requests`: an area id asked for, one pending per account and area.
/// - `meta.owner`: the account made at setup, `all` by measurement (S-6).
///
/// From `grants`: its `*` row is the owner; no op ever wrote anything else (the only rows were
/// tests'), so the rest is dropped. Everyone with an active job is admitted with no document
/// (P-5). The permissions stored on files and on events kept for replay were area ids; they become
/// the catalog keys those areas take (`business.view`, every member, reads as `business` for an
/// event already kept and as every member for a logo).
const m012Permissions = Migration(12, "permissions", r"""
CREATE TABLE members (
  account       TEXT PRIMARY KEY REFERENCES accounts (id),
  access        INTEGER NOT NULL DEFAULT 1,
  all_granted   INTEGER NOT NULL DEFAULT 0,
  sections      TEXT,
  template_kind TEXT CHECK (template_kind IN ('global', 'company')),
  template_id   TEXT,
  custom        INTEGER NOT NULL DEFAULT 0,
  updated       TEXT NOT NULL,
  updated_by    TEXT
) STRICT;

CREATE TABLE permission_templates (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  description TEXT,
  sections    TEXT NOT NULL,
  created     TEXT NOT NULL,
  created_by  TEXT
) STRICT;

CREATE UNIQUE INDEX permission_templates_name ON permission_templates (lower(name));

CREATE TABLE permission_requests (
  id      TEXT PRIMARY KEY,
  account TEXT NOT NULL REFERENCES accounts (id),
  area    TEXT NOT NULL,
  keys    TEXT NOT NULL,
  reason  TEXT,
  state   TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending')),
  created TEXT NOT NULL
) STRICT;

CREATE UNIQUE INDEX permission_requests_pending ON permission_requests (account, area) WHERE state = 'pending';
CREATE INDEX permission_requests_account ON permission_requests (account, created);

INSERT OR IGNORE INTO meta (key, value)
  SELECT 'owner', account FROM grants WHERE permission = '*' ORDER BY account LIMIT 1;

INSERT INTO members (account, access, all_granted, template_kind, template_id, updated)
  SELECT value, 1, 1, 'global', 'owner', strftime('%Y-%m-%dT%H:%M:%fZ', 'now') FROM meta WHERE key = 'owner';

INSERT OR IGNORE INTO members (account, access, updated)
  SELECT DISTINCT account, 1, strftime('%Y-%m-%dT%H:%M:%fZ', 'now') FROM employments WHERE state = 'active';

DROP TABLE grants;

UPDATE files SET permission = CASE permission
  WHEN 'business.view' THEN NULL
  WHEN 'inventory.view' THEN 'products'
  ELSE permission END
WHERE referenced = 1;

UPDATE events SET audience =
  replace(replace(replace(replace(replace(audience,
    '"business.view"', '"business"'),
    '"inventory.view"', '"products"'),
    '"pos.view"', '"pos"'),
    '"sales.view_all"', '"sales"'),
    '"sales.view"', '"sales"')
WHERE audience IS NOT NULL;
""");
