import '../migrations.dart';

/// The company's staff (`employees.md`) and the activation of invited accounts (`session.md` S-8).
///
/// - `employments`: one row per stint of an account at the company. The job is plain; `state` is
///   the only stored lifecycle, the rest (work status, contract status, tenure) is measured on read
///   (E-4). The site is the company's one, so no branch is stored.
/// - `sealed_fields`: one row per sealed value (a job's pay and notes, a person's private
///   profile), so writing one needs nobody's key and never rewrites another. `hr` is sealed to the
///   `hr` scope's public key, `own` to the person's (null for `NOTES`, and while the person has no
///   key pair yet). `entity` is `employment` (by employment id) or `person` (by account id).
/// - `activations`: the live code of a pending account, as a hash. One use, 72 hours, voided after
///   [Employees.maxActivationFailures] wrong tries.
const m009Employees = Migration(9, "employees", r"""
CREATE TABLE employments (
  id          TEXT PRIMARY KEY,
  account     TEXT NOT NULL REFERENCES accounts (id),
  state       TEXT NOT NULL CHECK (state IN ('invited', 'active', 'ended', 'declined', 'cancelled')),
  job_title   TEXT NOT NULL,
  department  TEXT,
  code        TEXT,
  manager     TEXT REFERENCES employments (id),
  contract    TEXT,
  workday     TEXT,
  start_date  TEXT,
  end_date    TEXT,
  work_email  TEXT,
  work_phone  TEXT,
  invited     TEXT NOT NULL,
  invited_by  TEXT,
  responded   TEXT,
  ended_date  TEXT,
  end_reason  TEXT,
  end_note    TEXT,
  created_hlc TEXT NOT NULL,
  updated_hlc TEXT NOT NULL,
  origin      TEXT
) STRICT;

CREATE INDEX employments_account ON employments (account, state);

CREATE TABLE sealed_fields (
  entity    TEXT NOT NULL CHECK (entity IN ('employment', 'person')),
  entity_id TEXT NOT NULL,
  field     TEXT NOT NULL,
  hr        BLOB NOT NULL,
  own       BLOB,
  updated   TEXT NOT NULL,
  PRIMARY KEY (entity, entity_id, field)
) STRICT;

CREATE TABLE activations (
  account  TEXT PRIMARY KEY REFERENCES accounts (id),
  code     TEXT NOT NULL,
  expires  TEXT NOT NULL,
  failures INTEGER NOT NULL DEFAULT 0
) STRICT;
""");
