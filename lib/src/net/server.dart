import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lyra_protocol/lyra_protocol.dart';

import '../engine.dart';
import '../failure.dart';
import '../identity/grants.dart';
import '../identity/sessions.dart';
import '../process/engine_log.dart';
import 'files.dart';
import 'messages.dart';
import 'pairing.dart';
import 'rpc.dart';
import 'tls.dart';
import 'web_bundle.dart';

/// The master's one port on the LAN (`protocol-v1.md` §1, plan §5.1): HTTPS and WSS over
/// **TLS 1.3 only**. There is no plaintext listener, not even a redirect, in any build.
///
/// It starts before the engine is unlocked (passphrase mode): then it answers `hello` and, from
/// the master's own device, `engine.unlock`, and nothing else ([ready] hands it the engine).
final class LanServer {
  LanServer({
    required this.instanceId,
    required Transport transport,
    this.requestedPort = defaultPort,
    this.address,
    this.webRoot,
    this.log,
    Future<Engine> Function(String passphrase)? unlock,
    Engine? engine,
  }) : _transport = transport, _unlock = unlock {
    if (engine != null) ready(engine);
  }

  final String instanceId;
  final int requestedPort;

  /// Where to listen; every interface (IPv4 and IPv6) when null.
  final InternetAddress? address;

  /// The web build to serve at `/` (plan §3); none when null.
  final String? webRoot;
  final EngineLog? log;
  final Future<Engine> Function(String passphrase)? _unlock;

  /// What TLS serves; replaced when the master device changes or the certificate is renewed
  /// (the next handshake serves it: `Transport.serveFrom`).
  Transport get transport => _transport;
  set transport(Transport value) {
    _transport = value;
    if (_context case final context?) value.serveFrom(context);
  }

  Transport _transport;
  SecurityContext? _context;

  /// Called after `business.create`: the master now has a name for browsers (`LanName`).
  void Function()? onCompanyCreated;

  Engine? _engine;
  Engine? get engine => _engine;

  PairingDesk? _pairing;
  PairingDesk? get pairing => _pairing;

  HttpServer? _http;
  final Set<RpcConnection> _connections = {};
  final Map<String, List<DateTime>> _signIns = {};
  Timer? _sweeper;

  int get port => _http?.port ?? requestedPort;

  Future<void> start() async {
    final bind = address ?? InternetAddress.anyIPv6;

    _http = await HttpServer.bindSecure(
      bind,
      requestedPort,
      _context = transport.context,
      v6Only: false,
      requestClientCertificate: true,
    );
    _http!.idleTimeout = const Duration(seconds: 30);
    _http!.listen((request) => unawaited(_handle(request).catchError((Object error, StackTrace stack) {
      log?.error("request ${request.uri.path} failed: $error\n$stack");
      _plain(request.response, HttpStatus.internalServerError);
    })));
  }

  /// The engine is open (at start, or after `engine.unlock`).
  void ready(Engine engine) {
    _engine = engine;
    _pairing = PairingDesk(engine);
    for (final connection in _connections) {
      connection.identify();
    }

    _sweeper?.cancel();
    _sweeper = Timer.periodic(const Duration(minutes: 10), (_) {
      engine.files.sweep();
      engine.events.prune();
    });
  }

  /// `engine.unlock`: opens the engine with [passphrase]. A wrong one answers
  /// `wrong_passphrase` and leaves it locked.
  Future<void> unlock(String passphrase) async {
    if (_engine != null) return;
    if (_unlock == null) throw const EngineFailure(ErrorCodes.locked);

    ready(await _unlock(passphrase));
  }

  bool isOnline(String deviceId) => _connections.any((connection) => connection.device?.id == deviceId);

  /// `session.md` S-4: 20 sign ins a minute per device.
  bool allowSignIn(String deviceId) {
    final now = DateTime.now();
    final recent = (_signIns[deviceId] ?? const [])
      .where((at) => now.difference(at) < const Duration(minutes: 1))
      .toList();

    if (recent.length >= 20) return false;
    _signIns[deviceId] = [...recent, now];

    return true;
  }

  /// Closes every connection of a revoked device (S-41).
  Future<void> dropDevice(String deviceId) async {
    final doomed = _connections.where((connection) => connection.device?.id == deviceId).toList();

    for (final connection in doomed) {
      await connection.drop(RpcConnection.closeCodes[ErrorCodes.deviceRevoked]!, ErrorCodes.deviceRevoked);
    }
  }

  /// Sessions ended elsewhere (a password change): their connections answer `session_revoked`
  /// on the next frame (S-23).
  void revokeSessions(Iterable<String> sessionIds) {
    final ids = sessionIds.toSet();

    for (final connection in _connections) {
      if (ids.contains(connection.session?.sessionId)) connection.revokeSession();
    }
  }

  /// [account]'s permissions changed (`session.md` P-8): its connections check the new ones from
  /// the next frame. The `permissions/changed` event, appended in the same write, tells the app.
  void regrant(String account) {
    final grant = Grants.of(engine!.store.db, account);

    for (final connection in _connections) {
      if (connection.session?.accountId == account) connection.grant = grant;
    }
  }

  void forget(RpcConnection connection) => _connections.remove(connection);

  Future<void> close() async {
    _sweeper?.cancel();
    for (final connection in _connections.toList()) {
      await connection.drop(WebSocketStatus.goingAway, "server stopping");
    }
    await _http?.close(force: true);
    _http = null;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final path = request.uri.path;

    // HSTS on every answer; the bundle adds its own CSP (`protocol-v1.md` §1).
    response.headers
      ..set("Strict-Transport-Security", "max-age=31536000")
      ..set("X-Content-Type-Options", "nosniff")
      ..set("Referrer-Policy", "no-referrer")
      ..set("Cache-Control", "no-store");

    if (path == "/rpc") return _rpc(request);
    if (path == "/pair") return _pair(request);
    if (path == "/f" || path.startsWith("/f/")) return _files(request);

    final root = webRoot;
    if (root != null && request.method == "GET") return WebBundle(root).serve(request);

    _plain(response, HttpStatus.notFound);
  }

  Future<void> _rpc(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) return _plain(request.response, HttpStatus.badRequest);
    if (!_ownOrigin(request)) return _plain(request.response, HttpStatus.forbidden);

    final certificate = request.certificate;
    final fingerprint = certificate == null ? null : Fingerprint.of(certificate.der);
    final engine = _engine;

    // A revoked certificate still chains to the CA, so TLS accepts it; it is refused here,
    // before any frame (`protocol-v1.md` §3, S-41).
    if (fingerprint != null && engine != null) {
      final device = engine.devices.byFingerprint(fingerprint);
      if (device == null || device.isRevoked) return _plain(request.response, HttpStatus.forbidden);
    }

    final socket = await WebSocketTransformer.upgrade(request);
    final connection = RpcConnection(this, socket, certFingerprint: fingerprint);

    _connections.add(connection);
    await connection.serve();
  }

  Future<void> _pair(HttpRequest request) async {
    final desk = _pairing;

    if (!WebSocketTransformer.isUpgradeRequest(request)) return _plain(request.response, HttpStatus.badRequest);
    if (!_ownOrigin(request)) return _plain(request.response, HttpStatus.forbidden);
    if (desk == null) return _plain(request.response, HttpStatus.serviceUnavailable);

    final socket = await WebSocketTransformer.upgrade(request);
    final incoming = StreamIterator(socket);

    try {
      await desk.serve(
        receive: () async {
          if (!await incoming.moveNext()) throw const FormatException("closed");

          final frame = incoming.current;
          final json = frame is String && frame.length <= 16 * 1024 ? jsonDecode(frame) : null;
          if (json is! Map<String, Object?>) throw const FormatException("not a pairing frame");

          return json;
        },
        send: (message) => socket.add(jsonEncode(message)),
        transport: transport,
      );
    } on Object catch (error) {
      // A peer that stops talking or sends garbage: the ticket's failure count covers guesses.
      if (error is! FormatException && error is! TimeoutException) log?.error("pairing failed: $error");
    } finally {
      await socket.close();
    }
  }

  /// A page of any other site, open in a browser that trusts the CA, could open a WebSocket to
  /// the master (cross-site WebSocket hijacking): it gets nothing without the device's key, but
  /// it isn't let in either. Browsers always send `Origin`; only the master's own web build, at
  /// the address the browser asked for, may upgrade. Native clients send no `Origin`.
  bool _ownOrigin(HttpRequest request) {
    final origin = request.headers.value("origin");
    if (origin == null) return true;

    final uri = Uri.tryParse(origin);
    final host = request.headers.host;

    return uri != null && uri.scheme == "https" && host != null && uri.host == host && uri.port == (request.headers.port ?? 443);
  }

  /// `GET /f/<id>` and `PUT /f` (`protocol-v1.md` §6), with the session's access token.
  Future<void> _files(HttpRequest request) async {
    final response = request.response;
    final engine = _engine;

    if (engine == null) return _json(response, HttpStatus.serviceUnavailable, Messages.of(ErrorCodes.locked).toJson());

    final header = request.headers.value(HttpHeaders.authorizationHeader) ?? "";
    final grant = header.startsWith("Bearer ") ? engine.sessions.access(header.substring(7)) : null;
    final certificate = request.certificate;

    if (grant == null) return _json(response, HttpStatus.unauthorized, Messages.of(ErrorCodes.sessionExpired).toJson());
    // A native client's token only works from its own device (S-20).
    if (certificate != null && engine.devices.byFingerprint(Fingerprint.of(certificate.der))?.id != grant.deviceId) {
      return _json(response, HttpStatus.forbidden, Messages.of(ErrorCodes.sessionRevoked).toJson());
    }

    final account = engine.accounts.byId(grant.accountId);
    if (account == null || grant.scope == SessionScope.pos && request.method == "PUT") {
      return _json(response, HttpStatus.forbidden, Messages.of(ErrorCodes.forbidden).toJson());
    }

    try {
      if (request.method == "PUT" && request.uri.path == "/f") {
        final purpose = FilePurpose.byHeader(request.headers.value("x-lyra-purpose"));
        if (purpose == null) throw const EngineFailure(ErrorCodes.invalidField, {"field": "purpose"});

        final bytes = await _readLimited(request, purpose.maxBytes);
        final id = await engine.files.put(purpose, bytes, owner: account.id);

        return _json(response, HttpStatus.ok, {"fileId": id});
      }

      if (request.method == "GET" && request.uri.pathSegments.length == 2) {
        final file = await engine.files.get(
          request.uri.pathSegments[1],
          account: account.id,
          grant: account.grant,
          size: int.tryParse(request.uri.queryParameters["size"] ?? ""),
        );

        response.headers.contentType = ContentType.parse(file.contentType);
        response.contentLength = file.bytes.length;
        response.add(file.bytes);
        return await response.close();
      }

      _plain(response, HttpStatus.methodNotAllowed);
    } on EngineFailure catch (failure) {
      final status = failure.code == ErrorCodes.notFound ? HttpStatus.notFound : HttpStatus.badRequest;
      _json(response, status, Messages.ofFailure(failure).toJson());
    }
  }

  /// The body, refused (`invalid_file`) as soon as it passes [limit], so an upload can't fill
  /// the memory.
  static Future<Uint8List> _readLimited(HttpRequest request, int limit) async {
    final length = request.contentLength;
    if (length > limit) throw EngineFailure("invalid_file", {"maxBytes": limit});

    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request) {
      bytes.add(chunk);
      if (bytes.length > limit) throw EngineFailure("invalid_file", {"maxBytes": limit});
    }

    return bytes.takeBytes();
  }

  static void _json(HttpResponse response, int status, Object body) {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    unawaited(response.close());
  }

  static void _plain(HttpResponse response, int status) {
    response.statusCode = status;
    unawaited(response.close());
  }
}
