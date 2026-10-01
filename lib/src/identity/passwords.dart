import 'dart:convert';

import '../crypto/secrets.dart';

/// Password and PIN hashes (`session.md` S-3), stored as PHC strings:
/// `$argon2id$v=19$m=65536,t=3,p=1$<salt>$<hash>` (unpadded base64). The parameters travel with
/// the hash, so raising [Argon2Params.standard] leaves old hashes readable and [needsRehash]
/// says which to rewrite on the next successful sign in.
final class PasswordHasher {
  const PasswordHasher({this.params = Argon2Params.standard});

  final Argon2Params params;

  Future<String> hash(String password) async {
    final salt = randomBytes(16);
    final digest = await argon2id(password, salt, params);

    return "\$argon2id\$v=19\$m=${params.memory},t=${params.iterations},p=${params.parallelism}"
      "\$${_b64(salt)}\$${_b64(digest)}";
  }

  /// Whether [password] matches [phc]. A string that isn't one of ours never matches.
  Future<bool> verify(String password, String phc) async {
    final parsed = parse(phc);
    if (parsed == null) return false;

    final digest = await argon2id(password, parsed.salt, parsed.params, length: parsed.hash.length);

    return constantTimeEquals(digest, parsed.hash);
  }

  bool needsRehash(String phc) => parse(phc)?.params.isWeakerThan(params) ?? true;

  /// The parts of [phc], or null when it isn't one of ours.
  static ({Argon2Params params, List<int> salt, List<int> hash})? parse(String phc) {
    final match = RegExp(
      r"^\$argon2id\$v=19\$m=(\d+),t=(\d+),p=(\d+)\$([A-Za-z0-9+/]+)\$([A-Za-z0-9+/]+)$",
    ).firstMatch(phc);
    if (match == null) return null;

    try {
      return (
        params: Argon2Params(
          memory: int.parse(match.group(1)!),
          iterations: int.parse(match.group(2)!),
          parallelism: int.parse(match.group(3)!),
        ),
        salt: base64.decode(base64.normalize(match.group(4)!)),
        hash: base64.decode(base64.normalize(match.group(5)!)),
      );
    } on FormatException {
      return null;
    }
  }

  static String _b64(List<int> bytes) => base64.encode(bytes).replaceAll("=", "");
}
