import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/io.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';

const app = "0.0.7";

PairingDevice deviceNamed(String name, {String platform = "windows"}) =>
  PairingDevice(name: name, platform: platform, appVersion: app);

/// A master on loopback: set up with its own app enrolled, its engine open and its LAN server
/// listening on a free port. [master] is what the master's app keeps.
final class TestMaster {
  TestMaster._(this.paths, this.vault, this.engine, this.server, this.master, this.controlKey);

  static Future<TestMaster> start({String? passphrase}) async {
    final paths = tempPaths(addTearDown);
    final vault = MemoryVault();
    final key = EcKeyPair.generate();
    final setup = await setUpMaster(
      paths,
      vault,
      passphrase: passphrase,
      device: DeviceDraft(device: deviceNamed("Server"), publicKey: key.spki),
    );
    final controlKey = await Engine.controlKey(vault, setup.instanceId);
    final transport = (await Transport.read(paths.transport, controlKey))!;

    Future<Engine> open(String? secret) =>
      Engine.open(paths: paths, vault: vault, passphrase: secret, hasher: fastHasher);

    final engine = passphrase == null ? await open(null) : null;
    final server = LanServer(
      instanceId: setup.instanceId,
      transport: transport,
      requestedPort: 0,
      address: InternetAddress.loopbackIPv4,
      engine: engine,
      unlock: (secret) async {
        try {
          return await open(secret);
        } on KeyringError {
          throw const EngineFailure("wrong_passphrase");
        }
      },
    );

    await server.start();

    final test = TestMaster._(
      paths,
      vault,
      engine,
      server,
      LanIdentity(
        caCertificate: setup.device!.caCertificate,
        certificate: setup.device!.certificate,
        privateKeyPem: key.privateKeyPem,
      ),
      controlKey,
    );

    addTearDown(test.stop);

    return test;
  }

  final NodePaths paths;
  final MemoryVault vault;
  final Engine? engine;
  final LanServer server;
  final LanIdentity master;
  final List<int> controlKey;

  int get port => server.port;

  Engine get openEngine => server.engine!;

  bool _stopped = false;

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;

    await server.close();
    server.engine?.close();
  }

  /// Connects as [identity] (the master's app by default) and says hello.
  Future<RpcClient> connect([LanIdentity? identity]) async {
    final client = await connectRpc("127.0.0.1", port, identity ?? master);
    addTearDown(client.close);

    await client.hello(app: app, platform: "windows");

    return client;
  }

  /// Connects, signs the owner in and binds the session.
  Future<(RpcClient, Map<String, Object?>)> signIn([LanIdentity? identity]) async {
    final client = await connect(identity);
    final tokens = await client.call(Ops.authSignIn, args: {"login": owner.username, "password": owner.password})
      as Map<String, Object?>;

    await client.call(Ops.sessionBind, args: {"accessToken": tokens["accessToken"]});

    return (client, tokens);
  }

  /// Opens a pairing on the master's app: `{qr, code, expires}`.
  Future<Map<String, Object?>> openPairing() async {
    final (client, _) = await signIn();

    return await client.call(Ops.pairingStart) as Map<String, Object?>;
  }

  /// Pairs a new native device with the code, as its app would.
  Future<LanIdentity> pairNative(String name, {String? code, PairingOffer? offer}) async {
    final key = EcKeyPair.generate();
    final channel = await connectPairing("127.0.0.1", port);
    addTearDown(channel.close);

    final result = await pairDevice(
      channel,
      device: deviceNamed(name),
      signer: LocalDeviceSigner(key),
      code: offer == null ? code : null,
      offer: offer,
    );

    return LanIdentity(
      caCertificate: result.caCertificate,
      certificate: result.certificate!,
      privateKeyPem: key.privateKeyPem,
    );
  }
}

/// Expects [future] to fail with the master's [code].
Future<void> expectRefusal(Future<Object?> future, String code) =>
  expectLater(future, throwsA(isA<RpcError>().having((error) => error.code, "code", code)));

/// A WebSocket to `/rpc` that trusts the CA but presents **no** client certificate: what a
/// browser with the installed CA looks like to the master.
Future<RpcClient> connectAsBrowser(int port, List<int> caCertificate) async {
  final context = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificatesBytes(utf8.encode(Pem.encode("CERTIFICATE", caCertificate)));
  final socket = await WebSocket.connect("wss://127.0.0.1:$port/rpc", customClient: HttpClient(context: context));
  final client = RpcClient(_Frames(socket));
  addTearDown(client.close);

  return client;
}

final class _Frames implements FrameSocket {
  _Frames(this._socket);

  final WebSocket _socket;

  @override
  Stream<String> get frames => _socket.where((frame) => frame is String).cast<String>();

  @override
  void send(String frame) => _socket.add(frame);

  @override
  Future<void> close() => _socket.close();
}

/// A `/pair` channel run by hand, for the tests that play an attacker.
final class ScriptedChannel implements PairingChannel {
  ScriptedChannel(this._socket, this.serverFingerprint) {
    _socket.listen((frame) => _incoming.add(jsonDecode(frame as String) as Map<String, Object?>), onDone: _incoming.close);
  }

  final WebSocket _socket;
  final StreamController<Map<String, Object?>> _incoming = StreamController();
  late final StreamIterator<Map<String, Object?>> _reader = StreamIterator(_incoming.stream);

  @override
  final String? serverFingerprint;

  @override
  Future<Map<String, Object?>> receive() async {
    if (!await _reader.moveNext()) throw const PairingFailure(Pairing.noPairing);
    return _reader.current;
  }

  @override
  void send(Map<String, Object?> message) => _socket.add(jsonEncode(message));
}
