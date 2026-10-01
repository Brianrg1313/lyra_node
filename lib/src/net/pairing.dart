import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:lyra_protocol/lyra_protocol.dart';

import '../audit/audit_log.dart';
import '../engine.dart';
import '../identity/devices.dart';
import '../ids.dart';
import '../crypto/secrets.dart';
import 'tls.dart';

/// The pairing that is open right now: one code and one QR token, both for the same device
/// (`session.md` S-40).
final class PairingTicket {
  PairingTicket._({required this.code, required this.token, required this.expires, required this.openedBy});

  final String code;
  final String token;
  final DateTime expires;

  /// The account that asked for it; it appears as `pairedBy` on the device.
  final String openedBy;

  int _failures = 0;
  bool _used = false;
}

/// The master's side of pairing (`protocol-v1.md` §3, plan §5.3).
///
/// [open] makes the live ticket (a new one replaces the old); [serve] runs one `/pair`
/// connection. A ticket pairs one device; three failed exchanges void it (S-40).
///
/// The password way needs no ticket: a person with an active account pairs a new device with
/// their own login and password (the owner's call, 2026-10-01), and a wrong one counts towards
/// that account's lockout like a wrong sign in.
final class PairingDesk {
  PairingDesk(this._engine);

  final Engine _engine;
  PairingTicket? _live;

  /// How long each step may take before the connection is dropped.
  static const stepTimeout = Duration(seconds: 30);

  /// Opens a pairing for [openedBy]. Answers what `pairing.start` shows: the QR text, the code
  /// and when both expire.
  Map<String, Object?> open({required String openedBy, required Transport transport, required int port}) {
    final ticket = PairingTicket._(
      code: Pairing.newCode(),
      token: Pairing.newToken(),
      expires: _engine.now().toUtc().add(Pairing.lifetime),
      openedBy: openedBy,
    );
    _live = ticket;

    final offer = PairingOffer(
      instanceId: _engine.instanceId,
      addresses: transport.addresses.where((address) => address != "127.0.0.1" && address != "::1").toList(),
      port: port,
      caFingerprint: transport.ca.fingerprint,
      token: ticket.token,
    );

    return {"qr": offer.encode(), "code": ticket.code, "expires": ticket.expires.toIso8601String()};
  }

  /// Closes the live pairing, if any.
  void close() => _live = null;

  /// Runs `/pair` on one connection: [receive] and [send] carry its JSON frames.
  Future<void> serve({
    required Future<Map<String, Object?>> Function() receive,
    required void Function(Map<String, Object?>) send,
    required Transport transport,
  }) async {
    void fail(String code) => send({"step": "failed", "code": code});

    send({"step": "hello", "instanceId": _engine.instanceId, "protocol": protocolVersion});

    final start = await receive().timeout(stepTimeout);
    if (start["step"] == "account") return _byPassword(start, receive: receive, send: send, transport: transport);

    final ticket = _live;

    if (ticket == null || ticket._used) return fail(Pairing.noPairing);
    if (!ticket.expires.isAfter(_engine.now())) {
      _live = null;
      return fail(Pairing.expired);
    }

    final secret = switch (start["secret"]) {
      "code" => ticket.code,
      "token" => ticket.token,
      _ => null,
    };
    final pA = start["pA"];

    if (start["step"] != "start" || secret == null || pA is! String) return fail(Pairing.badRequest);

    await _exchange(
      secret: secret,
      pA: pA,
      receive: receive,
      send: send,
      transport: transport,
      failed: (reason) => _failed(ticket, reason),
      // Checked and consumed before the first await of the enrolment, so a second exchange with
      // the same ticket can't pair a second device.
      claim: () {
        if (ticket._used || !identical(_live, ticket)) return false;
        ticket._used = true;
        _live = null;
        return true;
      },
      pairedBy: ticket.openedBy,
    );
  }

  /// `account → salt → start`: the secret is the account's password digest. A login that can't
  /// sign in runs the exchange against a secret nobody holds, so it fails like a wrong password.
  Future<void> _byPassword(
    Map<String, Object?> first, {
    required Future<Map<String, Object?>> Function() receive,
    required void Function(Map<String, Object?>) send,
    required Transport transport,
  }) async {
    void fail(String code) => send({"step": "failed", "code": code});

    final login = first["login"];
    if (login is! String || login.trim().isEmpty || login.length > 254) return fail(Pairing.badRequest);

    final account = _engine.accounts.pairingAccount(login, await _engine.pairingDecoyKey);
    if (account.lockedUntil != null) return fail(Pairing.accountLocked);

    send({"step": "salt", ...account.salt.toJson()});

    final start = await receive().timeout(stepTimeout);
    final pA = start["pA"];

    if (start["step"] != "start" || start["secret"] != PairingSecret.password.name || pA is! String) {
      return fail(Pairing.badRequest);
    }

    await _exchange(
      secret: account.secret ?? base64.encode(randomBytes(32)),
      pA: pA,
      receive: receive,
      send: send,
      transport: transport,
      failed: (reason) {
        if (account.id != null && reason == "wrong_secret") _engine.accounts.pairingFailed(account.id!);
        _audit({"reason": reason, "secret": PairingSecret.password.name});
      },
      claim: () => account.id != null,
      pairedBy: account.id ?? "",
    );
  }

  /// SPAKE2 on [secret] and the enrolment, the same for every way. [claim] runs once the device
  /// proved the secret, right before it is enrolled; false stops it (`pairing_closed`).
  Future<void> _exchange({
    required String secret,
    required String pA,
    required Future<Map<String, Object?>> Function() receive,
    required void Function(Map<String, Object?>) send,
    required Transport transport,
    required void Function(String reason) failed,
    required bool Function() claim,
    required String pairedBy,
  }) async {
    void fail(String code) => send({"step": "failed", "code": code});

    final spake = Spake2.b(
      Spake2.passwordScalar(secret, instanceId: _engine.instanceId),
      idA: Pairing.idDevice,
      idB: _engine.instanceId,
      aad: Pairing.aad,
    );

    final Spake2Keys keys;
    try {
      keys = spake.finish(base64.decode(pA));
    } on FormatException {
      failed("bad_point");
      return fail(Pairing.failed);
    }

    send({"step": "reply", "pB": base64.encode(spake.message)});

    final enroll = await receive().timeout(stepTimeout);
    final confirm = enroll["confirm"];

    // One guess per exchange: a wrong confirmation is a wrong secret (or a tampered exchange).
    if (enroll["step"] != "enroll" || confirm is! String || !keys.checkPeer(_decode(confirm))) {
      failed("wrong_secret");
      return fail(Pairing.failed);
    }

    final macKey = keys.derive(Pairing.macPurpose);
    final body = Pairing.open(enroll, macKey);
    final device = PairingDevice.tryParse(body?["device"]);
    final publicKey = _decode(body?["publicKey"]);
    final proof = _decode(body?["proof"]);

    if (body == null || device == null || !P256.verify(publicKey, Pairing.proofMessage(keys.confirmA), proof)) {
      failed("bad_enrolment");
      return fail(Pairing.failed);
    }

    if (!claim()) return fail(Pairing.noPairing);

    final id = newId();
    final certificate = device.isWeb ? null : _engine.authority.issueDevice(publicKey, id, now: _engine.now());
    final enrolled = _engine.devices.enroll(
      id: id,
      name: device.name,
      platform: device.platform,
      appVersion: device.appVersion,
      kind: device.isWeb ? DeviceKind.web : DeviceKind.native,
      publicKey: publicKey,
      certFingerprint: certificate?.fingerprint,
      pairedBy: pairedBy,
    );

    send(Pairing.seal({
      "step": "paired",
      "confirm": base64.encode(keys.confirmation),
      "instanceId": _engine.instanceId,
      "caCertificate": base64.encode(transport.ca.der),
      "serverFingerprint": transport.server.fingerprint,
      "certificate": certificate == null ? null : base64.encode(certificate.der),
      "deviceId": enrolled.id,
      "deviceCode": enrolled.code,
    }, macKey));
  }

  void _failed(PairingTicket ticket, String reason) {
    ticket._failures++;
    final voided = ticket._failures >= Pairing.maxAttempts;
    if (voided && identical(_live, ticket)) _live = null;

    _audit({"reason": reason, "attempt": ticket._failures, "voided": voided});
  }

  void _audit(Map<String, Object?> data) =>
    _engine.store.write((db) => AuditLog(db, now: _engine.now).append(AuditKinds.pairingFailed, data: data));

  static Uint8List _decode(Object? value) {
    if (value is! String) return Uint8List(0);

    try {
      return base64.decode(value);
    } on FormatException {
      return Uint8List(0);
    }
  }
}
