import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:lyra_protocol/lyra_protocol.dart';

import '../audit/audit_log.dart';
import '../engine.dart';
import '../identity/devices.dart';
import '../ids.dart';
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
      _failed(ticket, "bad_point");
      return fail(Pairing.failed);
    }

    send({"step": "reply", "pB": base64.encode(spake.message)});

    final enroll = await receive().timeout(stepTimeout);
    final confirm = enroll["confirm"];

    // One guess per exchange: a wrong confirmation is a wrong code (or a tampered exchange).
    if (enroll["step"] != "enroll" || confirm is! String || !keys.checkPeer(_decode(confirm))) {
      _failed(ticket, "wrong_secret");
      return fail(Pairing.failed);
    }

    final macKey = keys.derive(Pairing.macPurpose);
    final body = Pairing.open(enroll, macKey);
    final device = PairingDevice.tryParse(body?["device"]);
    final publicKey = _decode(body?["publicKey"]);
    final proof = _decode(body?["proof"]);

    if (body == null || device == null || !P256.verify(publicKey, Pairing.proofMessage(keys.confirmA), proof)) {
      _failed(ticket, "bad_enrolment");
      return fail(Pairing.failed);
    }

    // Checked and consumed before the first await below, so a second exchange with the same
    // ticket can't pair a second device.
    if (ticket._used || !identical(_live, ticket)) return fail(Pairing.noPairing);
    ticket._used = true;
    _live = null;

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
      pairedBy: ticket.openedBy,
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

    _engine.store.write((db) => AuditLog(db, now: _engine.now).append(AuditKinds.pairingFailed, data: {
      "reason": reason,
      "attempt": ticket._failures,
      "voided": voided,
    }));
  }

  static Uint8List _decode(Object? value) {
    if (value is! String) return Uint8List(0);

    try {
      return base64.decode(value);
    } on FormatException {
      return Uint8List(0);
    }
  }
}
