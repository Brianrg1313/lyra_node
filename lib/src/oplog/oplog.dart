import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'hlc.dart';

/// One committed change (plan §8.2): what changed ([entity] + [entityId]), how ([kind]), the
/// data a client or the sync needs to apply it ([payload]), and who did it.
final class OplogEntry {
  const OplogEntry({
    required this.seq,
    required this.hlc,
    required this.entity,
    required this.entityId,
    required this.kind,
    required this.payload,
    this.actor,
    this.device,
    this.command,
  });

  factory OplogEntry._fromRow(Row row) => OplogEntry(
    seq: row["seq"] as int,
    hlc: Hlc.parse(row["hlc"] as String),
    entity: row["entity"] as String,
    entityId: row["entity_id"] as String,
    kind: row["kind"] as String,
    payload: jsonDecode(row["payload"] as String) as Map<String, Object?>,
    actor: row["actor"] as String?,
    device: row["device"] as String?,
    command: row["command"] as String?,
  );

  /// One increasing counter over the whole log: the `seq` of events (`protocol-v1.md` §5).
  final int seq;
  final Hlc hlc;
  final String entity;
  final String entityId;
  final String kind;
  final Map<String, Object?> payload;

  /// The account that ran the command; null for the engine itself.
  final String? actor;
  final String? device;

  /// The `commandId` of the write that produced it.
  final String? command;
}

/// The operation log: the event feed for clients, the source of hybrid sync, and readable
/// history for support (plan §8.2). Append-only.
final class Oplog {
  const Oplog(this._db);

  final Database _db;

  /// Appends one entry. Call it inside the write that made the change, so the change and its
  /// entry commit together or not at all.
  int append({
    required Hlc hlc,
    required String entity,
    required String entityId,
    required String kind,
    Map<String, Object?> payload = const {},
    String? actor,
    String? device,
    String? command,
  }) {
    _db.execute(
      "INSERT INTO oplog (hlc, entity, entity_id, kind, payload, actor, device, command) "
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [hlc.pack(), entity, entityId, kind, jsonEncode(payload), actor, device, command],
    );

    return _db.lastInsertRowId;
  }

  /// Entries after [seq], oldest first, at most [limit].
  List<OplogEntry> since(int seq, {int limit = 500}) => [
    for (final row in _db.select(
      "SELECT * FROM oplog WHERE seq > ? ORDER BY seq LIMIT ?",
      [seq, limit],
    ))
      OplogEntry._fromRow(row),
  ];

  int get lastSeq =>
    _db.select("SELECT coalesce(max(seq), 0) AS seq FROM oplog").first["seq"] as int;

  /// The newest stamp ever written, to seed the clock at start ([HlcClock] never goes back).
  Hlc? get lastHlc {
    final row = _db.select("SELECT max(hlc) AS hlc FROM oplog").first;

    return row["hlc"] == null ? null : Hlc.parse(row["hlc"] as String);
  }
}
