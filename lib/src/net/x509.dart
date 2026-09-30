import 'dart:io';
import 'dart:typed_data';

import 'package:lyra_protocol/lyra_protocol.dart';

/// A certificate this engine issued: its DER and what the engine needs to know about it.
final class Certificate {
  const Certificate(this.der, {required this.notAfter});

  final Uint8List der;
  final DateTime notAfter;

  String get pem => Pem.encode("CERTIFICATE", der);

  String get fingerprint => Fingerprint.of(der);
}

/// The X.509 v3 certificates of a master (plan §5.3), written by hand in DER because they are
/// few and fixed: the installation CA, the server certificate and device certificates.
/// Everything is P-256 with ECDSA-SHA256.
abstract final class X509 {
  static const _cn = "2.5.4.3";
  static const _org = "2.5.4.10";
  static const _basicConstraints = "2.5.29.19";
  static const _keyUsage = "2.5.29.15";
  static const _extKeyUsage = "2.5.29.37";
  static const _subjectAltName = "2.5.29.17";
  static const _nameConstraints = "2.5.29.30";
  static const _subjectKeyId = "2.5.29.14";
  static const _authorityKeyId = "2.5.29.35";
  static const _serverAuth = "1.3.6.1.5.5.7.3.1";
  static const _clientAuth = "1.3.6.1.5.5.7.3.2";

  /// The addresses the browser root may vouch for ([authority]).
  static final List<(InternetAddress, int)> privateRanges = [
    (InternetAddress("10.0.0.0"), 8),
    (InternetAddress("172.16.0.0"), 12),
    (InternetAddress("192.168.0.0"), 16),
    (InternetAddress("127.0.0.0"), 8),
    (InternetAddress("169.254.0.0"), 16),
    (InternetAddress("fc00::"), 7),
    (InternetAddress("fe80::"), 10),
    (InternetAddress("::1"), 128),
  ];

  /// The installation CA: 20 years (it is replaced with the master, never renewed in place),
  /// path length 0.
  ///
  /// It exists as **two self-signed certificates of the same key and name**, and every
  /// certificate the key signs chains to both:
  /// - the **pinned** root ([forBrowsers] false) is the only root a native Lyra client trusts for
  ///   this master, inside its own TLS context; it never enters an OS trust store, so it needs
  ///   no name constraints. (Dart's TLS, BoringSSL, refuses IP name constraints outright,
  ///   "unsupported name constraint type", so a native client could not use the other one.)
  /// - the **browser** root ([forBrowsers] true) is what an admin installs in an OS trust store
  ///   for web (plan §5.3). It carries critical X.509 name constraints: private and link-local
  ///   ranges, loopback, `.local` and this computer's [hostnames]. Browsers and OS verifiers
  ///   honour them, so installing it can't be used to intercept that computer's other traffic.
  static Certificate authority({
    required EcKeyPair key,
    required String instanceId,
    required List<String> hostnames,
    bool forBrowsers = false,
    DateTime? now,
  }) {
    final start = _start(now);
    final name = _authorityName(instanceId);

    return _sign(
      issuerKey: key,
      issuer: name,
      subject: name,
      subjectKey: key.spki,
      notBefore: start,
      notAfter: start.add(const Duration(days: 365 * 20)),
      extensions: [
        _extension(_basicConstraints, Der.sequence([Der.boolean(true), Der.smallInteger(0)]), critical: true),
        // keyCertSign | cRLSign.
        _extension(_keyUsage, Der.bitString([0x06], unusedBits: 1), critical: true),
        if (forBrowsers)
          _extension(_nameConstraints, Der.sequence([
            Der.implicitConstructed(0, [
              for (final (address, prefix) in privateRanges)
                Der.sequence([Der.implicitPrimitive(7, [...address.rawAddress, ..._mask(address, prefix)])]),
              for (final host in {"localhost", "local", ...hostnames.map((h) => h.toLowerCase())})
                Der.sequence([Der.implicitPrimitive(2, host.codeUnits)]),
            ]),
          ]), critical: true),
        _extension(_subjectKeyId, Der.octetString(_keyId(key.spki))),
      ],
    );
  }

  /// The certificate `/rpc` serves: every address and name of this computer, 1 year. It is
  /// issued again whenever the addresses change (DHCP) and at every start past half its life.
  static Certificate server({
    required EcKeyPair key,
    required EcKeyPair caKey,
    required String instanceId,
    required List<InternetAddress> addresses,
    required List<String> hostnames,
    DateTime? now,
  }) {
    final start = _start(now);

    return _sign(
      issuerKey: caKey,
      issuer: _authorityName(instanceId),
      subject: _name("Lyra server ${instanceId.substring(0, 8)}"),
      subjectKey: key.spki,
      notBefore: start,
      notAfter: start.add(const Duration(days: 365)),
      extensions: [
        _extension(_basicConstraints, Der.sequence([]), critical: true),
        // digitalSignature.
        _extension(_keyUsage, Der.bitString([0x80], unusedBits: 7), critical: true),
        _extension(_extKeyUsage, Der.sequence([Der.oid(_serverAuth)])),
        _extension(_subjectAltName, Der.sequence([
          for (final host in {"localhost", ...hostnames.map((h) => h.toLowerCase())})
            Der.implicitPrimitive(2, host.codeUnits),
          for (final address in addresses) Der.implicitPrimitive(7, address.rawAddress),
        ])),
        _extension(_subjectKeyId, Der.octetString(_keyId(key.spki))),
        _extension(_authorityKeyId, Der.sequence([Der.implicitPrimitive(0, _keyId(caKey.spki))])),
      ],
    );
  }

  /// A paired device's certificate for mutual TLS: its public key, its device id as the name,
  /// client authentication only, 10 years (revocation is the deny list, not expiry).
  static Certificate device({
    required Uint8List spki,
    required String deviceId,
    required EcKeyPair caKey,
    required String instanceId,
    DateTime? now,
  }) {
    // Refuses a key that isn't P-256 before signing anything for it.
    P256.pointOfSpki(spki);

    final start = _start(now);

    return _sign(
      issuerKey: caKey,
      issuer: _authorityName(instanceId),
      subject: _name("Lyra device $deviceId"),
      subjectKey: spki,
      notBefore: start,
      notAfter: start.add(const Duration(days: 365 * 10)),
      extensions: [
        _extension(_basicConstraints, Der.sequence([]), critical: true),
        _extension(_keyUsage, Der.bitString([0x80], unusedBits: 7), critical: true),
        _extension(_extKeyUsage, Der.sequence([Der.oid(_clientAuth)])),
        _extension(_authorityKeyId, Der.sequence([Der.implicitPrimitive(0, _keyId(caKey.spki))])),
      ],
    );
  }

  /// Reads back the validity end of a certificate this engine issued.
  static DateTime notAfterOf(List<int> der) {
    final tbs = _tbs(der);
    tbs.next(); // version
    tbs.next(); // serial
    tbs.next(); // signature algorithm
    tbs.next(); // issuer
    final validity = tbs.next(Der.tagSequence).children;
    validity.next();

    return _time(validity.next());
  }

  static Certificate read(List<int> der) => Certificate(Uint8List.fromList(der), notAfter: notAfterOf(der));

  static Certificate _sign({
    required EcKeyPair issuerKey,
    required Uint8List issuer,
    required Uint8List subject,
    required Uint8List subjectKey,
    required DateTime notBefore,
    required DateTime notAfter,
    required List<Uint8List> extensions,
  }) {
    final algorithm = Der.sequence([Der.oid(P256.ecdsaSha256Oid)]);
    // 16 random bytes, top bit cleared: positive and unique (RFC 5280 §4.1.2.2).
    final serial = Hashes.random(16)..[0] &= 0x7f;
    final tbs = Der.sequence([
      Der.explicit(0, Der.smallInteger(2)),
      Der.integer(Der.toBigInt(serial)),
      algorithm,
      issuer,
      Der.sequence([Der.time(notBefore), Der.time(notAfter)]),
      subject,
      subjectKey,
      Der.explicit(3, Der.sequence(extensions)),
    ]);

    final der = Der.sequence([tbs, algorithm, Der.bitString(issuerKey.sign(tbs))]);

    return Certificate(der, notAfter: DateTime.fromMillisecondsSinceEpoch(notAfter.millisecondsSinceEpoch, isUtc: true));
  }

  /// Both roots have this name: it is how a certificate the key signs finds either of them.
  static Uint8List _authorityName(String instanceId) => _name("Lyra installation ${instanceId.substring(0, 8)}");

  static Uint8List _name(String commonName) => Der.sequence([
    Der.set([Der.sequence([Der.oid(_org), Der.utf8String("Lyra")])]),
    Der.set([Der.sequence([Der.oid(_cn), Der.utf8String(commonName)])]),
  ]);

  static Uint8List _extension(String oid, Uint8List value, {bool critical = false}) => Der.sequence([
    Der.oid(oid),
    if (critical) Der.boolean(true),
    Der.octetString(value),
  ]);

  static Uint8List _keyId(Uint8List spki) => Hashes.sha256(spki).sublist(0, 20);

  static List<int> _mask(InternetAddress address, int prefix) {
    final length = address.rawAddress.length;

    return [for (var i = 0; i < length; i++) i * 8 + 8 <= prefix ? 0xff : i * 8 >= prefix ? 0x00 : (0xff << (8 - prefix % 8)) & 0xff];
  }

  /// A minute back, so a client whose clock runs slightly behind still accepts a fresh one.
  static DateTime _start(DateTime? now) {
    final at = (now ?? DateTime.now()).toUtc().subtract(const Duration(minutes: 1));

    return DateTime.utc(at.year, at.month, at.day, at.hour, at.minute, at.second);
  }

  static DerReader _tbs(List<int> der) =>
    DerReader(der).next(Der.tagSequence).children.next(Der.tagSequence).children;

  static DateTime _time(DerElement element) {
    final text = String.fromCharCodes(element.value);
    final full = element.tag == Der.tagUtcTime
      ? "${int.parse(text.substring(0, 2)) >= 50 ? "19" : "20"}$text"
      : text;

    return DateTime.utc(
      int.parse(full.substring(0, 4)),
      int.parse(full.substring(4, 6)),
      int.parse(full.substring(6, 8)),
      int.parse(full.substring(8, 10)),
      int.parse(full.substring(10, 12)),
      int.parse(full.substring(12, 14)),
    );
  }
}
