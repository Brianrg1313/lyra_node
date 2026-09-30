import 'dart:io';
import 'dart:typed_data';

import 'audit/audit_log.dart';
import 'crypto/keyring.dart';
import 'crypto/recovery.dart';
import 'crypto/secrets.dart';
import 'crypto/vault.dart';
import 'failure.dart';
import 'identity/accounts.dart';
import 'identity/passwords.dart';
import 'ids.dart';
import 'oplog/commands.dart';
import 'oplog/hlc.dart';
import 'oplog/oplog.dart';
import 'process/paths.dart';
import 'storage/migrations.dart';
import 'storage/store.dart';

/// This engine's version, answered in `hello` (`protocol-v1.md` §4).
const String engineVersion = "0.1.0";

/// The oldest app this engine serves (`update_required` below it).
const String minAppVersion = "0.0.6";

/// The owner typed at setup (`session.md` S-6).
final class OwnerDraft {
  const OwnerDraft({
    required this.username,
    required this.password,
    required this.firstName,
    required this.lastName,
    this.email,
  });

  factory OwnerDraft.fromJson(Map<String, Object?> json) => OwnerDraft(
    username: json["username"] as String? ?? "",
    password: json["password"] as String? ?? "",
    firstName: json["firstName"] as String? ?? "",
    lastName: json["lastName"] as String? ?? "",
    email: json["email"] as String?,
  );

  final String username;
  final String password;
  final String firstName;
  final String lastName;
  final String? email;
}

/// A master's data, open: the keys in memory, the database, and what writes to it.
///
/// [Engine.setup] makes a new master; [Engine.open] opens an existing one. Nothing here knows
/// about processes or the network: the runner (`NodeRunner`) and, from phase 3, the LAN server
/// hold an `Engine`, and the tests drive one directly.
final class Engine {
  Engine._(this.paths, this._keyring, this.store, this.clock, this._now, this._hasher);

  final NodePaths paths;
  final Keyring _keyring;
  final Store store;
  final HlcClock clock;
  final DateTime Function() _now;
  final PasswordHasher _hasher;

  String get instanceId => _keyring.instanceId;

  Oplog get oplog => Oplog(store.db);

  AuditLog get audit => AuditLog(store.db, now: _now);

  CommandLedger get commands => CommandLedger(store.db);

  Accounts get accounts => Accounts(store, clock, hasher: _hasher, now: _now);

  /// The name of the control key in the OS vault (`ControlChannel`, `EngineStatusFile`).
  static String controlKeyName(String instanceId) => "control.$instanceId";

  /// The control key of [instanceId], made on first use. It only proves "this is our engine"
  /// and signs stop requests; it opens no data, so making a new one never loses anything.
  static Future<Uint8List> controlKey(KeyVault vault, String instanceId) async {
    final name = controlKeyName(instanceId);
    final key = await vault.read(name);
    if (key != null) return key;

    final fresh = randomBytes(32);
    await vault.write(name, fresh);

    return fresh;
  }

  /// Makes a new master in [paths]: the keys, the database and its owner (plan §6.2, §7.4).
  ///
  /// [passphrase] chooses passphrase mode. Answers the recovery key, **the only time it exists
  /// outside the owner's hands**. If anything fails, whatever was already written is removed,
  /// so a second try starts clean.
  static Future<({String instanceId, RecoveryKey recovery})> setup({
    required NodePaths paths,
    required KeyVault vault,
    required OwnerDraft owner,
    String? passphrase,
    Argon2Params params = Argon2Params.standard,
    PasswordHasher hasher = const PasswordHasher(),
    DateTime Function()? now,
  }) async {
    final keyrings = KeyringStore(paths.keyring, vault);

    if (keyrings.exists) throw const EngineFailure("already_set_up");
    // A database with no keyring is data nobody can open, but it may still be somebody's only
    // copy to hand to support; it is never overwritten.
    if (File(paths.database).existsSync()) throw const EngineFailure("data_exists");

    final instanceId = newId();
    final clock = now ?? DateTime.now;
    Store? store;
    Keyring? keyring;

    try {
      await controlKey(vault, instanceId);

      final created = await keyrings.create(instanceId: instanceId, passphrase: passphrase, params: params);
      keyring = created.keyring;
      store = Store.open(paths.database, await keyring.databaseKey());

      final applied = migrate(store, backups: paths.backups, now: clock());
      final hlc = HlcClock(instanceId);

      store.write((db) {
        db.execute("INSERT INTO meta (key, value) VALUES ('instance_id', ?), ('created', ?)", [
          instanceId,
          clock().toUtc().toIso8601String(),
        ]);

        final audit = AuditLog(db, now: clock);
        audit.append(AuditKinds.keyringCreated, data: {"instanceId": instanceId, "mode": keyrings.mode!.name});
        for (final version in applied) {
          audit.append(AuditKinds.migrationApplied, data: {"version": version});
        }
      });

      await Accounts(store, hlc, hasher: hasher, now: clock).createOwner(
        username: owner.username,
        password: owner.password,
        firstName: owner.firstName,
        lastName: owner.lastName,
        email: owner.email,
      );

      return (instanceId: instanceId, recovery: created.recovery);
    } catch (_) {
      store?.close();
      store = null;
      await _discard(paths, vault, instanceId);
      rethrow;
    } finally {
      store?.close();
      keyring?.dispose();
    }
  }

  /// Opens the master in [paths]: loads the keys (from the vault, or [passphrase]), opens the
  /// database, runs pending migrations, and records the start in the audit log.
  static Future<Engine> open({
    required NodePaths paths,
    required KeyVault vault,
    String? passphrase,
    PasswordHasher hasher = const PasswordHasher(),
    DateTime Function()? now,
  }) async {
    final clock = now ?? DateTime.now;
    final keyring = await KeyringStore(paths.keyring, vault).unlock(passphrase: passphrase);
    final Store store;

    try {
      store = Store.open(paths.database, await keyring.databaseKey());
    } catch (_) {
      keyring.dispose();
      rethrow;
    }

    try {
      final applied = migrate(store, backups: paths.backups, now: clock());
      final meta = store.db.select("SELECT value FROM meta WHERE key = 'instance_id'");

      // Keys and database from two different masters (a file copied over another): refused
      // rather than mixing them.
      if (meta.isEmpty || meta.first["value"] != keyring.instanceId) {
        throw const EngineFailure("instance_mismatch");
      }

      final engine = Engine._(
        paths,
        keyring,
        store,
        HlcClock(keyring.instanceId, last: Oplog(store.db).lastHlc),
        clock,
        hasher,
      );

      store.write((db) {
        final audit = AuditLog(db, now: clock);
        for (final version in applied) {
          audit.append(AuditKinds.migrationApplied, data: {"version": version});
        }
        audit.append(AuditKinds.engineStart, data: {"version": engineVersion, "pid": pid});
      });

      return engine;
    } catch (_) {
      store.close();
      keyring.dispose();
      rethrow;
    }
  }

  /// Gets the data back with the recovery key when the usual unlock can't (a lost vault or
  /// passphrase, a new computer): wraps the DEK again under this machine's vault, or a new
  /// [passphrase], and records it in the audit log (`session.md` S-11).
  static Future<void> recover({
    required NodePaths paths,
    required KeyVault vault,
    required RecoveryKey key,
    String? passphrase,
    Argon2Params params = Argon2Params.standard,
    DateTime Function()? now,
  }) async {
    final keyring = await KeyringStore(paths.keyring, vault).recover(key, passphrase: passphrase, params: params);

    try {
      final store = Store.open(paths.database, await keyring.databaseKey());

      try {
        store.write((db) => AuditLog(db, now: now).append(
          AuditKinds.keyringRecovered,
          data: {"mode": passphrase == null ? UnlockMode.unattended.name : UnlockMode.passphrase.name},
        ));
      } finally {
        store.close();
      }
    } finally {
      keyring.dispose();
    }
  }

  /// Records the stop, folds the WAL into the file and forgets the keys.
  void close() {
    try {
      store.write((db) => AuditLog(db, now: _now).append(AuditKinds.engineStop, data: {"pid": pid}));
      store.checkpoint();
    } finally {
      store.close();
      _keyring.dispose();
    }
  }

  static Future<void> _discard(NodePaths paths, KeyVault vault, String instanceId) async {
    for (final path in [paths.keyring, paths.database, "${paths.database}-wal", "${paths.database}-shm"]) {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    }

    await vault.delete(KeyringStore.kekName(instanceId));
    await vault.delete(controlKeyName(instanceId));
  }
}
