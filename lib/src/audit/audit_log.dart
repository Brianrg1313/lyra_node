import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:lyra_protocol/lyra_protocol.dart' show canonicalJson;

/// What the audit log records (plan §6.6). Stable strings: exports and support read them.
abstract final class AuditKinds {
  static const engineStart = "engine.start";
  static const engineStop = "engine.stop";
  static const keyringCreated = "keyring.created";
  static const keyringRecovered = "keyring.recovered";
  static const migrationApplied = "migration.applied";
  static const accountCreated = "account.created";
  static const companyCreated = "company.created";
  static const fieldDeleted = "inventory.field_deleted";
  static const signInFailed = "auth.failed";
  static const accountLocked = "auth.locked";
  static const signedIn = "auth.signed_in";
  static const refreshReused = "auth.refresh_reused";
  static const passwordChanged = "account.password_changed";
  static const devicePaired = "device.paired";
  static const deviceRevoked = "device.revoked";
  static const pairingFailed = "pairing.failed";
  static const engineUnlocked = "engine.unlocked";
}

final class AuditEntry {
  const AuditEntry({
    required this.seq,
    required this.at,
    required this.kind,
    required this.data,
    required this.prev,
    required this.hash,
    this.actor,
    this.device,
  });

  factory AuditEntry._fromRow(Row row) => AuditEntry(
    seq: row["seq"] as int,
    at: DateTime.parse(row["at"] as String),
    kind: row["kind"] as String,
    actor: row["actor"] as String?,
    device: row["device"] as String?,
    data: jsonDecode(row["data"] as String) as Map<String, Object?>,
    prev: row["prev"] as String,
    hash: row["hash"] as String,
  );

  final int seq;
  final DateTime at;
  final String kind;
  final String? actor;
  final String? device;
  final Map<String, Object?> data;

  /// The [hash] of the entry before this one (64 zeros for the first).
  final String prev;

  /// `SHA-256(prev ‖ canonical JSON of this entry without its hashes)`.
  final String hash;
}

/// The append-only, hash-chained audit log (plan §6.6): `h_n = H(h_{n-1} ‖ entry)`.
///
/// Editing or removing an entry breaks every hash after it, which [verify] finds. A determined
/// local admin can rebuild the whole chain (plan §6.1 accepts that); hybrid sync compares it
/// with the cloud's copy.
final class AuditLog {
  AuditLog(this._db, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  static final String genesis = "0" * 64;

  final Database _db;
  final DateTime Function() _now;

  /// Appends one entry. Inside a write, it commits with the change it records.
  AuditEntry append(String kind, {String? actor, String? device, Map<String, Object?> data = const {}}) {
    final last = _db.select("SELECT seq, hash FROM audit ORDER BY seq DESC LIMIT 1");
    final seq = last.isEmpty ? 1 : (last.first["seq"] as int) + 1;
    final prev = last.isEmpty ? genesis : last.first["hash"] as String;
    final at = _now().toUtc();
    final hash = _hash(prev, seq, at, kind, actor, device, data);

    _db.execute(
      "INSERT INTO audit (seq, at, kind, actor, device, data, prev, hash) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [seq, at.toIso8601String(), kind, actor, device, jsonEncode(data), prev, hash],
    );

    return AuditEntry(
      seq: seq, at: at, kind: kind, actor: actor, device: device, data: data, prev: prev, hash: hash,
    );
  }

  /// The seq of the first entry whose chain is broken, or null when the whole log holds.
  int? verify() {
    var prev = genesis;
    var expected = 1;

    for (final row in _db.select("SELECT * FROM audit ORDER BY seq")) {
      final entry = AuditEntry._fromRow(row);
      final hash = _hash(prev, entry.seq, entry.at, entry.kind, entry.actor, entry.device, entry.data);

      if (entry.seq != expected || entry.prev != prev || entry.hash != hash) return entry.seq;

      prev = entry.hash;
      expected++;
    }

    return null;
  }

  /// Entries after [after], oldest first.
  List<AuditEntry> list({int after = 0, int limit = 500}) => [
    for (final row in _db.select(
      "SELECT * FROM audit WHERE seq > ? ORDER BY seq LIMIT ?",
      [after, limit],
    ))
      AuditEntry._fromRow(row),
  ];

  static String _hash(
    String prev,
    int seq,
    DateTime at,
    String kind,
    String? actor,
    String? device,
    Map<String, Object?> data,
  ) {
    final entry = canonicalJson({
      "seq": seq,
      "at": at.toUtc().toIso8601String(),
      "kind": kind,
      "actor": actor,
      "device": device,
      "data": data,
    });

    return sha256.convert(utf8.encode(prev + entry)).toString();
  }
}
