import 'dart:typed_data';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../audit/audit_log.dart';
import '../failure.dart';
import '../ids.dart';
import '../oplog/hlc.dart';
import '../oplog/oplog.dart';
import '../storage/store.dart';
import 'sessions.dart';

enum DeviceKind {
  /// The app on the master itself (plan §3): the only one that unlocks the engine and opens
  /// pairing.
  master,

  /// A desktop or mobile app with a certificate for mutual TLS.
  native,

  /// A browser, proving itself with a WebCrypto key (`device.prove`).
  web,
}

/// A paired device (`session.md` session.devices).
final class Device {
  const Device({
    required this.id,
    required this.name,
    required this.platform,
    required this.kind,
    required this.code,
    required this.publicKey,
    required this.paired,
    this.certFingerprint,
    this.appVersion,
    this.pairedBy,
    this.lastSeen,
    this.lastAccount,
    this.revoked,
  });

  final String id;
  final String name;
  final String platform;
  final DeviceKind kind;

  /// `A`, `B`, … `Z`, `AA`…: assigned at pairing and never reused. It prefixes the ticket codes
  /// the device mints (`pos.md` POS-40).
  final String code;

  /// SPKI of the device key.
  final Uint8List publicKey;

  /// Of the device certificate; null for a browser.
  final String? certFingerprint;
  final String? appVersion;
  final DateTime paired;
  final String? pairedBy;
  final DateTime? lastSeen;
  final String? lastAccount;
  final DateTime? revoked;

  bool get isRevoked => revoked != null;

  /// What `devices.list` answers. [online] comes from the server's open connections.
  Map<String, Object?> toJson({bool online = false}) => {
    "id": id,
    "name": name,
    "platform": platform,
    "kind": kind.name,
    "code": code,
    "certFingerprint": certFingerprint,
    "appVersion": appVersion,
    "paired": paired.toUtc().toIso8601String(),
    "pairedBy": pairedBy,
    "lastSeen": lastSeen?.toUtc().toIso8601String(),
    "lastAccount": lastAccount,
    "revoked": revoked?.toUtc().toIso8601String(),
    "online": online,
  };
}

/// Paired devices: enrolment, renaming and revocation (S-40, S-41).
final class Devices {
  Devices(this._store, this._clock, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Store _store;
  final HlcClock _clock;
  final DateTime Function() _now;

  Database get _db => _store.db;

  /// Adds a device under [id] (a fresh id when null; the caller mints it first when the
  /// certificate it issues names it). [certFingerprint] is null for a browser. A new master
  /// device replaces the previous one, which is revoked in the same write: there is one master
  /// app per master.
  Device enroll({
    required String name,
    required String platform,
    required DeviceKind kind,
    required Uint8List publicKey,
    String? id,
    String? certFingerprint,
    String? appVersion,
    String? pairedBy,
  }) {
    final deviceId = id ?? newId();
    final fingerprint = certFingerprint;

    return _store.write((db) {
      final id = deviceId;
      final stamp = _clock.tick();
      final now = _now().toUtc().toIso8601String();
      final count = db.select("SELECT count(*) AS n FROM devices").first["n"] as int;
      final code = codeFor(count);
      final audit = AuditLog(db, now: _now);

      if (kind == DeviceKind.master) {
        for (final row in db.select("SELECT id FROM devices WHERE kind = 'master' AND revoked IS NULL")) {
          _revoke(db, row["id"] as String, reason: "replaced", actor: pairedBy, device: id);
        }
      }

      db.execute(
        "INSERT INTO devices (id, name, platform, kind, code, public_key, cert_fingerprint, app_version, paired, "
        "paired_by, created_hlc, updated_hlc, origin) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [id, name, platform, kind.name, code, publicKey, fingerprint, appVersion, now, pairedBy,
          stamp.pack(), stamp.pack(), id],
      );
      Oplog(db).append(
        hlc: stamp,
        entity: "device",
        entityId: id,
        kind: "paired",
        payload: {"name": name, "platform": platform, "kind": kind.name, "code": code},
        actor: pairedBy,
        device: id,
      );
      audit.append(AuditKinds.devicePaired, actor: pairedBy, device: id, data: {
        "device": id,
        "name": name,
        "platform": platform,
        "kind": kind.name,
        "certFingerprint": fingerprint,
      });

      return byId(id)!;
    });
  }

  Device? byId(String id) {
    final rows = _db.select("SELECT * FROM devices WHERE id = ? AND deleted = 0", [id]);

    return rows.isEmpty ? null : _device(rows.first);
  }

  Device? byFingerprint(String fingerprint) {
    final rows = _db.select("SELECT * FROM devices WHERE cert_fingerprint = ? AND deleted = 0", [fingerprint]);

    return rows.isEmpty ? null : _device(rows.first);
  }

  /// The master's own device that isn't revoked, if any.
  Device? get master {
    final rows = _db.select("SELECT * FROM devices WHERE kind = 'master' AND revoked IS NULL AND deleted = 0");

    return rows.isEmpty ? null : _device(rows.first);
  }

  /// Newest first, revoked ones included (the list shows them as revoked).
  List<Device> list() => [
    for (final row in _db.select("SELECT * FROM devices WHERE deleted = 0 ORDER BY paired DESC, id DESC"))
      _device(row),
  ];

  Device rename(String id, String name, {String? actor, String? device}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 64) {
      throw const EngineFailure(ErrorCodes.invalidField, {"field": "name"});
    }

    return _store.write((db) {
      if (byId(id) == null) throw const EngineFailure(ErrorCodes.notFound);

      final stamp = _clock.tick();
      db.execute("UPDATE devices SET name = ?, updated_hlc = ? WHERE id = ?", [trimmed, stamp.pack(), id]);
      Oplog(db).append(
        hlc: stamp, entity: "device", entityId: id, kind: "renamed", payload: {"name": trimmed},
        actor: actor, device: device,
      );

      return byId(id)!;
    });
  }

  /// Revokes [id]: its sessions end and its certificate is refused from now on (S-41). The
  /// caller drops the device's open connections.
  Device revoke(String id, {String? actor, String? device}) => _store.write((db) {
    final target = byId(id);
    if (target == null) throw const EngineFailure(ErrorCodes.notFound);
    // The master's own device only goes when a new one replaces it ([enroll]).
    if (target.kind == DeviceKind.master) throw const EngineFailure("self");

    if (!target.isRevoked) _revoke(db, id, reason: "revoked", actor: actor, device: device);

    return byId(id)!;
  });

  /// Last seen now, by [account] when a session is bound.
  void touch(String id, {String? account}) => _store.write((db) => db.execute(
    "UPDATE devices SET last_seen = ?, last_account = coalesce(?, last_account) WHERE id = ?",
    [_now().toUtc().toIso8601String(), account, id],
  ));

  void _revoke(Database db, String id, {required String reason, String? actor, String? device}) {
    final stamp = _clock.tick();

    db.execute(
      "UPDATE devices SET revoked = ?, updated_hlc = ? WHERE id = ?",
      [_now().toUtc().toIso8601String(), stamp.pack(), id],
    );
    Sessions.endForDevice(db, id, reason: "device_revoked", now: _now());
    Oplog(db).append(hlc: stamp, entity: "device", entityId: id, kind: "revoked", actor: actor, device: device);
    AuditLog(db, now: _now).append(AuditKinds.deviceRevoked, actor: actor, device: device, data: {
      "device": id,
      "reason": reason,
    });
  }

  /// `A`…`Z`, then `AA`…`ZZ`, `AAA`…: the [n]th code, like spreadsheet columns.
  static String codeFor(int n) {
    var code = "";
    for (var rest = n + 1; rest > 0; rest = (rest - 1) ~/ 26) {
      code = String.fromCharCode(65 + (rest - 1) % 26) + code;
    }

    return code;
  }

  Device _device(Row row) => Device(
    id: row["id"] as String,
    name: row["name"] as String,
    platform: row["platform"] as String,
    kind: DeviceKind.values.byName(row["kind"] as String),
    code: row["code"] as String,
    publicKey: row["public_key"] as Uint8List,
    certFingerprint: row["cert_fingerprint"] as String?,
    appVersion: row["app_version"] as String?,
    paired: DateTime.parse(row["paired"] as String),
    pairedBy: row["paired_by"] as String?,
    lastSeen: row["last_seen"] == null ? null : DateTime.parse(row["last_seen"] as String),
    lastAccount: row["last_account"] as String?,
    revoked: row["revoked"] == null ? null : DateTime.parse(row["revoked"] as String),
  );
}
