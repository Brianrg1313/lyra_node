import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../crypto/envelope.dart';
import '../crypto/secrets.dart';
import '../storage/store.dart';
import 'x509.dart';

/// The addresses and names this computer answers to on the LAN.
abstract final class LocalAddresses {
  /// Every address in a private, link-local or loopback range (`X509.privateRanges`). A public
  /// address is left out: the browser root may not vouch for it, and a browser would then refuse
  /// the whole server certificate.
  static Future<List<InternetAddress>> current() async {
    final interfaces = await NetworkInterface.list(includeLoopback: true, includeLinkLocal: true);
    final found = <InternetAddress>{
      InternetAddress.loopbackIPv4,
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (isPrivate(address)) InternetAddress.fromRawAddress(address.rawAddress),
    };

    // IPv4 first: it's what people type and what a QR lists first.
    return found.toList()..sort((a, b) => a.rawAddress.length.compareTo(b.rawAddress.length));
  }

  static bool isPrivate(InternetAddress address) {
    for (final (range, prefix) in X509.privateRanges) {
      if (range.type == address.type && _inRange(address.rawAddress, range.rawAddress, prefix)) return true;
    }

    return false;
  }

  static String get hostname => Platform.localHostname.toLowerCase();

  static bool _inRange(List<int> address, List<int> range, int prefix) {
    for (var bit = 0; bit < prefix; bit++) {
      final mask = 0x80 >> (bit % 8);
      if (address[bit ~/ 8] & mask != range[bit ~/ 8] & mask) return false;
    }

    return true;
  }
}

/// The installation CA (plan §5.3): its key and both roots (`X509.authority`), kept in `meta`
/// (the SQLCipher database, keyed from the keyring). Only an unlocked engine can issue.
final class Authority {
  Authority._(this.instanceId, this._key, this.pinned, this.browser, this.hostnames);

  static const _privateKey = "ca.key";
  static const _pinned = "ca.certificate";
  static const _browser = "ca.browser_certificate";
  static const _hostnames = "ca.hostnames";

  /// The CA of this master, made the first time (at setup, or at the first start of a master
  /// set up before the network existed).
  static Authority ensure(Store store, String instanceId, {DateTime? now}) {
    final existing = _load(store.db, instanceId);
    if (existing != null) return existing;

    final key = EcKeyPair.generate();
    final hostnames = [LocalAddresses.hostname];
    final pinned = X509.authority(key: key, instanceId: instanceId, hostnames: hostnames, now: now);
    final browser = X509.authority(key: key, instanceId: instanceId, hostnames: hostnames, forBrowsers: true, now: now);

    store.write((db) => db.execute("INSERT INTO meta (key, value) VALUES (?, ?), (?, ?), (?, ?), (?, ?)", [
      _privateKey, key.privateKeyPem,
      _pinned, pinned.pem,
      _browser, browser.pem,
      _hostnames, jsonEncode(hostnames),
    ]));

    return Authority._(instanceId, key, pinned, browser, hostnames);
  }

  static Authority? _load(Database db, String instanceId) {
    final rows = {
      for (final row in db.select("SELECT key, value FROM meta WHERE key LIKE 'ca.%'"))
        row["key"] as String: row["value"] as String,
    };

    if (!rows.containsKey(_privateKey)) return null;

    return Authority._(
      instanceId,
      EcKeyPair.fromPem(rows[_privateKey]!),
      X509.read(Pem.decode("CERTIFICATE", rows[_pinned]!)),
      X509.read(Pem.decode("CERTIFICATE", rows[_browser]!)),
      (jsonDecode(rows[_hostnames]!) as List).cast<String>(),
    );
  }

  final String instanceId;
  final EcKeyPair _key;

  /// The root native clients pin; its fingerprint is the QR's `caFingerprint`.
  final Certificate pinned;

  /// The name-constrained root an admin installs for web browsers.
  final Certificate browser;

  /// The names the browser root allows besides `localhost` and `.local`.
  final List<String> hostnames;

  /// A server certificate for [addresses], this computer's names the CA allows and [host], the
  /// master's own `.local` name (`LanName`).
  ({Certificate certificate, EcKeyPair key}) issueServer(List<InternetAddress> addresses, {String? host, DateTime? now}) {
    final key = EcKeyPair.generate();
    final current = LocalAddresses.hostname;
    final names = [
      if (hostnames.contains(current)) current,
      if (!current.contains(".")) "$current.local",
      ?host,
    ];

    return (
      certificate: X509.server(
        key: key,
        caKey: _key,
        instanceId: instanceId,
        addresses: addresses,
        hostnames: names,
        now: now,
      ),
      key: key,
    );
  }

  Certificate issueDevice(Uint8List spki, String deviceId, {DateTime? now}) =>
    X509.device(spki: spki, deviceId: deviceId, caKey: _key, instanceId: instanceId, now: now);
}

/// `transport.json`: what the server needs **before** the engine is unlocked (plan §6.2,
/// passphrase mode answers `hello` and `engine.unlock` while locked): the pinned root, the
/// server certificate and its key, and which device is the master's own.
///
/// It is sealed (AES-256-GCM) with a key derived from the control key, which lives in the OS
/// vault in both unlock modes. It opens no company data: the server key only proves "this is
/// the master" on the LAN, and it is issued again at every unlocked start that needs it.
final class Transport {
  const Transport({
    required this.ca,
    required this.server,
    required this.serverKeyPem,
    required this.addresses,
    this.host,
    this.masterDevice,
  });

  static const _context = "lyra/transport/v1";

  final Certificate ca;
  final Certificate server;
  final String serverKeyPem;

  /// The addresses [server] names.
  final List<String> addresses;

  /// The master's `.local` name [server] carries (`LanName`), kept here so a locked engine still
  /// announces it; none before the company exists.
  final String? host;

  /// Fingerprint of the master's own device certificate: the only device `engine.unlock`
  /// and `pairing.start` accept.
  final String? masterDevice;

  static Future<Transport?> read(String path, List<int> controlKey) async {
    final file = File(path);
    if (!file.existsSync()) return null;

    try {
      final key = await subkey(controlKey, _context);
      final json = jsonDecode(utf8.decode(await Envelope.open(key, file.readAsBytesSync(), context: _context)))
        as Map<String, Object?>;

      return Transport(
        ca: X509.read(base64.decode(json["ca"] as String)),
        server: X509.read(base64.decode(json["server"] as String)),
        serverKeyPem: json["serverKey"] as String,
        addresses: (json["addresses"] as List).cast<String>(),
        host: json["host"] as String?,
        masterDevice: json["masterDevice"] as String?,
      );
    } on Object {
      // Sealed with another control key, or damaged: issued again at the next unlocked start.
      return null;
    }
  }

  Future<void> write(String path, List<int> controlKey) async {
    final key = await subkey(controlKey, _context);
    final sealed = await Envelope.seal(key, utf8.encode(jsonEncode({
      "ca": base64.encode(ca.der),
      "server": base64.encode(server.der),
      "serverKey": serverKeyPem,
      "addresses": addresses,
      "host": host,
      "masterDevice": masterDevice,
    })), context: _context);
    final temporary = File("$path.tmp");

    temporary.writeAsBytesSync(sealed, flush: true);
    temporary.renameSync(path);
  }

  Transport withMaster(String? fingerprint) => Transport(
    ca: ca,
    server: server,
    serverKeyPem: serverKeyPem,
    addresses: addresses,
    host: host,
    masterDevice: fingerprint,
  );

  /// Whether the server certificate must be issued again: an address or a [host] it doesn't name,
  /// or past half its life.
  bool needsRenewal(List<InternetAddress> current, {String? host, DateTime? now}) {
    final at = (now ?? DateTime.now()).toUtc();
    final halfLife = server.notAfter.subtract(const Duration(days: 365 ~/ 2));

    return at.isAfter(halfLife) || host != this.host || current.any((address) => !addresses.contains(address.address));
  }

  static Transport issue(Authority authority, List<InternetAddress> addresses, {String? host, String? masterDevice, DateTime? now}) {
    final issued = authority.issueServer(addresses, host: host, now: now);

    return Transport(
      ca: authority.pinned,
      server: issued.certificate,
      serverKeyPem: issued.key.privateKeyPem,
      addresses: [for (final address in addresses) address.address],
      host: host,
      masterDevice: masterDevice,
    );
  }

  /// TLS 1.3 only; the server certificate alone in the chain (a client finds the root it
  /// trusts by name: the pinned one natively, the browser one in an OS store); client
  /// certificates are asked for and must chain to the pinned root.
  SecurityContext get context => serveFrom(SecurityContext(withTrustedRoots: false)
    ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3
    ..setTrustedCertificatesBytes(utf8.encode(ca.pem))
    ..setClientAuthoritiesBytes(utf8.encode(ca.pem)));

  /// Makes [context] serve this server certificate. A context a listening socket already holds
  /// serves it from the next handshake on, so a renewed certificate needs no new socket.
  SecurityContext serveFrom(SecurityContext context) => context
    ..useCertificateChainBytes(utf8.encode(server.pem))
    ..usePrivateKeyBytes(utf8.encode(serverKeyPem));
}
