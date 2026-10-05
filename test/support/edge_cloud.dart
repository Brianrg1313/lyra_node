import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:lyra_node/lyra_node.dart';

/// The backend's half of the edge sync, in memory: `lyra/app/docs/task-edge-sync-backend.md`
/// made executable, so the engine is tested against the contract before the backend exists. It
/// checks signatures, keeps the id map per device, settles fields by stamp, never echoes, and
/// answers the allowance; [edit], [create], [append] and [delete] play a person using the cloud app.
final class EdgeCloud implements EdgeTransport {
  EdgeCloud({this.company = "c-company", this.site = "c-site", this.base = "/edge/v1"});

  final String company;
  final String site;
  final String base;

  String allowance = EdgeAllowance.within;

  /// Requests that fail before reaching the backend, and ones applied whose answer is lost.
  int unreachable = 0;
  int answersLost = 0;

  /// A change the backend refuses, with its reason.
  String? Function(Map<String, Object?> change)? refuse;

  final clock = HlcClock("cloud", maxDrift: const Duration(days: 365));

  final _devices = <String, ({String instance, List<int> key, bool revoked, int from})>{};
  final _nonces = <String>{};
  final _ids = <String, String>{};
  final _commands = <String, Map<String, Object?>>{};
  final _records = <String, Map<String, _Record>>{};
  final _log = <({int seq, Map<String, Object?> change, String? origin})>[];
  var _next = 0;

  /// The edge key's public half, as the enrolment answers it: the Ed25519 key of [edgeSeed].
  static const edgeKey = "6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw=";

  /// The edge key's private seed, which signs the grants (§9).
  static final edgeSeed = List.filled(32, 7);

  static const _refs = {
    "product_field": {"table": "product_table"},
    "product": {"table": "product_table"},
    "stock_movement": {"product": "product", "table": "product_table"},
  };

  static const _facts = {"stock_movement", "payment"};

  // ------------------------------------------------------------------------- enrolment

  /// `POST /edge/v1/devices`, the app's call with the owner's session.
  EdgeEnrolment enroll(String instance, String publicKey) => EdgeEnrolment.fromJson(register(instance, publicKey));

  /// [enroll]'s answer as the backend sends it, which the app hands to `sync.enroll`.
  Map<String, Object?> register(String instance, String publicKey) {
    final id = "d-${++_next}";
    _devices[id] = (instance: instance, key: base64.decode(publicKey), revoked: false, from: _log.length);

    return {
      "device": id,
      "company": company,
      "site": site,
      "edgeKey": {"kid": "2026-10", "publicKey": edgeKey},
      "allowance": allowance,
      "endpoint": "https://cloud.test$base",
    };
  }

  void revoke(String device) {
    final current = _devices[device]!;
    _devices[device] = (instance: current.instance, key: current.key, revoked: true, from: current.from);
  }

  /// `POST /edge/v1/grants` (§9): a grant for [email] on [device], signed as the backend signs it.
  /// [payload] overrides the statement's keys, to forge or age one; [seed] signs with another key.
  Future<String> grant(String device, String email, {DateTime? now, Map<String, Object?> payload = const {},
      List<int>? seed}) async {
    final issued = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final bytes = utf8.encode(jsonEncode({
      "v": 1,
      "kid": "2026-10",
      "device": device,
      "company": company,
      "account": {"id": "u-1", "email": email},
      "nonce": "${++_next}".padLeft(22, "n"),
      "iat": issued,
      "exp": issued + 120,
      ...payload,
    }));
    final signature = await Ed25519().sign(bytes, keyPair: await Ed25519().newKeyPairFromSeed(seed ?? edgeSeed));
    String part(List<int> value) => base64Url.encode(value).replaceAll("=", "");

    return "${part(bytes)}.${part(signature.bytes)}";
  }

  // ------------------------------------------------------------------- the cloud app

  /// A record made in the cloud; answers its cloud id.
  String create(String entity, Map<String, Object?> fields, {Map<String, Object?> cells = const {}}) {
    final id = "c-${++_next}";
    _write(entity, id, EdgeOps.upsert, fields, cells, clock.tick(), origin: null);

    return id;
  }

  /// [at] stamps it by hand: an edit made earlier, or far in the future.
  void edit(String entity, String id, {Map<String, Object?> fields = const {}, Map<String, Object?> cells = const {}, Hlc? at}) =>
    _write(entity, id, EdgeOps.upsert, fields, cells, at ?? clock.tick(), origin: null);

  void delete(String entity, String id, {Hlc? at}) =>
    _write(entity, id, EdgeOps.delete, const {}, const {}, at ?? clock.tick(), origin: null);

  String append(String entity, Map<String, Object?> fields) {
    final id = "c-${++_next}";
    _write(entity, id, EdgeOps.append, fields, const {}, clock.tick(), origin: null);

    return id;
  }

  // ------------------------------------------------------------------------- reading

  /// The cloud id the master's [localId] got, if any.
  String? cloudIdOf(String device, String entity, String localId) => _ids["$device|$entity|m:$localId"];

  /// A record's values as the cloud holds them; null when it has none.
  ({Map<String, Object?> fields, Map<String, Object?> cells, bool deleted, bool voided})? record(String entity, String id) {
    final record = _records[entity]?[id];
    if (record == null) return null;

    return (
      fields: {for (final entry in record.fields.entries) entry.key: entry.value.$1},
      cells: {for (final entry in record.cells.entries) entry.key: entry.value.$1},
      deleted: record.deleted?.$1 ?? false,
      voided: record.voided,
    );
  }

  Iterable<String> ids(String entity) => _records[entity]?.keys ?? const [];

  /// How many changes the backend took from masters, duplicates and refusals left out.
  int applied = 0;

  // ------------------------------------------------------------------------- the API

  @override
  Future<EdgeResponse> send(EdgeRequest request) async {
    if (unreachable > 0) {
      unreachable--;
      throw const EdgeFailure(0, "unreachable");
    }

    final deviceId = request.headers["Edge-Device"];
    final device = deviceId == null ? null : _devices[deviceId];
    if (device == null) return _error(401, "edge_unknown");
    if (device.revoked) return _error(401, "edge_revoked");
    if (!await EdgeSigner.verify(request, device.key)) return _error(401, "edge_signature");
    if (!_nonces.add("$deviceId|${request.headers["Edge-Nonce"]}")) return _error(401, "edge_replay");
    if (!request.path.startsWith(base)) return _error(404, "not_found");

    final uri = Uri.parse(request.path.substring(base.length));

    if (uri.path == "/status") return _ok({"device": deviceId, "company": company, "site": site});
    if (allowance == EdgeAllowance.exceeded) return _error(402, "allowance_exceeded");

    final response = switch ((request.method, uri.path)) {
      ("POST", "/commands") => _commandsCall(deviceId!, request.json!),
      ("GET", "/changes") => _changes(deviceId!, uri.queryParameters),
      ("GET", "/snapshot") => _snapshot(uri.queryParameters),
      _ => _error(404, "not_found"),
    };

    if (answersLost > 0 && request.method == "POST") {
      answersLost--;
      throw const EdgeFailure(0, "unreachable");
    }

    return response;
  }

  EdgeResponse _commandsCall(String device, Map<String, Object?> body) {
    final results = <Map<String, Object?>>[];

    for (final raw in body["changes"] as List) {
      final change = raw as Map<String, Object?>;
      final commandId = change["commandId"] as String;

      if (_commands[commandId] case final first?) {
        results.add({...first, "status": first["status"] == "rejected" ? "rejected" : "duplicate"});
        continue;
      }

      final result = _take(device, change);
      _commands[commandId] = result;
      results.add(result);
    }

    return _ok({"results": results});
  }

  Map<String, Object?> _take(String device, Map<String, Object?> change) {
    final entity = change["entity"] as String;
    final op = change["op"] as String;
    final hlc = Hlc.parse(change["hlc"] as String);
    final reason = refuse?.call(change);
    if (reason != null) return {"commandId": change["commandId"], "status": "rejected", "reason": reason};

    String? resolve(String entity, String id, {bool create = false}) {
      if (!id.startsWith("m:")) return id;

      final key = "$device|$entity|$id";
      return _ids[key] ?? (create ? _ids[key] = "c-${++_next}" : null);
    }

    final rejected = {"commandId": change["commandId"], "status": "rejected", "reason": "unknown_reference"};
    final natural = entity == "currency";
    final id = natural
      ? change["id"] as String
      : entity == "company" ? company : entity == "site" ? site
      : resolve(entity, change["id"] as String, create: op == EdgeOps.upsert || op == EdgeOps.append);
    if (id == null) return rejected;

    final fields = <String, Object?>{};
    for (final entry in (change["fields"] as Map? ?? const {}).entries) {
      final target = _refs[entity]?[entry.key];
      final value = entry.value;
      if (target == null || value is! String) {
        fields[entry.key as String] = value;
        continue;
      }

      final resolved = resolve(target, value);
      if (resolved == null) return rejected;
      fields[entry.key as String] = resolved;
    }

    final cells = <String, Object?>{};
    for (final entry in (change["cells"] as Map? ?? const {}).entries) {
      final resolved = resolve("product_field", entry.key as String);
      if (resolved == null) return rejected;
      cells[resolved] = entry.value;
    }

    clock.receive(hlc);

    // A fact the backend already has is the same fact.
    if (op == EdgeOps.append && _records[entity]?[id] != null) {
      return {"commandId": change["commandId"], "status": "duplicate", "cloudId": id};
    }

    _write(entity, id, op, fields, cells, hlc, origin: device);
    applied++;

    return {"commandId": change["commandId"], "status": "accepted", "cloudId": id};
  }

  EdgeResponse _changes(String device, Map<String, String> query) {
    final from = query["cursor"] == null ? _devices[device]!.from : int.parse(query["cursor"]!);
    final limit = int.parse(query["limit"] ?? "500");
    final pending = _log.where((entry) => entry.seq > from && entry.origin != device).toList();
    final page = pending.take(limit).toList();

    return _ok({
      "changes": [for (final entry in page) entry.change],
      "cursor": "${page.isEmpty ? (from > _log.length ? from : _log.length) : page.last.seq}",
      "more": pending.length > page.length,
    });
  }

  EdgeResponse _snapshot(Map<String, String> query) => _ok({
    "changes": [
      for (final MapEntry(key: entity, value: records) in _records.entries)
        for (final MapEntry(key: id, value: record) in records.entries)
          if (record.deleted?.$1 != true)
            {
              "commandId": "snapshot:$entity:$id",
              "hlc": record.newest.pack(),
              "entity": entity,
              "id": id,
              "op": _facts.contains(entity) ? EdgeOps.append : EdgeOps.upsert,
              "fields": {for (final entry in record.fields.entries) entry.key: entry.value.$1},
              "cells": {for (final entry in record.cells.entries) entry.key: entry.value.$1},
            },
    ],
    "done": true,
    "changes_cursor": "${_log.length}",
  });

  /// Settles a change field by field (the contract's §5) and logs what won.
  void _write(String entity, String id, String op, Map<String, Object?> fields, Map<String, Object?> cells, Hlc hlc,
      {required String? origin}) {
    final record = (_records[entity] ??= {})[id] ??= _Record();
    final won = <String, Object?>{};
    final wonCells = <String, Object?>{};

    switch (op) {
      case EdgeOps.delete:
        if (record.deleted == null || record.deleted!.$2.compareTo(hlc) < 0) record.deleted = (true, hlc);
      case EdgeOps.voided:
        record.voided = true;
        won.addAll(fields);
      default:
        for (final MapEntry(key: field, value: value) in fields.entries) {
          if (record.fields[field] == null || record.fields[field]!.$2.compareTo(hlc) < 0) {
            record.fields[field] = (value, hlc);
            won[field] = value;
          }
        }
        for (final MapEntry(key: cell, value: value) in cells.entries) {
          if (record.cells[cell] == null || record.cells[cell]!.$2.compareTo(hlc) < 0) {
            record.cells[cell] = (value, hlc);
            wonCells[cell] = value;
          }
        }
        if (op == EdgeOps.upsert && record.deleted != null && record.deleted!.$2.compareTo(hlc) < 0) record.deleted = (false, hlc);
    }

    _log.add((seq: _log.length + 1, origin: origin, change: {
      "commandId": "cloud-${_log.length + 1}",
      "hlc": hlc.pack(),
      "entity": entity,
      "id": id,
      "op": op,
      "fields": won,
      "cells": wonCells,
    }));
  }

  EdgeResponse _ok(Map<String, Object?> body) => EdgeResponse(200, {...body, "allowance": allowance});

  EdgeResponse _error(int status, String code) => EdgeResponse(status, {"code": code, "allowance": allowance});
}

final class _Record {
  final fields = <String, (Object?, Hlc)>{};
  final cells = <String, (Object?, Hlc)>{};
  (bool, Hlc)? deleted;
  bool voided = false;

  Hlc get newest => [...fields.values.map((value) => value.$2), ...cells.values.map((value) => value.$2)]
    .fold(Hlc(0, 0, "cloud"), (newest, hlc) => hlc.compareTo(newest) > 0 ? hlc : newest);
}
