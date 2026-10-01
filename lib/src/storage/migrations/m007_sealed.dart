import '../migrations.dart';

/// The sealed keys (plan §6.3): a second layer over the database's own encryption for the fields
/// only some people may read.
///
/// `account_keys`: each account's X25519 pair, its private half sealed with a key stretched from
/// that person's password (Argon2id, `kdf` and `salt` beside it). `sealed_keys`: each scope's key
/// (`hr`, `payments`) wrapped once per holder to that holder's public key, `holder` being an
/// account id or `recovery` (the public key the recovery key derives, `meta.sealed_recovery`).
/// `sessions.sealed`: the scope keys a session unlocked at its sign in, sealed with a key derived
/// from its refresh token, which only the client holds; so a restart doesn't lock them, and a disk
/// without that token can't open them.
const m007Sealed = Migration(7, "sealed", r"""
CREATE TABLE account_keys (
  account TEXT PRIMARY KEY REFERENCES accounts (id),
  public  BLOB NOT NULL,
  private BLOB NOT NULL,
  salt    BLOB NOT NULL,
  kdf     TEXT NOT NULL,
  updated TEXT NOT NULL
) STRICT;

CREATE TABLE sealed_keys (
  scope   TEXT NOT NULL CHECK (scope IN ('hr', 'payments')),
  holder  TEXT NOT NULL,
  wrap    BLOB NOT NULL,
  created TEXT NOT NULL,
  PRIMARY KEY (scope, holder)
) STRICT;

ALTER TABLE sessions ADD COLUMN sealed BLOB;
""");
