import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lyra_protocol/lyra_protocol.dart';

import '../engine.dart';
import '../failure.dart';
import '../identity/devices.dart';
import '../identity/sessions.dart';
import '../oplog/commands.dart';
import 'events.dart';
import 'messages.dart';
import 'ops.dart';
import 'server.dart';

/// Who may run an op, checked before its handler runs. The master is the gate (plan §5.4):
/// a client hiding a button is a convenience, never the rule.
enum Gate {
  /// Before anything is known (`hello`, `device.prove`).
  anyone,

  /// A paired, not revoked device (`auth.*`, `session.bind`).
  device,

  /// A device with a live session bound to the connection.
  session,
}

/// How one op is served.
final class OpRule {
  const OpRule(
    this.handler, {
    this.gate = Gate.session,
    this.permission,
    this.masterOnly = false,
    this.whileLocked = false,
    this.sealedArgs = const {},
  });

  final Future<Object?> Function(OpCall call) handler;
  final Gate gate;

  /// The permission id of `docs/app-areas.json` the session must hold.
  final String? permission;

  /// Only from the master's own device (`engine.unlock`, `pairing.start`).
  final bool masterOnly;

  /// Served while the engine is locked (plan §6.2).
  final bool whileLocked;

  /// Args left out of the `commandId` ledger's hash: a sealed field (plan §6.3) is often a phone
  /// or an id number, few enough guesses that its plain hash would give it away. The ledger keeps
  /// the answer in clear, so such an op answers without them.
  final Set<String> sealedArgs;

  /// [args] as the ledger hashes them.
  Map<String, Object?> hashed(Map<String, Object?> args) => sealedArgs.isEmpty
    ? args
    : {for (final MapEntry(:key, :value) in args.entries) if (!sealedArgs.contains(key)) key: value};
}

/// One request being served: its arguments and the connection it came on.
final class OpCall {
  OpCall(this.connection, this.request, this.rule);

  final RpcConnection connection;
  final RpcRequest request;
  final OpRule rule;

  Map<String, Object?> get args => request.args;

  Engine get engine => connection.server.engine!;

  Device get device => connection.device!;

  SessionGrant get session => connection.session!;

  /// A required string argument (`required` when missing, `invalid_field` when not a string).
  String text(String name, {int max = 256}) {
    final value = args[name];

    if (value == null) throw EngineFailure(ErrorCodes.required, {"field": name});
    if (value is! String || value.length > max) throw EngineFailure(ErrorCodes.invalidField, {"field": name});

    return value;
  }

  /// Runs a write op's change and keeps its answer under its `commandId`, **in one
  /// transaction** (the domain's own writes join it). If the same command already ran, [body]
  /// doesn't run again and the first answer comes back.
  ///
  /// [keep] is what the ledger keeps instead, for an answer that carries a secret shown once (an
  /// activation code): a replay then answers without it.
  T write<T extends Object?>(T Function() body, {Object? Function(T answer)? keep}) => engine.store.write((db) {
    final ledger = CommandLedger(db);
    final commandId = request.commandId!;
    final hashed = rule.hashed(args);
    final kept = ledger.replay(commandId, request.op, hashed);

    if (kept.found) return kept.answer as T;

    final answer = body();
    ledger.record(commandId, request.op, hashed, keep == null ? answer : keep(answer), engine.now());

    return answer;
  });

  /// Sends [event] frames right after this op's answer (the replay of `events.subscribe`).
  void afterAnswer(void Function() send) => connection._afterAnswer.add(send);
}

/// One `/rpc` WebSocket (`protocol-v1.md` §2, §4): the handshake, the device it proved to be,
/// the session bound to it, its event subscription.
///
/// Frames are served **one at a time, in order**: an answer never overtakes an earlier one on
/// the same connection, and writes reach the store in the order the client sent them.
final class RpcConnection {
  RpcConnection(this.server, this._socket, {this.certFingerprint}) {
    _socket.pingInterval = const Duration(seconds: 20);
    identify();
  }

  /// Per session (`protocol-v1.md` §7): 50 a second, bursts of 200.
  static const _rate = 50.0;
  static const _burst = 200.0;

  final LanServer server;
  final WebSocket _socket;

  /// SHA-256 of the client certificate TLS verified; null for a browser.
  final String? certFingerprint;

  Device? device;
  SessionGrant? session;
  /// What the bound session's person may do; replaced at once when it changes (`session.md` P-8).
  Grant grant = Grant.none();
  String? _accessToken;
  bool _helloDone = false;
  bool _revoked = false;
  Uint8List? challenge;

  StreamSubscription<StoredEvent>? _events;
  List<StoredEvent>? _pendingLive;
  int _lastEventSeq = 0;
  final List<void Function()> _afterAnswer = [];

  Future<void> _queue = Future.value();
  double _tokens = _burst;
  DateTime _refilled = DateTime.now();

  /// Whether this connection comes from the master's own app (its certificate is the one the
  /// transport file names, which a locked engine can still check).
  bool get isMasterDevice => certFingerprint != null && certFingerprint == server.transport.masterDevice;

  bool get isBrowser => certFingerprint == null;

  /// Loads the device behind the certificate once the engine is open.
  void identify() {
    final engine = server.engine;
    if (engine == null || certFingerprint == null || device != null) return;

    device = engine.devices.byFingerprint(certFingerprint!);
  }

  Future<void> serve() {
    final done = Completer<void>();

    _socket.listen(
      (frame) => _queue = _queue.then((_) => _receive(frame)).catchError((Object error, StackTrace stack) {
        server.log?.error("rpc frame failed: $error\n$stack");
      }),
      onDone: () {
        _closed();
        done.complete();
      },
      onError: (_) {},
      cancelOnError: false,
    );

    return done.future;
  }

  /// Closes the connection now (a revoked device, S-41).
  Future<void> drop(int code, String reason) async {
    _closed();
    await _socket.close(code, reason);
  }

  /// The session was ended elsewhere: the next frame answers `session_revoked` and the
  /// connection closes (S-23).
  void revokeSession() => _revoked = true;

  Future<void> _receive(Object? frame) async {
    if (frame is! String) return drop(WebSocketStatus.unsupportedData, "text frames only");

    if (frame.length > maxFrameBytes || (frame.length * 3 > maxFrameBytes && utf8.encode(frame).length > maxFrameBytes)) {
      _send(RpcResponse.failed(0, Messages.of(ErrorCodes.frameTooLarge)));
      return drop(WebSocketStatus.messageTooBig, ErrorCodes.frameTooLarge);
    }

    final Frame decoded;
    try {
      decoded = Frame.decode(frame);
    } on FormatException {
      return _send(RpcResponse.failed(0, Messages.of(ErrorCodes.badRequest)));
    }

    if (decoded is! RpcRequest) return _send(RpcResponse.failed(0, Messages.of(ErrorCodes.badRequest)));

    final answer = await _dispatch(decoded);
    _send(answer);

    final after = List.of(_afterAnswer);
    _afterAnswer.clear();
    for (final send in after) {
      send();
    }

    server.engine?.events.publish();

    final close = answer.ok ? null : closeCodes[answer.error!.code];
    if (close != null) await drop(close, answer.error!.code);
  }

  /// Refusals after which the connection is closed (`protocol-v1.md` §4, S-23), with the
  /// WebSocket close code a client reads.
  static const closeCodes = {
    ErrorCodes.deviceRevoked: 4001,
    ErrorCodes.versionMismatch: 4002,
    ErrorCodes.sessionRevoked: 4003,
  };

  Future<RpcResponse> _dispatch(RpcRequest request) async {
    RpcResponse failed(String code, [Map<String, Object?> data = const {}]) =>
      RpcResponse.failed(request.id, Messages.of(code, data));

    final op = Ops.byName(request.op);
    final rule = op == null ? null : opRules[op.name];

    if (!_helloDone && request.op != Ops.hello.name) return failed(ErrorCodes.badRequest, {"expected": Ops.hello.name});
    if (op == null || rule == null) return failed(ErrorCodes.unknownOp);
    if (!_take()) return failed(ErrorCodes.rateLimited, {"retryAfter": 1});

    final engine = server.engine;
    if (engine == null && !rule.whileLocked) return failed(ErrorCodes.locked);
    if (rule.masterOnly && !isMasterDevice) return failed("not_master");

    if (rule.gate != Gate.anyone) {
      identify();
      if (certFingerprint != null && engine != null && (device == null || device!.isRevoked)) {
        return failed(ErrorCodes.deviceRevoked);
      }
      if (device == null && !(rule.whileLocked && isMasterDevice)) return failed(ErrorCodes.forbidden);
    }

    if (rule.gate == Gate.session) {
      final refusal = _checkSession();
      if (refusal != null) return failed(refusal);
    }

    if (rule.permission != null) {
      if (!grant.can(rule.permission!)) return failed(ErrorCodes.forbidden);
      // A PIN session runs POS ops only (S-22).
      if (session?.scope == SessionScope.pos && !rule.permission!.startsWith("pos.")) return failed(ErrorCodes.forbidden);
    }

    if (op.needsCommandId != (request.commandId != null)) {
      return failed(ErrorCodes.badRequest, {"field": "commandId"});
    }

    try {
      if (op.needsCommandId) {
        final kept = CommandLedger(engine!.store.db).replay(request.commandId!, request.op, rule.hashed(request.args));
        if (kept.found) return RpcResponse.ok(request.id, kept.answer);
      }

      return RpcResponse.ok(request.id, await rule.handler(OpCall(this, request, rule)));
    } on EngineFailure catch (failure) {
      return RpcResponse.failed(request.id, Messages.ofFailure(failure));
    } on CommandReused {
      return failed(ErrorCodes.commandReused);
    } on FormatException {
      return failed(ErrorCodes.badRequest);
    } on TypeError {
      // An argument of the wrong type reached a cast.
      return failed(ErrorCodes.badRequest);
    } catch (error, stack) {
      server.log?.error("op ${request.op} failed: $error\n$stack");
      return failed(ErrorCodes.internal);
    }
  }

  /// Null when the bound session is live; otherwise the refusal.
  String? _checkSession() {
    final engine = server.engine!;
    final bound = session;

    if (_revoked) return ErrorCodes.sessionRevoked;
    if (bound == null || _accessToken == null) return ErrorCodes.sessionExpired;

    final grant = engine.sessions.access(_accessToken!);
    if (grant != null) {
      session = grant;
      return null;
    }

    final open = engine.sessions.isOpen(bound.sessionId);
    unbind();

    return open ? ErrorCodes.sessionExpired : ErrorCodes.sessionRevoked;
  }

  /// Marks the handshake done (the `hello` handler).
  void helloDone() => _helloDone = true;

  /// Ties the connection to a session (`session.bind`, S-20).
  void bind(String accessToken, SessionGrant grant, Grant permissions) {
    _accessToken = accessToken;
    session = grant;
    this.grant = permissions;
    _revoked = false;
  }

  void unbind() {
    _accessToken = null;
    session = null;
    grant = Grant.none();
    unsubscribe();
  }

  /// Starts the event stream (`events.subscribe`): the answer first, then the replay after
  /// [since], then live events, in `seq` order with nothing twice.
  int subscribe(int? since) {
    final events = server.engine!.events;
    final replay = since == null ? const <StoredEvent>[] : events.since(since);

    unsubscribe();
    _lastEventSeq = since ?? events.head;
    _pendingLive = [];
    _events = events.live.listen((event) {
      final pending = _pendingLive;
      pending == null ? _deliver(event) : pending.add(event);
    });

    _afterAnswer.add(() {
      final live = _pendingLive ?? const [];
      _pendingLive = null;

      for (final event in [...replay, ...live]) {
        _deliver(event);
      }
    });

    return events.head;
  }

  void unsubscribe() {
    _events?.cancel();
    _events = null;
    _pendingLive = null;
  }

  void _deliver(StoredEvent event) {
    final bound = session;
    if (bound == null || event.seq <= _lastEventSeq) return;

    _lastEventSeq = event.seq;
    if (event.visibleTo(bound.accountId, grant)) _socket.add(event.frame.encode());
  }

  bool _take() {
    final now = DateTime.now();
    _tokens = (_tokens + now.difference(_refilled).inMicroseconds / 1e6 * _rate).clamp(0, _burst);
    _refilled = now;

    if (_tokens < 1) return false;
    _tokens -= 1;

    return true;
  }

  void _send(RpcResponse response) {
    if (_socket.readyState == WebSocket.open) _socket.add(response.encode());
  }

  void _closed() {
    unsubscribe();
    server.forget(this);
  }
}
