import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../canonical_json.dart';

/// A `commandId` came back with different arguments (`command_reused`): a client bug, never a
/// retry.
final class CommandReused implements Exception {
  const CommandReused(this.commandId);

  final String commandId;

  String get code => ErrorCodes.commandReused;

  @override
  String toString() => "CommandReused($commandId)";
}

/// What makes a write safe to send twice (`docs/offline/README.md`, Writes): the first answer
/// of every `commandId` is kept for [retention], and the same command gets that answer again
/// instead of running a second time. A retry after a dropped connection and a POS outbox replay
/// both rely on it.
final class CommandLedger {
  const CommandLedger(this._db);

  static const retention = Duration(days: 30);

  final Database _db;

  /// The kept answer of [commandId], or `(found: false)` when it never ran. Throws
  /// [CommandReused] when it ran with other arguments.
  ({bool found, Object? answer}) replay(String commandId, String op, Map<String, Object?> args) {
    final rows = _db.select("SELECT args_hash, answer FROM commands WHERE id = ?", [commandId]);
    if (rows.isEmpty) return (found: false, answer: null);

    if (rows.first["args_hash"] != _hash(op, args)) throw CommandReused(commandId);

    return (found: true, answer: jsonDecode(rows.first["answer"] as String));
  }

  /// Keeps [answer]. Call it inside the write that ran the command.
  void record(String commandId, String op, Map<String, Object?> args, Object? answer, DateTime at) {
    _db.execute(
      "INSERT INTO commands (id, op, args_hash, answer, at) VALUES (?, ?, ?, ?, ?)",
      [commandId, op, _hash(op, args), jsonEncode(answer), at.toUtc().toIso8601String()],
    );
  }

  /// Forgets answers older than [retention]. Answers how many.
  int prune(DateTime now) {
    _db.execute(
      "DELETE FROM commands WHERE at < ?",
      [now.toUtc().subtract(retention).toIso8601String()],
    );

    return _db.updatedRows;
  }

  static String _hash(String op, Map<String, Object?> args) =>
    sha256.convert(utf8.encode(canonicalJson({"op": op, "args": args}))).toString();
}
