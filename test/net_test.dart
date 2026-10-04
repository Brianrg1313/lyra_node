import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/io.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:test/test.dart';

import 'net_support.dart';
import 'support.dart';

/// The LAN server with real TLS clients on loopback (plan §5, `protocol-v1.md`). The exit
/// criteria of phase 3 that a single computer can check: pairing by QR and by code, mutual TLS
/// pinned to the installation CA, a man in the middle that can neither read nor pair, and
/// revocation.
void main() {
  group('handshake', () {
    test('the master app connects with its certificate and signs in', () async {
      final master = await TestMaster.start();
      final (client, tokens) = await master.signIn();

      expect(tokens["mustChangePassword"], isFalse);

      final devices = await client.call(Ops.devicesList) as List;
      expect(devices.single, containsPair("kind", "master"));
      expect(devices.single, containsPair("online", true));
    });

    test('the first frame must be hello; a foreign protocol closes the connection', () async {
      final master = await TestMaster.start();
      final client = await connectRpc("127.0.0.1", master.port, master.master);
      addTearDown(client.close);

      await expectRefusal(client.call(Ops.authIdentify, args: {"login": "x"}), ErrorCodes.badRequest);
      await expectRefusal(
        client.call(Ops.hello, args: const HelloArgs(protocol: 2, app: app, platform: "windows").toJson()),
        ErrorCodes.versionMismatch,
      );
      await client.done.timeout(const Duration(seconds: 5));
    });

    test('an app older than minApp is told to update', () async {
      final master = await TestMaster.start();
      final client = await connectRpc("127.0.0.1", master.port, master.master);
      addTearDown(client.close);

      await expectLater(
        client.hello(app: "0.0.1", platform: "windows"),
        throwsA(isA<RpcError>().having((e) => e.action, "action", ErrorActions.update)),
      );
    });

    test('an op without a session, an unknown op and a write without commandId are refused', () async {
      final master = await TestMaster.start();
      final client = await master.connect();

      await expectRefusal(client.call(Ops.devicesList), ErrorCodes.sessionExpired);
      await expectRefusal(client.call(Ops.posSnapshot), ErrorCodes.unknownOp);

      // The client library refuses to send it; a hand-written frame reaches the master.
      final (signedIn, _) = await master.signIn();
      expect(() => signedIn.call(Ops.devicesRename, args: {"id": "x", "name": "y"}), throwsArgumentError);

      final raw = await WebSocket.connect(
        "wss://127.0.0.1:${master.port}/rpc",
        customClient: HttpClient(context: master.master.context),
      );
      addTearDown(raw.close);
      final answers = StreamIterator(raw);

      raw.add(const RpcRequest(id: 1, op: "hello", args: {"protocol": 1, "app": app, "platform": "windows"}).encode());
      await answers.moveNext();
      raw.add(const RpcRequest(id: 2, op: "auth.identify", args: {"login": "x"}, commandId: "0192").encode());
      await answers.moveNext();

      final refused = Frame.decode(answers.current as String) as RpcResponse;
      expect(refused.error?.code, ErrorCodes.badRequest);
    });

    test('TLS 1.2 and plaintext are refused', () async {
      final master = await TestMaster.start();
      final context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(Pem.encode("CERTIFICATE", master.master.caCertificate)))
        ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2;

      // A TLS 1.3 server simply has no 1.2 to offer: a 1.2-only peer can't finish; plain HTTP
      // gets no answer at all.
      final plain = await Socket.connect("127.0.0.1", master.port);
      plain.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n");
      final answer = await plain.timeout(const Duration(seconds: 5), onTimeout: (sink) => sink.close()).toList();
      expect(utf8.decode(answer.expand((chunk) => chunk).toList(), allowMalformed: true), isNot(contains("HTTP/1.1 200")));
      plain.destroy();

      final secure = await SecureSocket.connect("127.0.0.1", master.port, context: context);
      expect(secure.selectedProtocol, isNull);
      secure.destroy();
    });
  });

  group('pairing', () {
    test('with the code: the device gets a certificate and connects with mutual TLS', () async {
      final master = await TestMaster.start();
      final offer = await master.openPairing();
      final phone = await master.pairNative("Counter", code: offer["code"] as String);

      expect(Fingerprint.of(phone.caCertificate), Fingerprint.of(master.master.caCertificate));

      final (client, _) = await master.signIn(phone);
      final devices = await client.call(Ops.devicesList) as List;

      expect(devices.map((d) => (d as Map)["name"]), containsAll(["Server", "Counter"]));
      expect(devices.firstWhere((d) => (d as Map)["name"] == "Counter"), containsPair("code", "B"));
    });

    test('with the QR: the token is the secret and the CA fingerprint is checked', () async {
      final master = await TestMaster.start();
      final offer = PairingOffer.parse((await master.openPairing())["qr"] as String);

      expect(offer.caFingerprint, Fingerprint.of(master.master.caCertificate));

      final laptop = await master.pairNative("Laptop", offer: offer);
      await master.signIn(laptop);
    });

    test('a code pairs one device only', () async {
      final master = await TestMaster.start();
      final code = (await master.openPairing())["code"] as String;

      await master.pairNative("First", code: code);
      await expectLater(
        master.pairNative("Second", code: code),
        throwsA(isA<PairingFailure>().having((f) => f.code, "code", Pairing.noPairing)),
      );
    });

    test('three wrong codes void it, even the right one afterwards (S-40)', () async {
      final master = await TestMaster.start();
      final code = (await master.openPairing())["code"] as String;
      final wrong = code == "00000000" ? "11111111" : "00000000";

      for (var i = 0; i < Pairing.maxAttempts; i++) {
        await expectLater(
          master.pairNative("Guess $i", code: wrong),
          throwsA(isA<PairingFailure>().having((f) => f.code, "code", Pairing.failed)),
        );
      }

      await expectLater(
        master.pairNative("Late", code: code),
        throwsA(isA<PairingFailure>().having((f) => f.code, "code", Pairing.noPairing)),
      );
      expect(master.openEngine.audit.list().where((e) => e.kind == AuditKinds.pairingFailed), hasLength(3));
    });

    test('with the password: no code, the account pairs its own device and signs in', () async {
      final master = await TestMaster.start();
      final laptop = await master.pairNative(
        "Laptop",
        password: PasswordPairing(login: owner.username, password: owner.password),
      );

      final (client, _) = await master.signIn(laptop);
      final devices = await client.call(Ops.devicesList) as List;
      final paired = devices.firstWhere((d) => (d as Map)["name"] == "Laptop") as Map;

      expect(paired["pairedBy"], isNotNull);
    });

    test('a wrong password fails like a wrong code and counts towards the lockout (S-4)', () async {
      final master = await TestMaster.start();
      final wrong = PasswordPairing(login: owner.username, password: "not the password");

      for (var i = 0; i < Accounts.maxFailures; i++) {
        await expectLater(
          master.pairNative("Guess $i", password: wrong),
          throwsA(isA<PairingFailure>().having((f) => f.code, "code", Pairing.failed)),
        );
      }

      await expectLater(
        master.pairNative("Late", password: PasswordPairing(login: owner.username, password: owner.password)),
        throwsA(isA<PairingFailure>().having((f) => f.code, "code", Pairing.accountLocked)),
      );
      expect(master.openEngine.audit.list().where((e) => e.kind == AuditKinds.accountLocked), hasLength(1));
    });

    test('an unknown login gets a steady decoy salt and fails like a wrong password', () async {
      final master = await TestMaster.start();

      Future<Map<String, Object?>> saltOf(String login) async {
        final channel = await connectPairing("127.0.0.1", master.port);
        addTearDown(channel.close);
        await channel.receive();
        channel.send({"step": "account", "login": login});
        return channel.receive();
      }

      final known = await saltOf(owner.username);
      final unknown = await saltOf("nobody");

      expect(unknown.keys, unorderedEquals(known.keys));
      expect(unknown["step"], "salt");
      expect((await saltOf("NOBODY"))["salt"], unknown["salt"]);
      expect(unknown["salt"], isNot(known["salt"]));

      await expectLater(
        master.pairNative("Ghost", password: const PasswordPairing(login: "nobody", password: "anything at all")),
        throwsA(isA<PairingFailure>().having((f) => f.code, "code", Pairing.failed)),
      );
    });

    test('only the master app opens a pairing', () async {
      final master = await TestMaster.start();
      final phone = await master.pairNative("Phone", code: (await master.openPairing())["code"] as String);
      final (client, _) = await master.signIn(phone);

      await expectRefusal(client.call(Ops.pairingStart), "not_master");
    });
  });

  group('a man in the middle', () {
    test('without the CA, TLS itself fails: a pinned client never talks to it', () async {
      final master = await TestMaster.start();
      final impostor = await TestMaster.start();

      // Same address the client expects, another master's certificate.
      await expectLater(
        connectRpc("127.0.0.1", impostor.port, master.master),
        throwsA(isA<HandshakeException>()),
      );
    });

    test('relaying the pairing through its own TLS is caught, even with the right code', () async {
      final master = await TestMaster.start();
      final code = (await master.openPairing())["code"] as String;
      final proxy = await _PairingProxy.start(master.port);
      addTearDown(proxy.close);

      await expectLater(
        _pairThrough(proxy.port, code),
        throwsA(isA<PairingFailure>().having((f) => f.code, "code", PairingFailure.wrongMaster)),
      );
    });

    test('answering the pairing itself fails: it does not know the code', () async {
      final master = await TestMaster.start();
      final impostor = await TestMaster.start();
      final realCode = (await master.openPairing())["code"] as String;
      await impostor.openPairing();

      // The impostor has a pairing of its own open, but not this code.
      await expectLater(
        _pairThrough(impostor.port, realCode),
        throwsA(isA<PairingFailure>().having((f) => f.code, "code", Pairing.failed)),
      );
    });

    test('a QR pointing at another master is refused before any secret is used', () async {
      final master = await TestMaster.start();
      final impostor = await TestMaster.start();
      final offer = PairingOffer.parse((await master.openPairing())["qr"] as String);

      final channel = await connectPairing("127.0.0.1", impostor.port);
      addTearDown(channel.close);

      await expectLater(
        pairDevice(
          channel,
          device: deviceNamed("Phone"),
          signer: LocalDeviceSigner(EcKeyPair.generate()),
          offer: offer,
        ),
        throwsA(isA<PairingFailure>().having((f) => f.code, "code", PairingFailure.wrongMaster)),
      );
    });
  });

  group('revocation', () {
    test('a revoked device is disconnected at once and refused afterwards (S-41)', () async {
      final master = await TestMaster.start();
      final phone = await master.pairNative("Phone", code: (await master.openPairing())["code"] as String);
      final (phoneClient, phoneTokens) = await master.signIn(phone);
      final (admin, _) = await master.signIn();

      final devices = await admin.call(Ops.devicesList) as List;
      final phoneId = (devices.firstWhere((d) => (d as Map)["name"] == "Phone") as Map)["id"];

      final revoked = await admin.call(Ops.devicesRevoke, args: {"id": phoneId}, commandId: newId()) as Map;
      expect(revoked["revoked"], isNotNull);

      await phoneClient.done.timeout(const Duration(seconds: 5));
      await expectLater(connectRpc("127.0.0.1", master.port, phone), throwsA(isA<WebSocketException>()));

      // Its session is gone too: the refresh token opens nothing.
      await expectLater(
        () => master.openEngine.sessions.refresh(phoneTokens["refreshToken"] as String, deviceId: phoneId as String),
        throwsA(isA<EngineFailure>()),
      );
    });

    test('the master app can not be revoked', () async {
      final master = await TestMaster.start();
      final (admin, _) = await master.signIn();
      final devices = await admin.call(Ops.devicesList) as List;

      await expectRefusal(
        admin.call(Ops.devicesRevoke, args: {"id": (devices.single as Map)["id"]}, commandId: newId()),
        "self",
      );
    });
  });

  group('sessions', () {
    test('a refresh token rotates, and a spent one coming back ends the session (S-21)', () async {
      final master = await TestMaster.start();
      final (client, first) = await master.signIn();

      final second = await client.call(Ops.authRefresh, args: {"refreshToken": first["refreshToken"]}) as Map;
      expect(second["refreshToken"], isNot(first["refreshToken"]));

      await expectRefusal(client.call(Ops.authRefresh, args: {"refreshToken": first["refreshToken"]}), ErrorCodes.sessionRevoked);
      await expectRefusal(
        (await master.connect()).call(Ops.authRefresh, args: {"refreshToken": second["refreshToken"]}),
        ErrorCodes.sessionExpired,
      );
    });

    test('a token only binds on the device it was issued to (S-20)', () async {
      final master = await TestMaster.start();
      final phone = await master.pairNative("Phone", code: (await master.openPairing())["code"] as String);
      final (_, tokens) = await master.signIn();
      final other = await master.connect(phone);

      await expectRefusal(other.call(Ops.sessionBind, args: {"accessToken": tokens["accessToken"]}), ErrorCodes.sessionRevoked);
    });

    test('a wrong password is invalid_credentials, the same as an unknown user', () async {
      final master = await TestMaster.start();
      final client = await master.connect();

      await expectRefusal(client.call(Ops.authSignIn, args: {"login": owner.username, "password": "wrong password"}), "invalid_credentials");
      await expectRefusal(client.call(Ops.authSignIn, args: {"login": "nobody", "password": "wrong password"}), "invalid_credentials");
      expect(await client.call(Ops.authIdentify, args: {"login": "nobody"}), {"method": "password"});
    });

    test('changing the password ends the other sessions (S-9)', () async {
      final master = await TestMaster.start();
      final (other, _) = await master.signIn();
      final (client, _) = await master.signIn();

      await client.call(Ops.accountChangePassword, args: {"current": owner.password, "password": "a brand new password"}, commandId: newId());

      await expectRefusal(other.call(Ops.devicesList), ErrorCodes.sessionRevoked);
      expect(await client.call(Ops.devicesList), isNotEmpty);
    });

    test('a commandId sent twice runs once and answers the same', () async {
      final master = await TestMaster.start();
      final (client, _) = await master.signIn();
      final id = ((await client.call(Ops.devicesList) as List).single as Map)["id"];
      final command = newId();

      final first = await client.call(Ops.devicesRename, args: {"id": id, "name": "Front desk"}, commandId: command);
      final again = await client.call(Ops.devicesRename, args: {"id": id, "name": "Front desk"}, commandId: command);

      expect(again, first);
      await expectRefusal(client.call(Ops.devicesRename, args: {"id": id, "name": "Other"}, commandId: command), ErrorCodes.commandReused);
    });
  });

  group('passphrase mode', () {
    test('locked: only hello and engine.unlock from the master app, then everything', () async {
      final master = await TestMaster.start(passphrase: "a long passphrase");
      final client = await connectRpc("127.0.0.1", master.port, master.master);
      addTearDown(client.close);

      expect((await client.hello(app: app, platform: "windows")).state, EngineState.locked);
      await expectRefusal(client.call(Ops.authSignIn, args: {"login": owner.username, "password": owner.password}), ErrorCodes.locked);
      await expectRefusal(client.call(Ops.engineUnlock, args: {"passphrase": "wrong"}), "wrong_passphrase");

      expect(await client.call(Ops.engineUnlock, args: {"passphrase": "a long passphrase"}), {"state": "ready"});
      await client.call(Ops.authSignIn, args: {"login": owner.username, "password": owner.password});
    });
  });

  group('browsers', () {
    test('a web device pairs without a certificate and proves itself on every connection', () async {
      final master = await TestMaster.start();
      final code = (await master.openPairing())["code"] as String;
      final key = EcKeyPair.generate();

      // The browser runs the code flow in the page; TLS is checked by the browser itself.
      final result = await pairDevice(
        await connectPairing("127.0.0.1", master.port),
        device: deviceNamed("Browser", platform: "web"),
        signer: LocalDeviceSigner(key),
        code: code,
      );
      expect(result.certificate, isNull);

      final browser = await connectAsBrowser(master.port, result.caCertificate);
      final hello = await browser.call(Ops.hello, args: const HelloArgs(protocol: 1, app: app, platform: "web").toJson()) as Map;

      await expectRefusal(browser.call(Ops.authSignIn, args: {"login": owner.username, "password": owner.password}), ErrorCodes.forbidden);

      final challenge = base64.decode(hello["challenge"] as String);
      await browser.call(Ops.deviceProve, args: {
        "deviceId": result.deviceId,
        "signature": base64.encode(key.sign(DeviceProof.message(result.instanceId, challenge))),
      });
      await browser.call(Ops.authSignIn, args: {"login": owner.username, "password": owner.password});
    });

    test('a signature by another key proves nothing', () async {
      final master = await TestMaster.start();
      final code = (await master.openPairing())["code"] as String;
      final result = await pairDevice(
        await connectPairing("127.0.0.1", master.port),
        device: deviceNamed("Browser", platform: "web"),
        signer: LocalDeviceSigner(EcKeyPair.generate()),
        code: code,
      );
      final browser = await connectAsBrowser(master.port, result.caCertificate);
      final hello = await browser.call(Ops.hello, args: const HelloArgs(protocol: 1, app: app, platform: "web").toJson()) as Map;
      final challenge = base64.decode(hello["challenge"] as String);

      await expectRefusal(browser.call(Ops.deviceProve, args: {
        "deviceId": result.deviceId,
        "signature": base64.encode(EcKeyPair.generate().sign(DeviceProof.message(result.instanceId, challenge))),
      }), ErrorCodes.forbidden);
    });

    test('a page of another site is not let in, to /rpc or /pair', () async {
      final master = await TestMaster.start();
      final ca = master.openEngine.authority.pinned.der;

      await expectLater(
        connectAsBrowser(master.port, ca, origin: "https://evil.example"),
        throwsA(isA<WebSocketException>().having((error) => error.httpStatusCode, "status", HttpStatus.forbidden)),
      );
      await expectLater(
        connectAsBrowser(master.port, ca, origin: "https://127.0.0.1:${master.port + 1}"),
        throwsA(isA<WebSocketException>()),
      );

      final context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(Pem.encode("CERTIFICATE", ca)));
      await expectLater(
        WebSocket.connect(
          "wss://127.0.0.1:${master.port}/pair",
          headers: {"origin": "https://evil.example"},
          customClient: HttpClient(context: context),
        ),
        throwsA(isA<WebSocketException>()),
      );
    });

    test('the page it serves says it is a master: one web build for the cloud and the LAN', () async {
      final web = Directory.systemTemp.createTempSync("lyra_web");
      addTearDown(() => web.deleteSync(recursive: true));
      File("${web.path}/index.html").writeAsStringSync("<!DOCTYPE html><html><head><title>Lyra</title></head></html>");
      File("${web.path}/main.dart.js").writeAsStringSync("// <head>");

      final master = await TestMaster.start(webRoot: web.path);
      final context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(Pem.encode("CERTIFICATE", master.openEngine.authority.pinned.der)));
      final client = HttpClient(context: context);
      addTearDown(() => client.close(force: true));

      Future<String> get(String path) async {
        final response = await (await client.getUrl(Uri.parse("https://127.0.0.1:${master.port}$path"))).close();

        return utf8.decode(await response.expand((chunk) => chunk).toList());
      }

      expect(await get("/"), "<!DOCTYPE html><html><head>${WebBundle.marker}<title>Lyra</title></head></html>");
      expect(await get("/home/finance"), contains(WebBundle.marker));
      expect(await get("/main.dart.js"), "// <head>");
    });

    test("a certificate with the master's name is served from the next handshake, without a restart", () async {
      final master = await TestMaster.start();
      final engine = master.openEngine;
      final (client, _) = await master.signIn();
      expect((await client.call(Ops.devicesBrowserCa) as Map)["host"], isNull);

      master.server.transport = await engine.prepareTransport(Uint8List.fromList(master.controlKey), host: "lovelace-cafe.local");

      final context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(engine.authority.pinned.pem));
      final socket = await SecureSocket.connect("127.0.0.1", master.port, context: context);
      final served = socket.peerCertificate!.der;
      await socket.close();

      expect(latin1.decode(served), contains("lovelace-cafe.local"));
      expect((await client.call(Ops.devicesBrowserCa) as Map)["host"], "lovelace-cafe.local");
      // Kept in the transport file, so a locked start still announces it; a start that names no
      // host keeps it.
      expect((await Transport.read(master.paths.transport, master.controlKey))!.host, "lovelace-cafe.local");
      expect((await engine.prepareTransport(Uint8List.fromList(master.controlKey))).host, "lovelace-cafe.local");
    });

    test('a signed-in device gets the browser root: same key, name-constrained', () async {
      final master = await TestMaster.start();
      final (client, _) = await master.signIn();
      final answer = await client.call(Ops.devicesBrowserCa) as Map;
      final der = base64.decode(answer["certificate"] as String);

      expect(answer["fingerprint"], Fingerprint.of(der));
      expect(answer["thumbprint"], hasLength(40));
      expect(answer["port"], master.port);
      expect(answer["addresses"], isNot(contains("127.0.0.1")));
      expect(der, master.openEngine.authority.browser.der);
      expect(der, isNot(master.openEngine.authority.pinned.der));
    });
  });

  group('events', () {
    test('a subscriber gets the replay after since, then live events, filtered per session', () async {
      final master = await TestMaster.start();
      final (client, tokens) = await master.signIn();
      final engine = master.openEngine;
      final ownerId = tokens["accountId"] as String;

      void emit(String name, {List<String>? accounts, String? permission}) {
        engine.store.write((db) => EventLog.append(db, name, {"n": name}, at: engine.now(), accounts: accounts, permission: permission));
        engine.events.publish();
      }

      emit("a");
      final received = <String>[];
      final subscription = client.events.listen((event) => received.add(event.event));
      addTearDown(subscription.cancel);

      final head = (await client.call(Ops.eventsSubscribe, args: {"since": 0}) as Map)["head"] as int;
      expect(head, 1);

      emit("b");
      emit("not-yours", accounts: ["someone-else"]);
      emit("c", accounts: [ownerId], permission: "server.devices");

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(received, ["a", "b", "c"]);
    });

    test('a since older than what is kept answers resync_required', () async {
      final master = await TestMaster.start();
      final (client, _) = await master.signIn();
      final engine = master.openEngine;

      engine.store.write((db) {
        for (var i = 0; i < 3; i++) {
          EventLog.append(db, "e", null, at: DateTime.utc(2020), accounts: null);
        }
      });
      engine.events.publish();
      engine.events.prune();

      await expectRefusal(client.call(Ops.eventsSubscribe, args: {"since": 1}), ErrorCodes.resyncRequired);
    });
  });

  group('files', () {
    Future<HttpClientResponse> request(TestMaster master, String method, String path, String token,
        {List<int>? body, String? purpose}) async {
      final client = HttpClient(context: master.master.context);
      addTearDown(() => client.close(force: true));
      final request = await client.openUrl(method, Uri.parse("https://127.0.0.1:${master.port}$path"));

      request.headers.set(HttpHeaders.authorizationHeader, "Bearer $token");
      if (purpose != null) request.headers.set("X-Lyra-Purpose", purpose);
      if (body != null) request.add(body);

      return request.close();
    }

    test('an upload is checked by its bytes, stored encrypted and read back by its owner', () async {
      final master = await TestMaster.start();
      final (_, tokens) = await master.signIn();
      final token = tokens["accessToken"] as String;
      final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4]);

      final put = await request(master, "PUT", "/f", token, body: png, purpose: "logo");
      final fileId = (jsonDecode(await utf8.decodeStream(put)) as Map)["fileId"] as String;
      expect(put.statusCode, 200);
      expect(put.headers.value("strict-transport-security"), isNotNull);

      // On disk it's sealed: the PNG signature isn't there.
      final stored = File("${master.paths.files}/$fileId").readAsBytesSync();
      expect(stored.sublist(0, 8), isNot(png.sublist(0, 8)));

      final get = await request(master, "GET", "/f/$fileId", token);
      expect(await get.fold<List<int>>([], (all, chunk) => all..addAll(chunk)), png);
      expect(get.headers.contentType?.mimeType, "image/png");

      final fake = await request(master, "PUT", "/f", token, body: utf8.encode("<script>"), purpose: "logo");
      expect(fake.statusCode, 400);
      await fake.drain<void>();

      final anonymous = await request(master, "GET", "/f/$fileId", "nope");
      expect(anonymous.statusCode, 401);
      await anonymous.drain<void>();
    });
  });
}

Future<PairingResult> _pairThrough(int port, String code) async {
  final channel = await connectPairing("127.0.0.1", port);
  addTearDown(channel.close);

  return pairDevice(channel, device: deviceNamed("Victim"), signer: LocalDeviceSigner(EcKeyPair.generate()), code: code);
}

/// Terminates TLS with its own certificate and relays `/pair` frames to the real master: the
/// attacker who sits on the LAN and hopes the device won't notice.
final class _PairingProxy {
  _PairingProxy._(this._server);

  static Future<_PairingProxy> start(int target) async {
    final key = EcKeyPair.generate();
    final leaf = X509.server(
      key: key,
      caKey: key,
      instanceId: "evil0000-0000",
      addresses: [InternetAddress.loopbackIPv4],
      hostnames: const [],
    );
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(leaf.pem))
      ..usePrivateKeyBytes(utf8.encode(key.privateKeyPem));
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);

    server.listen((request) async {
      final victim = await WebSocketTransformer.upgrade(request);
      final upstream = await WebSocket.connect(
        "wss://127.0.0.1:$target/pair",
        customClient: HttpClient(context: SecurityContext(withTrustedRoots: false))..badCertificateCallback = (_, _, _) => true,
      );

      victim.listen(upstream.add, onDone: upstream.close);
      upstream.listen(victim.add, onDone: victim.close);
    });

    return _PairingProxy._(server);
  }

  final HttpServer _server;

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);
}
