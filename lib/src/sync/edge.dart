import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import '../crypto/secrets.dart';
import '../oplog/hlc.dart';

/// What a change does on the wire (`task-edge-sync-backend.md` §4).
abstract final class EdgeOps {
  /// Creates the record or changes only the fields it carries.
  static const upsert = "upsert";

  /// A tombstone.
  static const delete = "delete";

  /// A fact, never edited after.
  static const append = "append";

  /// A fact made void.
  static const voided = "void";
}

/// One change on the wire, either direction (`task-edge-sync-backend.md` §4). Ids are cloud ids,
/// or the master's own as `m:<id>` until the cloud has answered one ([EdgeIds]).
final class EdgeChange {
  const EdgeChange({
    required this.commandId,
    required this.hlc,
    required this.entity,
    required this.id,
    required this.op,
    this.fields = const {},
    this.cells = const {},
    this.actor,
  });

  /// Throws [FormatException] on a change that isn't one, so a bad page stops the pull loudly.
  factory EdgeChange.fromJson(Object? json) {
    if (json is! Map) throw const FormatException("A change is an object");

    final commandId = json["commandId"], hlc = json["hlc"], entity = json["entity"], id = json["id"], op = json["op"];
    if (commandId is! String || hlc is! String || entity is! String || id is! String || op is! String) {
      throw FormatException("Not a change: $json");
    }

    return EdgeChange(
      commandId: commandId,
      hlc: Hlc.parse(hlc),
      entity: entity,
      id: id,
      op: op,
      fields: Map<String, Object?>.from(json["fields"] as Map? ?? const {}),
      cells: Map<String, Object?>.from(json["cells"] as Map? ?? const {}),
      actor: json["actor"] as String?,
    );
  }

  final String commandId;
  final Hlc hlc;
  final String entity;
  final String id;
  final String op;
  final Map<String, Object?> fields;

  /// A product's values, keyed by its table's field ids.
  final Map<String, Object?> cells;

  /// The person's e-mail, when there is one.
  final String? actor;

  Map<String, Object?> toJson() => {
    "commandId": commandId,
    "hlc": hlc.pack(),
    "entity": entity,
    "id": id,
    "op": op,
    if (fields.isNotEmpty) "fields": fields,
    if (cells.isNotEmpty) "cells": cells,
    "actor": actor,
  };
}

/// An edge request, signed before it leaves (`task-edge-sync-backend.md` §2).
final class EdgeRequest {
  const EdgeRequest(this.method, this.path, this.body, this.headers);

  final String method;

  /// The path with its query, exactly as sent and signed.
  final String path;

  /// Empty for a request without one.
  final Uint8List body;
  final Map<String, String> headers;

  Map<String, Object?>? get json => body.isEmpty ? null : jsonDecode(utf8.decode(body)) as Map<String, Object?>;
}

final class EdgeResponse {
  const EdgeResponse(this.status, this.body);

  final int status;
  final Map<String, Object?> body;
}

/// Carries signed requests to the cloud: HTTPS in the engine ([HttpEdgeTransport]), an in-memory
/// backend in the tests.
abstract interface class EdgeTransport {
  Future<EdgeResponse> send(EdgeRequest request);
}

/// The edge call failed: the cloud answered an error ([status], [code]), or nobody answered
/// ([status] 0).
final class EdgeFailure implements Exception {
  const EdgeFailure(this.status, this.code, [this.data = const {}]);

  final int status;
  final String code;
  final Map<String, Object?> data;

  /// The device was revoked or never known: syncing stops until it is enrolled again.
  bool get revoked => code == "edge_revoked" || code == "edge_unknown";

  bool get allowanceExceeded => code == "allowance_exceeded";

  bool get cursorExpired => code == "cursor_expired";

  @override
  String toString() => "EdgeFailure($status, $code)";
}

/// The master's edge credential: an Ed25519 pair, the private half known only here. Every request
/// is signed with it, so no bearer secret travels or rests anywhere.
final class EdgeSigner {
  EdgeSigner(this.device, this._pair, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  static final _ed25519 = Ed25519();

  final String device;
  final SimpleKeyPair _pair;
  final DateTime Function() _now;

  /// A new pair: the 32-byte seed (to seal and keep) and the public key (for the backend).
  static Future<({Uint8List seed, Uint8List publicKey})> generate() async {
    final seed = randomBytes(32);
    final pair = await _ed25519.newKeyPairFromSeed(seed);

    return (seed: seed, publicKey: Uint8List.fromList((await pair.extractPublicKey()).bytes));
  }

  static Future<EdgeSigner> fromSeed(String device, List<int> seed, {DateTime Function()? now}) async =>
    EdgeSigner(device, await _ed25519.newKeyPairFromSeed(seed), now: now);

  /// What the signature covers: method, path, time, nonce and the body's digest.
  static String canonical(String method, String path, String time, String nonce, List<int> body) =>
    "$method\n$path\n$time\n$nonce\n${sha256.convert(body)}";

  Future<EdgeRequest> sign(String method, String path, [Map<String, Object?>? json]) async {
    final body = json == null ? Uint8List(0) : Uint8List.fromList(utf8.encode(jsonEncode(json)));
    final time = _now().millisecondsSinceEpoch.toString();
    final nonce = base64Url.encode(randomBytes(16)).replaceAll("=", "");
    final signature = await _ed25519.sign(utf8.encode(canonical(method, path, time, nonce, body)), keyPair: _pair);

    return EdgeRequest(method, path, body, {
      "Edge-Device": device,
      "Edge-Time": time,
      "Edge-Nonce": nonce,
      "Edge-Signature": base64.encode(signature.bytes),
      if (body.isNotEmpty) "Content-Type": "application/json",
    });
  }

  /// Checks a request [sign] made: the backend's side, here for the in-memory backend of the tests.
  static Future<bool> verify(EdgeRequest request, List<int> publicKey) async {
    final headers = request.headers;
    final time = headers["Edge-Time"], nonce = headers["Edge-Nonce"], signature = headers["Edge-Signature"];
    if (time == null || nonce == null || signature == null) return false;

    try {
      return await _ed25519.verify(
        utf8.encode(canonical(request.method, request.path, time, nonce, request.body)),
        signature: Signature(base64.decode(signature), publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
      );
    } on FormatException {
      return false;
    }
  }
}

/// The edge API over HTTPS, with the OS's trust store: the cloud has a public certificate, unlike
/// the LAN, whose installation CA this never uses.
final class HttpEdgeTransport implements EdgeTransport {
  HttpEdgeTransport(this.endpoint, {this.timeout = const Duration(seconds: 30)});

  /// The `endpoint` the enrolment answered, e.g. `https://api…/edge/v1`: its origin. A request's
  /// path is already the whole path, the one its signature covers.
  final String endpoint;
  final Duration timeout;
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);

  @override
  Future<EdgeResponse> send(EdgeRequest request) async {
    try {
      final target = Uri.parse(request.path);
      final uri = Uri.parse(endpoint).replace(path: target.path, query: target.hasQuery ? target.query : null);
      final out = await _client.openUrl(request.method, uri).timeout(timeout);
      request.headers.forEach(out.headers.set);
      out.add(request.body);

      final answer = await out.close().timeout(timeout);
      final text = await answer.transform(utf8.decoder).join().timeout(timeout);
      final body = text.isEmpty ? const <String, Object?>{} : jsonDecode(text);

      return EdgeResponse(answer.statusCode, body is Map<String, Object?> ? body : const {});
    } on Object catch (error) {
      if (error is EdgeFailure) rethrow;
      throw EdgeFailure(0, "unreachable", {"error": error.runtimeType.toString()});
    }
  }

  void close() => _client.close(force: true);
}
