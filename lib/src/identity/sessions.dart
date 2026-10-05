import 'dart:convert';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../audit/audit_log.dart';
import '../failure.dart';
import '../ids.dart';
import '../storage/store.dart';

enum SessionScope {
  full,

  /// Opened with a PIN: `pos.*` ops only (`session.md` S-22).
  pos,
}

/// What `auth.signIn` and `auth.refresh` answer.
final class SessionTokens {
  const SessionTokens({
    required this.sessionId,
    required this.accessToken,
    required this.accessExpires,
    required this.refreshToken,
    required this.refreshExpires,
  });

  final String sessionId;
  final String accessToken;
  final DateTime accessExpires;
  final String refreshToken;
  final DateTime refreshExpires;

  Map<String, Object?> toJson() => {
    "accessToken": accessToken,
    "accessExpires": accessExpires.toUtc().toIso8601String(),
    "refreshToken": refreshToken,
    "refreshExpires": refreshExpires.toUtc().toIso8601String(),
  };
}

/// What an access token stands for.
final class SessionGrant {
  const SessionGrant({
    required this.sessionId,
    required this.accountId,
    required this.deviceId,
    required this.scope,
    required this.expires,
  });

  final String sessionId;
  final String accountId;
  final String deviceId;
  final SessionScope scope;
  final DateTime expires;
}

/// Sessions (`session.md` session.session): one account on one device.
///
/// Access tokens live **only in memory** (15 minutes, S-21): an engine restart forgets them and
/// clients refresh. Refresh tokens are stored as SHA-256 hashes, rotated on every use; a spent
/// one coming back ends its whole session, because only a copy can present it twice.
final class Sessions {
  Sessions(this._store, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const accessLifetime = Duration(minutes: 15);
  static const refreshLifetime = Duration(days: 30);
  static const posRefreshLifetime = Duration(hours: 16);

  final Store _store;
  final DateTime Function() _now;
  final Map<String, SessionGrant> _access = {};

  Database get _db => _store.db;

  /// Opens a session for [accountId] on [deviceId] after a successful sign in.
  SessionTokens open({required String accountId, required String deviceId, SessionScope scope = SessionScope.full}) {
    final id = newId();
    final refresh = _token();
    final now = _now().toUtc();
    final refreshExpires = now.add(scope == SessionScope.pos ? posRefreshLifetime : refreshLifetime);

    _store.write((db) {
      db.execute(
        "INSERT INTO sessions (id, account, device, scope, refresh_hash, refresh_expires, created, last_used) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [id, accountId, deviceId, scope.name, _hash(refresh), refreshExpires.toIso8601String(),
          now.toIso8601String(), now.toIso8601String()],
      );
      AuditLog(db, now: _now).append(AuditKinds.signedIn, actor: accountId, device: deviceId, data: {
        "session": id,
        "scope": scope.name,
      });
    });

    return _grant(id, accountId, deviceId, scope, refresh, refreshExpires);
  }

  /// The live session behind [accessToken], or null (unknown, expired or ended).
  SessionGrant? access(String accessToken) {
    final grant = _access[_hash(accessToken)];

    if (grant == null) return null;
    if (!grant.expires.isAfter(_now())) {
      _access.remove(_hash(accessToken));
      return null;
    }

    return grant;
  }

  /// Rotates [refreshToken] (S-21). It must come from the device the session belongs to (S-20).
  SessionTokens refresh(String refreshToken, {required String deviceId}) {
    final hash = _hash(refreshToken);

    // The write commits what it found (a reuse ends the session) before the refusal is thrown:
    // throwing inside it would roll that back.
    final outcome = _store.write<Object>((db) {
      final spent = db.select("SELECT session FROM refresh_spent WHERE hash = ?", [hash]);

      if (spent.isNotEmpty) {
        final session = spent.first["session"] as String;
        _end(db, session, "refresh_reused");
        AuditLog(db, now: _now).append(AuditKinds.refreshReused, device: deviceId, data: {"session": session});

        return const EngineFailure(ErrorCodes.sessionRevoked);
      }

      final rows = db.select("SELECT * FROM sessions WHERE refresh_hash = ? AND ended IS NULL", [hash]);
      if (rows.isEmpty) return const EngineFailure(ErrorCodes.sessionExpired);

      final row = rows.first;
      final id = row["id"] as String;

      if (row["device"] != deviceId) return const EngineFailure(ErrorCodes.sessionRevoked);
      if (!DateTime.parse(row["refresh_expires"] as String).isAfter(_now())) {
        _end(db, id, "expired");
        return const EngineFailure(ErrorCodes.sessionExpired);
      }

      final scope = SessionScope.values.byName(row["scope"] as String);
      final next = _token();
      final now = _now().toUtc();
      final refreshExpires = now.add(scope == SessionScope.pos ? posRefreshLifetime : refreshLifetime);

      db.execute("INSERT INTO refresh_spent (hash, session, spent) VALUES (?, ?, ?)", [hash, id, now.toIso8601String()]);
      db.execute(
        "UPDATE sessions SET refresh_hash = ?, refresh_expires = ?, last_used = ? WHERE id = ?",
        [_hash(next), refreshExpires.toIso8601String(), now.toIso8601String(), id],
      );
      // The previous access token goes with the rotation.
      _access.removeWhere((_, grant) => grant.sessionId == id);

      return _grant(id, row["account"] as String, deviceId, scope, next, refreshExpires);
    });

    if (outcome is EngineFailure) throw outcome;

    return outcome as SessionTokens;
  }

  /// Signs out one session.
  void end(String sessionId, {String reason = "signed_out"}) {
    _store.write((db) => _end(db, sessionId, reason));
  }

  /// Ends every open session of [accountId] but [except] (a password change, S-9). Answers the
  /// ended ids, so the server can drop their bindings.
  List<String> endForAccount(String accountId, {String? except, required String reason}) => _store.write((db) {
    final ids = [
      for (final row in db.select("SELECT id FROM sessions WHERE account = ? AND ended IS NULL", [accountId]))
        if (row["id"] != except) row["id"] as String,
    ];
    for (final id in ids) {
      _end(db, id, reason);
    }

    return ids;
  });

  /// Inside a device's revocation: ends its sessions in the same write (S-41). The in-memory
  /// access tokens go with [forgetDevice].
  static void endForDevice(Database db, String deviceId, {required String reason, required DateTime now}) {
    db.execute(
      "UPDATE sessions SET ended = ?, end_reason = ?, sealed = NULL WHERE device = ? AND ended IS NULL",
      [now.toUtc().toIso8601String(), reason, deviceId],
    );
  }

  /// Drops the access tokens of [deviceId] (after its revocation committed).
  void forgetDevice(String deviceId) => _access.removeWhere((_, grant) => grant.deviceId == deviceId);

  /// The account of the open session [refreshToken] refreshes on [deviceId], without rotating it:
  /// what `auth.unseal` checks the password of before it rotates (S-13). Null otherwise.
  String? accountOfRefresh(String refreshToken, {required String deviceId}) => _db.select(
    "SELECT account FROM sessions WHERE refresh_hash = ? AND device = ? AND ended IS NULL AND refresh_expires > ?",
    [_hash(refreshToken), deviceId, _now().toUtc().toIso8601String()],
  ).firstOrNull?["account"] as String?;

  /// The account [sessionId] belongs to, or null when there is no such session.
  String? accountOf(String sessionId) =>
    _db.select("SELECT account FROM sessions WHERE id = ?", [sessionId]).firstOrNull?["account"] as String?;

  /// Whether [sessionId] is still open (a bound connection checks it on every frame, S-23).
  bool isOpen(String sessionId) =>
    _db.select("SELECT 1 FROM sessions WHERE id = ? AND ended IS NULL", [sessionId]).isNotEmpty;

  void _end(Database db, String sessionId, String reason) {
    db.execute(
      "UPDATE sessions SET ended = ?, end_reason = ?, sealed = NULL WHERE id = ? AND ended IS NULL",
      [_now().toUtc().toIso8601String(), reason, sessionId],
    );
    _access.removeWhere((_, grant) => grant.sessionId == sessionId);
  }

  SessionTokens _grant(
    String sessionId,
    String accountId,
    String deviceId,
    SessionScope scope,
    String refresh,
    DateTime refreshExpires,
  ) {
    final access = _token();
    final expires = _now().toUtc().add(accessLifetime);

    _access[_hash(access)] = SessionGrant(
      sessionId: sessionId,
      accountId: accountId,
      deviceId: deviceId,
      scope: scope,
      expires: expires,
    );

    return SessionTokens(
      sessionId: sessionId,
      accessToken: access,
      accessExpires: expires,
      refreshToken: refresh,
      refreshExpires: refreshExpires,
    );
  }

  static String _token() => base64Url.encode(Hashes.random(32)).replaceAll("=", "");

  static String _hash(String token) => Hashes.hex(Hashes.sha256(utf8.encode(token)));
}
