import '../migrations.dart';

/// The cloud grants already used (`session.md` S-12): a grant opens one session, so its nonce is
/// kept until the grant has expired. A restart inside those two minutes must not make it new again,
/// hence a table and not memory.
const m016CloudGrants = Migration(16, "cloud grants", r"""
CREATE TABLE grant_nonces (
  nonce   TEXT PRIMARY KEY,
  expires TEXT NOT NULL
) STRICT;
""");
