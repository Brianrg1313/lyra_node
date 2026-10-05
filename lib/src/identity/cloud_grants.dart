import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:sqlite3/sqlite3.dart';

import '../failure.dart';
import '../storage/store.dart';
import 'accounts.dart';

/// The cloud grant (`session.md` S-12, plan D14, `task-edge-sync-backend.md` §9): one session for
/// two homes. Someone signed in online on a device with this master gets a short statement from the
/// backend, signed with the edge key this master pinned when it enrolled, and opens their session
/// here with it instead of their password. It is checked offline, so a grant opens the master while
/// the internet is gone too, as long as it was fetched before.
///
/// Token: `base64url(payload) "." base64url(signature)`, Ed25519 over the payload's bytes; the payload
/// is UTF-8 JSON `{v, kid, device, company, account: {id, email}, nonce, iat, exp}`.
final class CloudGrants {
  CloudGrants(this._store, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Store _store;
  final DateTime Function() _now;

  static final _ed25519 = Ed25519();

  /// How far an `exp` may be behind this clock and still count.
  static const skew = Duration(seconds: 30);

  /// How far ahead of this clock an `iat` may be: the edge sync's own bound on clocks (§2).
  static const ahead = Duration(minutes: 5);

  /// The longest a grant may be good for; the backend issues two minutes.
  static const longest = Duration(minutes: 5);

  Database get _db => _store.db;

  /// The account [token] opens, its nonce spent. Refusals: `grant_invalid` (anything that doesn't
  /// check), `grant_expired`, `grant_used`, `grant_no_account` (no active account with its e-mail)
  /// and `account_disabled`.
  Future<Account> redeem(String token, Accounts accounts) async {
    final payload = await _verified(token);
    final now = _now().toUtc();

    final issued = DateTime.fromMillisecondsSinceEpoch((payload["iat"] as int) * 1000, isUtc: true);
    final expires = DateTime.fromMillisecondsSinceEpoch((payload["exp"] as int) * 1000, isUtc: true);

    if (issued.isAfter(now.add(ahead)) || expires.isBefore(issued) || expires.difference(issued) > longest) {
      throw const EngineFailure("grant_invalid");
    }
    if (expires.add(skew).isBefore(now)) throw const EngineFailure("grant_expired");

    final email = (payload["account"] as Map)["email"] as String;
    final row = _db.select(
      "SELECT id, status FROM accounts WHERE deleted = 0 AND email IS NOT NULL AND lower(email) = lower(?)",
      [email.trim()],
    ).firstOrNull;

    if (row == null || row["status"] == AccountStatus.pending.name) throw const EngineFailure("grant_no_account");
    if (row["status"] == AccountStatus.disabled.name) throw const EngineFailure("account_disabled");

    final id = row["id"] as String;

    _store.write((db) {
      db.execute("DELETE FROM grant_nonces WHERE expires < ?", [now.subtract(skew).toIso8601String()]);
      db.execute(
        "INSERT OR IGNORE INTO grant_nonces (nonce, expires) VALUES (?, ?)",
        [payload["nonce"], expires.add(skew).toIso8601String()],
      );
      if (db.updatedRows != 1) throw const EngineFailure("grant_used");

      db.execute("UPDATE accounts SET last_sign_in = ? WHERE id = ?", [now.toIso8601String(), id]);
    });

    return accounts.byId(id)!;
  }

  /// The payload, once its signature, its key, its device and its company are this master's.
  Future<Map<String, Object?>> _verified(String token) async {
    final link = _db.select("SELECT device, company, edge_keys, revoked FROM sync_link").firstOrNull;
    if (link == null || link["revoked"] == 1) throw const EngineFailure("grant_invalid");

    final parts = token.split(".");
    if (parts.length != 2 || token.length > 4096) throw const EngineFailure("grant_invalid");

    final List<int> bytes;
    final List<int> signature;
    final Object? payload;
    try {
      bytes = base64Url.decode(base64Url.normalize(parts[0]));
      signature = base64Url.decode(base64Url.normalize(parts[1]));
      payload = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const EngineFailure("grant_invalid");
    }

    if (payload is! Map<String, Object?> || payload["v"] != 1 || signature.length != 64) {
      throw const EngineFailure("grant_invalid");
    }

    final account = payload["account"];
    final nonce = payload["nonce"];
    if (payload["iat"] is! int || payload["exp"] is! int || account is! Map || account["email"] is! String ||
        nonce is! String || nonce.length < 16 || nonce.length > 64) {
      throw const EngineFailure("grant_invalid");
    }

    final keys = jsonDecode(link["edge_keys"] as String) as List;
    final kid = payload["kid"];
    final key = keys.whereType<Map>().where((key) => key["kid"] == kid).firstOrNull;
    if (key == null) throw const EngineFailure("grant_invalid");

    final valid = await _ed25519.verify(
      bytes,
      signature: Signature(signature, publicKey: SimplePublicKey(base64.decode(key["publicKey"] as String), type: KeyPairType.ed25519)),
    );

    if (!valid || payload["device"] != link["device"] || payload["company"] != link["company"]) {
      throw const EngineFailure("grant_invalid");
    }

    return payload;
  }
}
