import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lyra_protocol/lyra_protocol.dart' show PairingDevice;

import 'audit/audit_log.dart';
import 'crypto/keyring.dart';
import 'crypto/recovery.dart';
import 'crypto/secrets.dart';
import 'crypto/vault.dart';
import 'domain/business/business.dart';
import 'domain/inventory/inventory.dart';
import 'domain/pos/pos.dart';
import 'domain/stock/stock.dart';
import 'failure.dart';
import 'identity/accounts.dart';
import 'identity/devices.dart';
import 'identity/passwords.dart';
import 'identity/sessions.dart';
import 'ids.dart';
import 'net/events.dart';
import 'net/files.dart';
import 'net/tls.dart';
import 'oplog/commands.dart';
import 'oplog/hlc.dart';
import 'oplog/oplog.dart';
import 'process/paths.dart';
import 'storage/migrations.dart';
import 'storage/store.dart';

/// This engine's version, answered in `hello` (`protocol-v1.md` §4).
const String engineVersion = "0.2.0";

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

/// The master's own app, enrolled as its device at setup, recovery or `lyra_node enroll`
/// (plan §3: the app talks to its engine like any client, with its own certificate).
final class DeviceDraft {
  const DeviceDraft({required this.device, required this.publicKey});

  /// Null when [json] isn't a device with a public key.
  static DeviceDraft? tryParse(Object? json) {
    if (json is! Map) return null;

    final device = PairingDevice.tryParse(json);
    final key = json["publicKey"];

    if (device == null || key is! String) return null;

    try {
      return DeviceDraft(device: device, publicKey: base64.decode(key));
    } on FormatException {
      return null;
    }
  }

  final PairingDevice device;

  /// SPKI of the key the app created and keeps.
  final Uint8List publicKey;
}

/// What an enrolled master app keeps (`lyra_node setup`, `recover` and `enroll` answer it).
final class EnrolledDevice {
  const EnrolledDevice({
    required this.deviceId,
    required this.code,
    required this.certificate,
    required this.caCertificate,
  });

  final String deviceId;
  final String code;
  final Uint8List certificate;
  final Uint8List caCertificate;

  Map<String, Object?> toJson() => {
    "deviceId": deviceId,
    "code": code,
    "certificate": base64.encode(certificate),
    "caCertificate": base64.encode(caCertificate),
  };
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

  late final Accounts accounts = Accounts(store, clock, hasher: _hasher, now: _now);

  late final Business business = Business(store, clock, now: _now);

  late final Inventory inventory = Inventory(store, clock, now: _now);

  late final Stock stock = Stock(store, clock, inventory, now: _now);

  late final Pos pos = Pos(store, clock, inventory, stock, business, now: _now);

  Devices get devices => Devices(store, clock, now: _now);

  /// Sessions hold access tokens in memory: one instance for the engine's life.
  late final Sessions sessions = Sessions(store, now: _now);

  late final EventLog events = EventLog(store, now: _now);

  late final Authority authority = Authority.ensure(store, instanceId, now: _now());

  late final FileStore files;

  DateTime now() => _now();

  /// Issues a certificate for the master's own app and enrolls it as the master device (the
  /// previous one is revoked), then records it in the transport file, so a locked engine still
  /// knows which device may unlock it.
  Future<EnrolledDevice> enrollMaster(DeviceDraft draft, {required Uint8List controlKey, String? by}) async {
    final id = newId();
    final certificate = authority.issueDevice(draft.publicKey, id, now: _now());
    final device = devices.enroll(
      id: id,
      name: draft.device.name,
      platform: draft.device.platform,
      appVersion: draft.device.appVersion,
      kind: DeviceKind.master,
      publicKey: draft.publicKey,
      certFingerprint: certificate.fingerprint,
      pairedBy: by ?? _owner,
    );

    await prepareTransport(controlKey);

    return EnrolledDevice(
      deviceId: device.id,
      code: device.code,
      certificate: certificate.der,
      caCertificate: authority.pinned.der,
    );
  }

  /// The transport file for this start. Issued again when it is missing, names other addresses
  /// than this computer has now, is past half its life, or names another master device.
  Future<Transport> prepareTransport(Uint8List controlKey) async {
    final addresses = await LocalAddresses.current();
    final master = devices.master?.certFingerprint;
    final existing = await Transport.read(paths.transport, controlKey);
    final Transport transport;

    if (existing == null ||
        existing.ca.fingerprint != authority.pinned.fingerprint ||
        existing.needsRenewal(addresses, now: _now())) {
      transport = Transport.issue(authority, addresses, masterDevice: master, now: _now());
    } else if (existing.masterDevice != master) {
      transport = existing.withMaster(master);
    } else {
      return existing;
    }

    await transport.write(paths.transport, controlKey);

    return transport;
  }

  String? get _owner {
    final rows = store.db.select("SELECT account FROM grants WHERE permission = '*' ORDER BY account LIMIT 1");

    return rows.isEmpty ? null : rows.first["account"] as String;
  }

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

  /// Makes a new master in [paths]: the keys, the database, its owner and its company (plan §6.2,
  /// §7.4, `business.md` B-1).
  ///
  /// [passphrase] chooses passphrase mode. Answers the recovery key, **the only time it exists
  /// outside the owner's hands**. If anything fails, whatever was already written is removed,
  /// so a second try starts clean.
  static Future<({String instanceId, RecoveryKey recovery, EnrolledDevice? device})> setup({
    required NodePaths paths,
    required KeyVault vault,
    required OwnerDraft owner,
    required CompanyDraft company,
    DeviceDraft? device,
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

    // Before any key or file exists: a wrong field leaves nothing to clean up.
    company.check();

    final instanceId = newId();
    final clock = now ?? DateTime.now;
    Store? store;
    Keyring? keyring;

    try {
      final control = await controlKey(vault, instanceId);

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

      final account = await Accounts(store, hlc, hasher: hasher, now: clock).createOwner(
        username: owner.username,
        password: owner.password,
        firstName: owner.firstName,
        lastName: owner.lastName,
        email: owner.email,
      );
      store.write((db) => Business.create(db, company, clock: hlc, now: clock(), actor: account.id));

      // The CA, the server certificate and the master's own device, so the first start already
      // serves the LAN (plan §5.3).
      final engine = Engine._(paths, keyring, store, hlc, clock, hasher)
        ..files = await _files(paths, store, keyring, clock);
      EnrolledDevice? enrolled;

      if (device != null) {
        enrolled = await engine.enrollMaster(device, controlKey: control);
      } else {
        await engine.prepareTransport(control);
      }

      return (instanceId: instanceId, recovery: created.recovery, device: enrolled);
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
      )..files = await _files(paths, store, keyring, clock);

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

  static Future<FileStore> _files(NodePaths paths, Store store, Keyring keyring, DateTime Function() now) async =>
    FileStore(store, paths.files, await keyring.derive("lyra/files/v1"), now: now);

  static Future<void> _discard(NodePaths paths, KeyVault vault, String instanceId) async {
    for (final path in [paths.keyring, paths.database, "${paths.database}-wal", "${paths.database}-shm", paths.transport]) {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    }

    await vault.delete(KeyringStore.kekName(instanceId));
    await vault.delete(controlKeyName(instanceId));
  }
}
