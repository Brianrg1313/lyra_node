import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../audit/audit_log.dart';
import '../identity/accounts.dart';
import '../identity/permissions.dart';
import '../storage/store.dart';
import 'envelope.dart';
import 'recovery.dart';
import 'secrets.dart';

/// What a sealed key guards, and the permission that holds it (plan §6.3).
enum SealedScope {
  /// Employees' private fields and salaries.
  hr("business.employees.view_personal"),

  /// The holder, document and number of the company's payment accounts (`money.md` M-45).
  payments("finance.methods.view");

  const SealedScope(this.permission);

  final String permission;
}

/// An account's private key sealed under a new password, made before the write that changes the
/// password (Argon2 is slow) and saved inside it ([SealedKeys.save]).
final class AccountKeyWrap {
  const AccountKeyWrap._(this.account, this.private, this.salt, this.kdf);

  final String account;
  final Uint8List private;
  final Uint8List salt;
  final String kdf;
}

/// The sealed keys (plan §6.3): fields encrypted **again**, over the database's own key, so that
/// a stolen disk with a broken OS vault still can't read them.
///
/// - Each account has an X25519 pair. Its private half is sealed with a key stretched from the
///   person's password (Argon2id), so only that person's sign in opens it.
/// - Each scope has one random key, wrapped to the public key of every account that holds it,
///   and to the public key the recovery key derives (`meta.sealed_recovery`). Wrapping to a
///   public key needs nothing of the recipient, which is how a holder can share the key with
///   someone newly granted and how the recovery wrap is made with the recovery key away.
/// - The first holder to sign in makes the scope's key. Later holders get it from one who
///   already has it (a grant, `employees.md`); until then they can't read the scope.
/// - A session keeps the keys its sign in opened, sealed with a key derived from its refresh
///   token, which only the client holds (the engine keeps its hash). An engine restart doesn't
///   lock them, and the refresh that follows opens them again; a session that ends drops them.
///   A PIN session never has them (M-45).
final class SealedKeys {
  SealedKeys(this._store, {Argon2Params params = Argon2Params.standard, DateTime Function()? now})
    : _params = params,
      _now = now ?? DateTime.now;

  static const recoveryHolder = "recovery";
  static const _recoveryMeta = "sealed_recovery";

  static final X25519 _x25519 = X25519();

  final Store _store;
  final Argon2Params _params;
  final DateTime Function() _now;

  /// Session id → the scope keys it opened. In memory only.
  final Map<String, Map<SealedScope, Uint8List>> _open = {};

  /// After a password sign in of [account] ([sessionId], [refreshToken]): opens its key pair,
  /// making it on its first sign in, and the scope keys its grants hold, making a scope's key
  /// when nobody holds it yet.
  Future<void> signedIn(
    Account account,
    String password, {
    required String sessionId,
    required String refreshToken,
  }) async {
    final scopes = [
      for (final scope in SealedScope.values)
        if (Permissions.allows(account.grants, scope.permission)) scope,
    ];
    final hasPair = _store.db.select("SELECT 1 FROM account_keys WHERE account = ?", [account.id]).isNotEmpty;

    // Someone who holds no scope only needs a pair to be granted one later: made once, not
    // opened on every sign in (it costs an Argon2).
    if (scopes.isEmpty && hasPair) return;

    final pair = await _pair(account.id, password);
    final keys = <SealedScope, Uint8List>{};

    for (final scope in scopes) {
      final key = await _scopeKey(scope, account.id, pair);
      if (key != null) keys[scope] = key;
    }

    if (keys.isEmpty) return;

    _open[sessionId] = keys;
    await _keep(sessionId, refreshToken, keys);
  }

  /// After `auth.refresh` rotated [previous] into [next]: the session's keys move to the new
  /// token, keeping only the scopes [grants] still hold. This is also how they come back after an
  /// engine restart, since access tokens don't survive one and every client refreshes first.
  Future<void> refreshed(
    String sessionId, {
    required Set<String> grants,
    required String previous,
    required String next,
  }) async {
    final row = _store.db.select("SELECT sealed FROM sessions WHERE id = ? AND ended IS NULL", [sessionId]).firstOrNull;
    final sealed = row?["sealed"] as Uint8List?;
    if (sealed == null) return;

    final Map<SealedScope, Uint8List> keys;
    try {
      final clear = await Envelope.open(await _sessionKey(previous), sealed, context: _sessionContext(sessionId));
      keys = {
        for (final MapEntry(:key, :value) in (jsonDecode(utf8.decode(clear)) as Map<String, Object?>).entries)
          if (Permissions.allows(grants, SealedScope.values.byName(key).permission))
            SealedScope.values.byName(key): base64.decode(value as String),
      };
    } on EnvelopeError {
      _store.write((db) => db.execute("UPDATE sessions SET sealed = NULL WHERE id = ?", [sessionId]));
      return;
    }

    if (keys.isEmpty) {
      _open.remove(sessionId);
      _store.write((db) => db.execute("UPDATE sessions SET sealed = NULL WHERE id = ?", [sessionId]));
      return;
    }

    _open[sessionId] = keys;
    await _keep(sessionId, next, keys);
  }

  /// The [scope] key [sessionId] opened, or null: not signed in with a password, not a holder,
  /// a holder nobody shared the key with yet, or a session that ended.
  Uint8List? key(String sessionId, SealedScope scope) {
    final open = _store.db.select("SELECT 1 FROM sessions WHERE id = ? AND ended IS NULL", [sessionId]).isNotEmpty;
    if (!open) {
      _open.remove(sessionId);
      return null;
    }

    return _open[sessionId]?[scope];
  }

  /// First half of a password change (`session.md` S-9): [accountId]'s private key sealed under
  /// [password], or null when the account has no key pair yet (it gets one at its next sign in).
  Future<AccountKeyWrap?> rewrap(String accountId, {required String current, required String password}) async {
    final row = _store.db.select("SELECT * FROM account_keys WHERE account = ?", [accountId]).firstOrNull;
    if (row == null) return null;

    final seed = await _openPrivate(accountId, current, row);
    try {
      return await _sealPrivate(accountId, password, seed);
    } finally {
      wipe(seed);
    }
  }

  /// Second half: inside the write that changes the password.
  void save(AccountKeyWrap wrap) => _store.write((db) => db.execute(
    "UPDATE account_keys SET private = ?, salt = ?, kdf = ?, updated = ? WHERE account = ?",
    [wrap.private, wrap.salt, wrap.kdf, _now().toUtc().toIso8601String(), wrap.account],
  ));

  /// Forgets every key in memory (the engine closing).
  void dispose() {
    for (final keys in _open.values) {
      keys.values.forEach(wipe);
    }
    _open.clear();
  }

  /// Stores the public key [recovery] derives, so scope keys are wrapped to it too. At setup and
  /// at a recovery (a master set up before the sealed keys gets it then); never replaced.
  static Future<void> setRecovery(Store store, RecoveryKey recovery) async {
    final public = await (await _recoveryPair(recovery)).extractPublicKey();

    store.write((db) => db.execute(
      "INSERT OR IGNORE INTO meta (key, value) VALUES (?, ?)",
      [_recoveryMeta, base64.encode(public.bytes)],
    ));
  }

  /// The [scope] key opened with [recovery], or null when it was never wrapped to it. For a
  /// password reset through the recovery key, which wraps it again for the new password.
  static Future<Uint8List?> recover(Store store, SealedScope scope, RecoveryKey recovery) async {
    final row = store.db.select(
      "SELECT wrap FROM sealed_keys WHERE scope = ? AND holder = ?",
      [scope.name, recoveryHolder],
    ).firstOrNull;
    if (row == null) return null;

    return _unwrap(scope, recoveryHolder, await _recoveryPair(recovery), row["wrap"] as Uint8List);
  }

  /// [clear] sealed with a scope [key], for a column; [context] names the row and column, so a
  /// value copied into another row never opens there.
  static Future<Uint8List> sealJson(Uint8List key, Map<String, Object?> clear, {required String context}) =>
    Envelope.seal(key, utf8.encode(jsonEncode(clear)), context: context);

  static Future<Map<String, Object?>> openJson(Uint8List key, Uint8List sealed, {required String context}) async =>
    jsonDecode(utf8.decode(await Envelope.open(key, sealed, context: context))) as Map<String, Object?>;

  // ---------------------------------------------------------------- internals

  /// [accountId]'s key pair, opened with [password], or made and stored on its first sign in.
  Future<SimpleKeyPair> _pair(String accountId, String password) async {
    final row = _store.db.select("SELECT * FROM account_keys WHERE account = ?", [accountId]).firstOrNull;

    if (row != null) {
      final seed = await _openPrivate(accountId, password, row);
      try {
        return await _x25519.newKeyPairFromSeed(seed);
      } finally {
        wipe(seed);
      }
    }

    final seed = randomBytes(32);
    try {
      final pair = await _x25519.newKeyPairFromSeed(seed);
      final public = await pair.extractPublicKey();
      final wrap = await _sealPrivate(accountId, password, seed);

      final stored = _store.write((db) {
        db.execute(
          "INSERT OR IGNORE INTO account_keys (account, public, private, salt, kdf, updated) VALUES (?, ?, ?, ?, ?, ?)",
          [accountId, Uint8List.fromList(public.bytes), wrap.private, wrap.salt, wrap.kdf,
            _now().toUtc().toIso8601String()],
        );
        return db.updatedRows == 1;
      });

      // Two sign ins at once both made one: the stored one wins.
      return stored ? pair : await _pair(accountId, password);
    } finally {
      wipe(seed);
    }
  }

  /// The [scope] key for [accountId]: unwrapped from its own wrap, or made when nobody holds the
  /// scope yet. Null when others hold it and none shared it with this account.
  Future<Uint8List?> _scopeKey(SealedScope scope, String accountId, SimpleKeyPair pair) async {
    final rows = _store.db.select("SELECT holder, wrap FROM sealed_keys WHERE scope = ?", [scope.name]);
    final mine = rows.where((row) => row["holder"] == accountId).firstOrNull;

    if (mine != null) {
      final key = await _unwrap(scope, accountId, pair, mine["wrap"] as Uint8List);
      if (rows.every((row) => row["holder"] != recoveryHolder)) await _wrapForRecovery(scope, key);

      return key;
    }
    if (rows.isNotEmpty) return null;

    final key = randomBytes(32);
    final wrap = await _wrap(scope, accountId, await pair.extractPublicKey(), key);
    final recovery = await _recoveryPublic();
    final recoveryWrap = recovery == null ? null : await _wrap(scope, recoveryHolder, recovery, key);

    final made = _store.write((db) {
      if (db.select("SELECT 1 FROM sealed_keys WHERE scope = ?", [scope.name]).isNotEmpty) return false;

      final now = _now().toUtc().toIso8601String();
      db.execute("INSERT INTO sealed_keys (scope, holder, wrap, created) VALUES (?, ?, ?, ?)",
        [scope.name, accountId, wrap, now]);
      if (recoveryWrap != null) {
        db.execute("INSERT INTO sealed_keys (scope, holder, wrap, created) VALUES (?, ?, ?, ?)",
          [scope.name, recoveryHolder, recoveryWrap, now]);
      }
      AuditLog(db, now: _now).append(AuditKinds.sealedKeyCreated, actor: accountId, data: {
        "scope": scope.name,
        "recovery": recoveryWrap != null,
      });
      return true;
    });

    // Another holder's sign in made it first: read theirs.
    return made ? key : _scopeKey(scope, accountId, pair);
  }

  /// A master set up before the sealed keys has no recovery wrap until a recovery stores the
  /// public key; the next holder's sign in adds it.
  Future<void> _wrapForRecovery(SealedScope scope, Uint8List key) async {
    final recovery = await _recoveryPublic();
    if (recovery == null) return;

    final wrap = await _wrap(scope, recoveryHolder, recovery, key);
    _store.write((db) => db.execute(
      "INSERT OR IGNORE INTO sealed_keys (scope, holder, wrap, created) VALUES (?, ?, ?, ?)",
      [scope.name, recoveryHolder, wrap, _now().toUtc().toIso8601String()],
    ));
  }

  Future<SimplePublicKey?> _recoveryPublic() async {
    final row = _store.db.select("SELECT value FROM meta WHERE key = ?", [_recoveryMeta]).firstOrNull;

    return row == null ? null : SimplePublicKey(base64.decode(row["value"] as String), type: KeyPairType.x25519);
  }

  Future<void> _keep(String sessionId, String refreshToken, Map<SealedScope, Uint8List> keys) async {
    final clear = utf8.encode(jsonEncode({for (final MapEntry(:key, :value) in keys.entries) key.name: base64.encode(value)}));
    final sealed = await Envelope.seal(await _sessionKey(refreshToken), clear, context: _sessionContext(sessionId));

    _store.write((db) => db.execute("UPDATE sessions SET sealed = ? WHERE id = ? AND ended IS NULL", [sealed, sessionId]));
  }

  Future<Uint8List> _openPrivate(String accountId, String password, Map<String, Object?> row) async {
    final kek = await argon2id(
      password,
      row["salt"] as Uint8List,
      Argon2Params.fromJson(jsonDecode(row["kdf"] as String) as Map<String, Object?>),
    );
    try {
      return await Envelope.open(kek, row["private"] as Uint8List, context: _accountContext(accountId));
    } finally {
      wipe(kek);
    }
  }

  Future<AccountKeyWrap> _sealPrivate(String accountId, String password, Uint8List seed) async {
    final salt = randomBytes(16);
    final kek = await argon2id(password, salt, _params);
    try {
      return AccountKeyWrap._(
        accountId,
        await Envelope.seal(kek, seed, context: _accountContext(accountId)),
        salt,
        jsonEncode(_params.toJson()),
      );
    } finally {
      wipe(kek);
    }
  }

  /// [key] wrapped to [public]: an ephemeral X25519 agreement, its secret through HKDF, then
  /// AES-GCM. Stored as `ephemeral public (32) | envelope`.
  static Future<Uint8List> _wrap(SealedScope scope, String holder, SimplePublicKey public, List<int> key) async {
    final ephemeral = await _x25519.newKeyPair();
    final kek = await _agreed(ephemeral, public);
    try {
      final box = await Envelope.seal(kek, key, context: _wrapContext(scope, holder));
      final mine = await ephemeral.extractPublicKey();

      return Uint8List.fromList([...mine.bytes, ...box]);
    } finally {
      wipe(kek);
    }
  }

  static Future<Uint8List> _unwrap(SealedScope scope, String holder, SimpleKeyPair pair, Uint8List wrap) async {
    if (wrap.length < 32) throw const EnvelopeError();

    final kek = await _agreed(pair, SimplePublicKey(wrap.sublist(0, 32), type: KeyPairType.x25519));
    try {
      return await Envelope.open(kek, wrap.sublist(32), context: _wrapContext(scope, holder));
    } finally {
      wipe(kek);
    }
  }

  static Future<Uint8List> _agreed(SimpleKeyPair pair, SimplePublicKey other) async {
    final shared = await _x25519.sharedSecretKey(keyPair: pair, remotePublicKey: other);

    return subkey(await shared.extractBytes(), "lyra/sealed/wrap/v1");
  }

  static Future<SimpleKeyPair> _recoveryPair(RecoveryKey recovery) async =>
    _x25519.newKeyPairFromSeed(await subkey(recovery.entropy, "lyra/sealed/recovery/v1"));

  static Future<Uint8List> _sessionKey(String refreshToken) =>
    subkey(utf8.encode(refreshToken), "lyra/sealed/session/v1");

  static String _accountContext(String accountId) => "lyra/sealed/account/$accountId";

  static String _wrapContext(SealedScope scope, String holder) => "lyra/sealed/${scope.name}/$holder";

  static String _sessionContext(String sessionId) => "lyra/sealed/session/$sessionId";
}
