import '../migrations.dart';

/// How and where the company delivers (`deliveries.md`).
///
/// The settings live on the company, as in the cloud: `delivers` and `pickup` are three-state (null
/// is "has not said", D-1), `meeting_point` two-state and off. An option or an area is a row each;
/// removing sets `deleted`, which the sync carries as a delete.
///
/// Money is in minor units of the company's currency, distances in metres and a point in millionths
/// of a degree, so no `REAL` rounding ever moves a fee or an outline. `zones` is a JSON list of
/// `{name, fee}`; `polygon` one of `[latitude, longitude]` pairs, open.
const m015Deliveries = Migration(15, "deliveries", r"""
ALTER TABLE company ADD COLUMN delivers INTEGER CHECK (delivers IN (0, 1));
ALTER TABLE company ADD COLUMN pickup INTEGER CHECK (pickup IN (0, 1));
ALTER TABLE company ADD COLUMN meeting_point INTEGER NOT NULL DEFAULT 0 CHECK (meeting_point IN (0, 1));
ALTER TABLE company ADD COLUMN delivery_notes TEXT;

CREATE TABLE delivery_options (
  id          TEXT PRIMARY KEY,
  mode        TEXT NOT NULL CHECK (mode IN ('own', 'platform', 'courier')),
  provider    TEXT,
  label       TEXT,
  coverage    TEXT NOT NULL CHECK (coverage IN ('local', 'national', 'international')),
  radius      INTEGER,
  zones       TEXT,
  fee         INTEGER,
  free_from   INTEGER,
  eta_min     INTEGER,
  eta_max     INTEGER,
  notes       TEXT,
  position    INTEGER NOT NULL DEFAULT 100,
  created     TEXT NOT NULL,
  created_hlc TEXT NOT NULL,
  updated_hlc TEXT NOT NULL,
  deleted     INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE INDEX delivery_options_live ON delivery_options (deleted, position);

CREATE TABLE delivery_areas (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  kind        TEXT NOT NULL CHECK (kind IN ('radius', 'polygon')),
  latitude    INTEGER,
  longitude   INTEGER,
  radius      INTEGER,
  polygon     TEXT,
  fee         INTEGER,
  minimum     INTEGER,
  active      INTEGER NOT NULL DEFAULT 1,
  position    INTEGER NOT NULL DEFAULT 100,
  created     TEXT NOT NULL,
  created_hlc TEXT NOT NULL,
  updated_hlc TEXT NOT NULL,
  deleted     INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE INDEX delivery_areas_live ON delivery_areas (deleted, position);
""");
