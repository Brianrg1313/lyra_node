import 'dart:async';
import 'dart:convert';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../failure.dart';
import '../identity/permissions.dart';
import '../storage/store.dart';

/// One event of the stream, with who may receive it.
final class StoredEvent {
  const StoredEvent({required this.seq, required this.name, required this.data, this.accounts, this.permissions});

  final int seq;
  final String name;
  final Object? data;

  /// Only these accounts' sessions receive it (`permissions/changed`).
  final List<String>? accounts;

  /// Only sessions holding one of these permissions receive it.
  final List<String>? permissions;

  /// Whether a session of [accountId] with [grants] may see it (`protocol-v1.md` §5: a client
  /// never receives an event about data it can't read).
  bool visibleTo(String accountId, Set<String> grants) =>
    (accounts == null || accounts!.contains(accountId)) &&
    (permissions == null || permissions!.any((permission) => Permissions.allows(grants, permission)));

  RpcEvent get frame => RpcEvent(event: name, seq: seq, data: data);
}

/// The event stream clients subscribe to (`protocol-v1.md` §5).
///
/// A write appends its events with [append] inside the same transaction, so an event exists
/// exactly when its change does. After the write commits, [publish] hands the new ones to the
/// live subscribers; the RPC router calls it after every op.
final class EventLog {
  EventLog(this._store, {DateTime Function()? now}) : _now = now ?? DateTime.now {
    _published = _lastSeq;
  }

  /// How far back `events.subscribe {since}` replays.
  static const replayWindow = Duration(days: 7);
  static const replayMax = 100000;

  final Store _store;
  final DateTime Function() _now;
  final StreamController<StoredEvent> _live = StreamController.broadcast(sync: true);
  late int _published;

  Stream<StoredEvent> get live => _live.stream;

  int get _lastSeq => _store.db.select("SELECT coalesce(max(seq), 0) AS seq FROM events").first["seq"] as int;

  /// Appends one event inside a write, for sessions holding [permission] or any of [anyOf].
  static void append(
    Database db,
    String name,
    Object? data, {
    required DateTime at,
    List<String>? accounts,
    String? permission,
    List<String>? anyOf,
  }) {
    final permissions = [?permission, ...?anyOf];
    final audience = accounts == null && permissions.isEmpty
      ? null
      : jsonEncode({"accounts": ?accounts, if (permissions.isNotEmpty) "anyOf": permissions});

    db.execute(
      "INSERT INTO events (at, name, data, audience) VALUES (?, ?, ?, ?)",
      [at.toUtc().toIso8601String(), name, jsonEncode(data), audience],
    );
  }

  /// Hands the events committed since the last call to the live subscribers.
  void publish() {
    final fresh = _read(_published);
    if (fresh.isEmpty) return;

    _published = fresh.last.seq;
    for (final event in fresh) {
      _live.add(event);
    }
  }

  /// The events after [seq] to replay, or `resync_required` when some of them are no longer
  /// kept.
  List<StoredEvent> since(int seq) {
    final oldest = _store.db.select("SELECT min(seq) AS seq FROM events").first["seq"] as int?;
    final last = _published;

    if (seq > last) return const [];
    // Nothing kept, or a gap between what the client has and the oldest kept event.
    if (seq < last && (oldest == null || oldest > seq + 1)) throw const EngineFailure(ErrorCodes.resyncRequired);

    return _read(seq, upTo: last);
  }

  /// The last published seq: a subscriber without `since` starts after it.
  int get head => _published;

  /// Forgets events past the replay window (age or count).
  void prune() => _store.write((db) {
    db.execute("DELETE FROM events WHERE at < ?", [_now().toUtc().subtract(replayWindow).toIso8601String()]);
    db.execute("DELETE FROM events WHERE seq <= (SELECT max(seq) FROM events) - ?", [replayMax]);
  });

  Future<void> close() => _live.close();

  List<StoredEvent> _read(int after, {int? upTo}) => [
    for (final row in _store.db.select(
      "SELECT * FROM events WHERE seq > ? AND seq <= ? ORDER BY seq",
      [after, upTo ?? 1 << 62],
    ))
      _event(row),
  ];

  static StoredEvent _event(Row row) {
    final audience = row["audience"] == null ? null : jsonDecode(row["audience"] as String) as Map<String, Object?>;

    return StoredEvent(
      seq: row["seq"] as int,
      name: row["name"] as String,
      data: jsonDecode(row["data"] as String),
      accounts: (audience?["accounts"] as List?)?.cast<String>(),
      // Before the POS release an audience named one `permission`.
      permissions: (audience?["anyOf"] as List?)?.cast<String>() ??
        (audience?["permission"] is String ? [audience!["permission"] as String] : null),
    );
  }
}
