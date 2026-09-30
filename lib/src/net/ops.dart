import 'dart:convert';

import 'package:crypto/crypto.dart' show sha1;
import 'package:lyra_protocol/lyra_protocol.dart';

import '../engine.dart';
import '../failure.dart';
import '../identity/devices.dart';
import 'rpc.dart';

/// Every op this engine serves, with its gate (`protocol-v1.md` §9, `session.md`). An op of the
/// catalogue missing here answers `unknown_op`: its domain arrives in plan phase 4.
///
/// A new op goes into `protocol-v1.md`, `lyra_protocol` (`Ops`), this table with its gate, and a
/// test, in the same change (the app's CLAUDE.md, local ops rule).
final Map<String, OpRule> opRules = {
  Ops.hello.name: const OpRule(_hello, gate: Gate.anyone, whileLocked: true),
  Ops.engineUnlock.name: const OpRule(_unlock, gate: Gate.device, masterOnly: true, whileLocked: true),
  Ops.deviceProve.name: const OpRule(_prove, gate: Gate.anyone),
  Ops.sessionBind.name: const OpRule(_bind, gate: Gate.device),
  Ops.eventsSubscribe.name: const OpRule(_subscribe),
  Ops.eventsUnsubscribe.name: const OpRule(_unsubscribe),
  Ops.authIdentify.name: const OpRule(_identify, gate: Gate.device),
  Ops.authSignIn.name: const OpRule(_signIn, gate: Gate.device),
  Ops.authRefresh.name: const OpRule(_refresh, gate: Gate.device),
  Ops.authSignOut.name: const OpRule(_signOut),
  Ops.accountChangePassword.name: const OpRule(_changePassword),
  Ops.devicesList.name: const OpRule(_devices, permission: _devicesPermission),
  Ops.devicesRename.name: const OpRule(_renameDevice, permission: _devicesPermission),
  Ops.devicesRevoke.name: const OpRule(_revokeDevice, permission: _devicesPermission),
  Ops.pairingStart.name: const OpRule(_startPairing, permission: _devicesPermission, masterOnly: true),
  Ops.devicesBrowserCa.name: const OpRule(_browserCa),
};

/// `docs/app-areas.json`, area `local_server`.
const _devicesPermission = "local_server.devices";

/// `hello` (`protocol-v1.md` §4). A browser gets a challenge to sign (`device.prove`).
Future<Object?> _hello(OpCall call) async {
  final HelloArgs args;
  try {
    args = HelloArgs.fromJson(call.args);
  } on FormatException {
    throw const EngineFailure(ErrorCodes.badRequest);
  }

  final server = call.connection.server;

  if (args.protocol != protocolVersion) {
    throw const EngineFailure(ErrorCodes.versionMismatch, {"protocol": protocolVersion});
  }
  if (Version.tryParse(args.app)! < Version.tryParse(minAppVersion)!) {
    throw const EngineFailure(ErrorCodes.updateRequired, {"minApp": minAppVersion});
  }

  call.connection.helloDone();

  final connection = call.connection;
  if (connection.isBrowser && connection.device == null) connection.challenge = Hashes.random(32);

  return HelloAnswer(
    protocol: protocolVersion,
    engine: engineVersion,
    minApp: minAppVersion,
    instanceId: server.instanceId,
    state: server.engine == null ? EngineState.locked : EngineState.ready,
    challenge: connection.challenge,
  ).toJson();
}

/// `engine.unlock {passphrase}`: passphrase mode, from the master's own app only (plan §6.2).
Future<Object?> _unlock(OpCall call) async {
  final server = call.connection.server;

  if (server.engine == null) await server.unlock(call.text("passphrase", max: 1024));
  call.connection.identify();

  return {"state": EngineState.ready.name};
}

/// `device.prove {deviceId, signature}`: a browser signs the `hello` challenge with its
/// WebCrypto key (`protocol-v1.md` §3).
Future<Object?> _prove(OpCall call) async {
  final connection = call.connection;
  final challenge = connection.challenge;
  final device = call.engine.devices.byId(call.text("deviceId"));
  final signature = base64.decode(call.text("signature", max: 512));

  connection.challenge = null;

  if (challenge == null || !connection.isBrowser) throw const EngineFailure(ErrorCodes.badRequest);
  if (device == null || device.kind != DeviceKind.web ||
      !P256.verify(device.publicKey, DeviceProof.message(call.engine.instanceId, challenge), signature)) {
    throw const EngineFailure(ErrorCodes.forbidden);
  }
  if (device.isRevoked) throw const EngineFailure(ErrorCodes.deviceRevoked);

  connection.device = device;

  return {"deviceId": device.id, "code": device.code};
}

/// `session.bind {accessToken}` (`protocol-v1.md` §4): only on the device the session belongs
/// to (S-20).
Future<Object?> _bind(OpCall call) async {
  final token = call.text("accessToken");
  final grant = call.engine.sessions.access(token);

  if (grant == null) throw const EngineFailure(ErrorCodes.sessionExpired);
  if (grant.deviceId != call.device.id) throw const EngineFailure(ErrorCodes.sessionRevoked);

  final account = call.engine.accounts.byId(grant.accountId);
  if (account == null) throw const EngineFailure(ErrorCodes.sessionRevoked);

  call.connection.bind(token, grant, account.grants);
  call.engine.devices.touch(call.device.id, account: account.id);

  return {"accountId": account.id, "expires": grant.expires.toIso8601String()};
}

Future<Object?> _subscribe(OpCall call) async {
  final since = call.args["since"];
  if (since != null && (since is! int || since < 0)) throw const EngineFailure(ErrorCodes.invalidField, {"field": "since"});

  return {"head": call.connection.subscribe(since as int?)};
}

Future<Object?> _unsubscribe(OpCall call) async {
  call.connection.unsubscribe();

  return const {};
}

/// `auth.identify {login}`: answers `password` for an unknown login too (`session.md`).
Future<Object?> _identify(OpCall call) async =>
  {"method": call.engine.accounts.usesPassword(call.text("login")) ? "password" : "activation"};

/// `auth.signIn {login, password}` (S-4): 20 attempts a minute per device, then the account
/// rules.
Future<Object?> _signIn(OpCall call) async {
  final server = call.connection.server;
  final device = call.device;

  if (!server.allowSignIn(device.id)) throw const EngineFailure(ErrorCodes.rateLimited, {"retryAfter": 60});

  final account = await call.engine.accounts.verifyPassword(
    call.text("login"),
    call.text("password", max: 1024),
    device: device.id,
  );
  final tokens = call.engine.sessions.open(accountId: account.id, deviceId: device.id);

  return {...tokens.toJson(), "accountId": account.id, "mustChangePassword": account.mustChangePassword};
}

/// `auth.refresh {refreshToken}` (S-21).
Future<Object?> _refresh(OpCall call) async =>
  call.engine.sessions.refresh(call.text("refreshToken"), deviceId: call.device.id).toJson();

Future<Object?> _signOut(OpCall call) async {
  call.engine.sessions.end(call.session.sessionId);
  call.connection.unbind();

  return const {};
}

/// `account.changePassword {current, password}` (S-9): every other session of the account ends.
Future<Object?> _changePassword(OpCall call) async {
  final accountId = call.session.accountId;
  final hash = await call.engine.accounts.newPasswordHash(
    accountId,
    current: call.text("current", max: 1024),
    password: call.text("password", max: 1024),
    device: call.device.id,
  );
  final answer = call.write(() {
    call.engine.accounts.setPassword(accountId, hash, device: call.device.id);
    return const <String, Object?>{};
  });

  final ended = call.engine.sessions.endForAccount(accountId, except: call.session.sessionId, reason: "password_changed");
  call.connection.server.revokeSessions(ended);

  return answer;
}

Future<Object?> _devices(OpCall call) async {
  final server = call.connection.server;

  return [for (final device in call.engine.devices.list()) device.toJson(online: server.isOnline(device.id))];
}

Future<Object?> _renameDevice(OpCall call) async => call.write(() => call.engine.devices
  .rename(call.text("id"), call.text("name"), actor: call.session.accountId, device: call.device.id)
  .toJson(online: call.connection.server.isOnline(call.text("id"))));

/// `devices.revoke {id}` (S-41): its sessions end, its connections close, its certificate is
/// refused from now on.
Future<Object?> _revokeDevice(OpCall call) async {
  final id = call.text("id");
  final answer = call.write(() => call.engine.devices
    .revoke(id, actor: call.session.accountId, device: call.device.id)
    .toJson());

  call.engine.sessions.forgetDevice(id);
  await call.connection.server.dropDevice(id);

  return answer;
}

/// `pairing.start` (S-40): a new code and QR, on the master's own device only.
Future<Object?> _startPairing(OpCall call) async {
  final server = call.connection.server;

  return server.pairing!.open(openedBy: call.session.accountId, transport: server.transport, port: server.port);
}

/// `devices.browserCa`: the name-constrained root, for a signed-in native device to install in
/// its computer's trust store or export for another one (plan §5.3). The pinned channel it comes
/// on already verified it. Installed by hand on another computer, the person compares what the
/// OS shows: Windows shows the SHA-1 `thumbprint`, other systems the SHA-256 `fingerprint`.
/// `addresses` and `port` are where a browser then opens the web build.
Future<Object?> _browserCa(OpCall call) async {
  final root = call.engine.authority.browser;
  final server = call.connection.server;

  return {
    "addresses": server.transport.addresses.where((address) => address != "127.0.0.1" && address != "::1").toList(),
    "port": server.port,
    "certificate": base64.encode(root.der),
    "fingerprint": root.fingerprint,
    "thumbprint": sha1.convert(root.der).toString(),
  };
}
