import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:lyra_protocol/lyra_protocol.dart' show Grant;

import '../audit/audit_log.dart';
import '../identity/accounts.dart';
import '../identity/grants.dart';
import '../storage/store.dart';
import 'envelope.dart';
import 'recovery.dart';
import 'secrets.dart';

/// What a sealed key guards, and the catalog key that holds it (plan §6.3, `session.md` P-9):
/// what the cloud requires for the screens that show those fields.
enum SealedScope {
  /// Employees' private fields and salaries.
  hr("employees"),

  /// The holder, document and number of the company's payment accounts (`money.md` M-45).
  payments("money");

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
/// - A person's own private data is theirs to read and write without holding the scope
///   (`employees.md` E-3, E-13). So a scope key also derives an X25519 pair whose public half is
///   in `meta`, and such a value is sealed twice, needing no key at all: to the scope's public key
///   ([sealToScope]) and to the person's ([sealToAccount]). The session keeps the account's
///   private key next to its scope keys ([own]), which is why every password sign in opens the
///   pair, holder or not.
final class SealedKeys {
  SealedKeys(this._store, {Argon2Params params = Argon2Params.standard, DateTime Function()? now})
    : _params = params,
      _now = now ?? DateTime.now;

  static const recoveryHolder = "recovery";
  static const _recoveryMeta = "sealed_recovery";

  /// The session copy's entry for the account's own private key, beside the scopes' names.
  static const _ownEntry = "own";

  static final X25519 _x25519 = X25519();

  final Store _store;
  final Argon2Params _params;
  final DateTime Function() _now;

  /// Session id → the scope keys it opened. In memory only.
  final Map<String, Map<SealedScope, Uint8List>> _open = {};

  /// Session id → its account's private key (the X25519 seed). In memory only.
  final Map<String, Uint8List> _own = {};

  /// A scope's pair, derived from its key once (the key never changes).
  final Map<SealedScope, SimpleKeyPair> _scopePairs = {};

  /// After a password sign in of [account] ([sessionId], [refreshToken]): opens its key pair,
  /// making it on its first sign in, and the scope keys its grants hold, making a scope's key
  /// when nobody holds it yet. Opening the pair costs an Argon2 on every sign in: the session
  /// needs it to read the person's own sealed data.
  Future<void> signedIn(
    Account account,
    String password, {
    required String sessionId,
    required String refreshToken,
  }) async {
    final scopes = [
      for (final scope in SealedScope.values)
        if (account.grant.can(scope.permission)) scope,
    ];

    final pair = await _pair(account.id, password);
    final keys = <SealedScope, Uint8List>{};

    for (final scope in scopes) {
      final key = await _scopeKey(scope, account.id, pair);
      if (key != null) keys[scope] = key;
    }

    final own = Uint8List.fromList(await pair.extractPrivateKeyBytes());

    _open[sessionId] = keys;
    _own[sessionId] = own;
    await _keep(sessionId, refreshToken, keys, own);
    for (final MapEntry(:key, :value) in keys.entries) {
      await share(key, value);
    }
  }

  /// After `auth.refresh` rotated [previous] into [next]: the session's keys move to the new
  /// token, keeping only the scopes [grant] still holds. This is also how they come back after an
  /// engine restart, since access tokens don't survive one and every client refreshes first.
  Future<void> refreshed(
    String sessionId, {
    required Grant grant,
    required String previous,
    required String next,
  }) async {
    final row = _store.db.select("SELECT sealed FROM sessions WHERE id = ? AND ended IS NULL", [sessionId]).firstOrNull;
    final sealed = row?["sealed"] as Uint8List?;
    if (sealed == null) return;

    final Map<SealedScope, Uint8List> keys;
    final Uint8List? own;
    try {
      final clear = await Envelope.open(await _sessionKey(previous), sealed, context: _sessionContext(sessionId));
      final entries = jsonDecode(utf8.decode(clear)) as Map<String, Object?>;
      keys = {
        for (final MapEntry(:key, :value) in entries.entries)
          if (key != _ownEntry && grant.can(SealedScope.values.byName(key).permission))
            SealedScope.values.byName(key): base64.decode(value as String),
      };
      own = entries[_ownEntry] is String ? base64.decode(entries[_ownEntry]! as String) : null;
    } on EnvelopeError {
      _store.write((db) => db.execute("UPDATE sessions SET sealed = NULL WHERE id = ?", [sessionId]));
      return;
    }

    if (keys.isEmpty && own == null) {
      _open.remove(sessionId);
      _own.remove(sessionId);
      _store.write((db) => db.execute("UPDATE sessions SET sealed = NULL WHERE id = ?", [sessionId]));
      return;
    }

    _open[sessionId] = keys;
    if (own != null) _own[sessionId] = own;
    for (final MapEntry(:key, :value) in keys.entries) {
      await _scopePair(key, value);
    }
    await _keep(sessionId, next, keys, own);
    for (final MapEntry(:key, :value) in keys.entries) {
      await share(key, value);
    }
  }

  /// Wraps [scope]'s [key] to every account that holds the scope, has a key pair and no wrap yet
  /// (`session.md` P-9): a member given the permission gets the key from whichever holder's
  /// session has it next, the assigner's own at once.
  Future<void> share(SealedScope scope, Uint8List key) async {
    final rows = _store.db.select(
      "SELECT k.account, k.public FROM account_keys k "
      "LEFT JOIN sealed_keys s ON s.scope = ? AND s.holder = k.account WHERE s.holder IS NULL",
      [scope.name],
    );

    for (final row in rows) {
      final account = row["account"] as String;
      if (!Grants.of(_store.db, account).can(scope.permission)) continue;

      final wrap = await _wrap(scope, account, SimplePublicKey(row["public"] as Uint8List, type: KeyPairType.x25519), key);
      _store.write((db) => db.execute(
        "INSERT OR IGNORE INTO sealed_keys (scope, holder, wrap, created) VALUES (?, ?, ?, ?)",
        [scope.name, account, wrap, _now().toUtc().toIso8601String()],
      ));
    }
  }

  /// Deletes [account]'s wraps of the scopes it no longer holds (P-9). Their open sessions drop
  /// those keys at their next refresh, which keeps only what the grant still holds.
  void unshare(String account) {
    final grant = Grants.of(_store.db, account);

    for (final scope in SealedScope.values) {
      if (grant.can(scope.permission)) continue;

      _store.write((db) => db.execute("DELETE FROM sealed_keys WHERE scope = ? AND holder = ?", [scope.name, account]));
      for (final MapEntry(key: session, value: keys) in _open.entries) {
        if (_store.db.select("SELECT 1 FROM sessions WHERE id = ? AND account = ?", [session, account]).isNotEmpty) {
          final dropped = keys.remove(scope);
          if (dropped != null) wipe(dropped);
        }
      }
    }
  }

  /// The [scope] key [sessionId] opened, or null: not signed in with a password, not a holder,
  /// a holder nobody shared the key with yet, or a session that ended.
  Uint8List? key(String sessionId, SealedScope scope) {
    final open = _store.db.select("SELECT 1 FROM sessions WHERE id = ? AND ended IS NULL", [sessionId]).isNotEmpty;
    if (!open) {
      _open.remove(sessionId);
      _own.remove(sessionId);
      return null;
    }

    return _open[sessionId]?[scope];
  }

  /// The private key of [sessionId]'s account, or null like [key]: it opens what
  /// [sealToAccount] sealed for that person.
  Uint8List? own(String sessionId) {
    final open = _store.db.select("SELECT 1 FROM sessions WHERE id = ? AND ended IS NULL", [sessionId]).isNotEmpty;
    if (!open) {
      _open.remove(sessionId);
      _own.remove(sessionId);
      return null;
    }

    return _own[sessionId];
  }

  /// [clear] (any JSON value) sealed for whoever holds [scope], with no key in hand: to the public
  /// half of the pair the scope key derives. Null while nobody ever opened the scope, so it has
  /// no pair yet (the owner's first sign in makes it).
  Future<Uint8List?> sealToScope(SealedScope scope, Object? clear, {required String context}) async {
    final row = _store.db.select("SELECT value FROM meta WHERE key = ?", [_publicMeta(scope)]).firstOrNull;
    if (row == null) return null;

    return _sealTo(SimplePublicKey(base64.decode(row["value"] as String), type: KeyPairType.x25519), clear, context);
  }

  /// [clear] sealed for the person [accountId] alone. Null while they have no pair (an account
  /// nobody signed in to yet).
  Future<Uint8List?> sealToAccount(String accountId, Object? clear, {required String context}) async {
    final row = _store.db.select("SELECT public FROM account_keys WHERE account = ?", [accountId]).firstOrNull;
    if (row == null) return null;

    return _sealTo(SimplePublicKey(row["public"] as Uint8List, type: KeyPairType.x25519), clear, context);
  }

  /// What [sealToScope] sealed, opened with the scope's [key].
  Future<Object?> openWithScope(SealedScope scope, Uint8List key, Uint8List sealed, {required String context}) async =>
    _openWith(await _scopePair(scope, key), sealed, context);

  /// What [sealToAccount] sealed, opened with the account's private key ([own]).
  Future<Object?> openWithOwn(Uint8List own, Uint8List sealed, {required String context}) async =>
    _openWith(await _x25519.newKeyPairFromSeed(own), sealed, context);

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
    _own.values.forEach(wipe);
    _open.clear();
    _own.clear();
    _scopePairs.clear();
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
      await _scopePair(scope, key);

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

    if (!made) {
      // Another holder's sign in made it first: read theirs.
      wipe(key);
      return _scopeKey(scope, accountId, pair);
    }

    await _scopePair(scope, key);
    return key;
  }

  /// [scope]'s pair, derived from its [key]; its public half is stored the first time, which on a
  /// master whose scope key predates it is the next sign in or refresh of a holder.
  Future<SimpleKeyPair> _scopePair(SealedScope scope, Uint8List key) async {
    final known = _scopePairs[scope];
    if (known != null) return known;

    final pair = await _x25519.newKeyPairFromSeed(await subkey(key, "lyra/sealed/scope-pair/v1"));
    final public = await pair.extractPublicKey();

    _store.write((db) => db.execute(
      "INSERT OR IGNORE INTO meta (key, value) VALUES (?, ?)",
      [_publicMeta(scope), base64.encode(public.bytes)],
    ));

    return _scopePairs[scope] = pair;
  }

  /// [clear] as JSON to [public]: an ephemeral agreement as in [_wrap], under its own label.
  /// Stored as `ephemeral public (32) | envelope`.
  static Future<Uint8List> _sealTo(SimplePublicKey public, Object? clear, String context) async {
    final ephemeral = await _x25519.newKeyPair();
    final kek = await _agreed(ephemeral, public, "lyra/sealed/data/v1");
    try {
      final box = await Envelope.seal(kek, utf8.encode(jsonEncode(clear)), context: _dataContext(context));
      final mine = await ephemeral.extractPublicKey();

      return Uint8List.fromList([...mine.bytes, ...box]);
    } finally {
      wipe(kek);
    }
  }

  static Future<Object?> _openWith(SimpleKeyPair pair, Uint8List sealed, String context) async {
    if (sealed.length < 32) throw const EnvelopeError();

    final kek = await _agreed(pair, SimplePublicKey(sealed.sublist(0, 32), type: KeyPairType.x25519), "lyra/sealed/data/v1");
    try {
      return jsonDecode(utf8.decode(await Envelope.open(kek, sealed.sublist(32), context: _dataContext(context))));
    } finally {
      wipe(kek);
    }
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

  Future<void> _keep(String sessionId, String refreshToken, Map<SealedScope, Uint8List> keys, Uint8List? own) async {
    final clear = utf8.encode(jsonEncode({
      for (final MapEntry(:key, :value) in keys.entries) key.name: base64.encode(value),
      if (own != null) _ownEntry: base64.encode(own),
    }));
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
    final kek = await _agreed(ephemeral, public, "lyra/sealed/wrap/v1");
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

    final kek = await _agreed(pair, SimplePublicKey(wrap.sublist(0, 32), type: KeyPairType.x25519), "lyra/sealed/wrap/v1");
    try {
      return await Envelope.open(kek, wrap.sublist(32), context: _wrapContext(scope, holder));
    } finally {
      wipe(kek);
    }
  }

  static Future<Uint8List> _agreed(SimpleKeyPair pair, SimplePublicKey other, String label) async {
    final shared = await _x25519.sharedSecretKey(keyPair: pair, remotePublicKey: other);

    return subkey(await shared.extractBytes(), label);
  }

  static Future<SimpleKeyPair> _recoveryPair(RecoveryKey recovery) async =>
    _x25519.newKeyPairFromSeed(await subkey(recovery.entropy, "lyra/sealed/recovery/v1"));

  static Future<Uint8List> _sessionKey(String refreshToken) =>
    subkey(utf8.encode(refreshToken), "lyra/sealed/session/v1");

  static String _accountContext(String accountId) => "lyra/sealed/account/$accountId";

  static String _wrapContext(SealedScope scope, String holder) => "lyra/sealed/${scope.name}/$holder";

  static String _sessionContext(String sessionId) => "lyra/sealed/session/$sessionId";

  static String _dataContext(String context) => "lyra/sealed/data/$context";

  static String _publicMeta(SealedScope scope) => "sealed_public_${scope.name}";
}
