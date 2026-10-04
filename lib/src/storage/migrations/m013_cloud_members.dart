import '../migrations.dart';

/// Who may do what as the cloud says (`session.md` P-12): the edge sync's `member` entity, kept
/// by the cloud account's id, whether or not that person has an account on this master yet.
///
/// - `sync_members`: the cloud's last document per person (`access`, `all_granted`, `sections` as
///   JSON, `template` as `{scope, id}` JSON, `custom`) and the e-mail it is found by here. It is
///   laid onto `members` when the person has an account here, and when they are admitted later.
const m013CloudMembers = Migration(13, "cloud members", r"""
CREATE TABLE sync_members (
  cloud_id    TEXT PRIMARY KEY,
  email       TEXT,
  access      INTEGER NOT NULL DEFAULT 0,
  all_granted INTEGER NOT NULL DEFAULT 0,
  sections    TEXT,
  template    TEXT,
  custom      INTEGER NOT NULL DEFAULT 0,
  updated_hlc TEXT NOT NULL
) STRICT;

CREATE INDEX sync_members_email ON sync_members (lower(email));
""");
