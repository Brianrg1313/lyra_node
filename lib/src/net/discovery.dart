import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:lyra_protocol/lyra_protocol.dart';

import '../storage/store.dart' show fold;

/// The name a browser on the LAN opens this master by, `<label>.local`, made from the company's
/// name so nobody has to find or type an address ("Panadería Don José" →
/// `panaderia-don-jose.local`). mDNS answers it, so no router is touched, and the browser root
/// already allows every `.local` name (`X509.authority`).
abstract final class LanName {
  /// At most this many characters before `.local`: short enough to read out and type.
  static const int maxLength = 40;

  /// What a name with no letter or digit we can write becomes (`東京` folds to nothing).
  static const String fallback = "lyra";

  /// [company] as a DNS label: accents off, lower case, anything else a single `-`.
  static String of(String company) {
    var label = fold(company)
      .replaceAll(RegExp("[^a-z0-9]+"), "-")
      .replaceAll(RegExp(r"^-+|-+$"), "");
    if (label.length > maxLength) label = label.substring(0, maxLength).replaceAll(RegExp(r"-+$"), "");

    return label.isEmpty ? fallback : label;
  }

  /// The [attempt]th name to try for [label] when another device on the LAN already answers the
  /// previous ones: `label`, `label-2`, `label-3`…
  static String candidate(String label, int attempt) => attempt <= 1 ? label : "$label-$attempt";

  /// The first of [label]'s candidates nobody else on the LAN answers (RFC 6762 §8.1, reduced to
  /// one question per name), [previous] (the one this master had) before them, so a free name
  /// people saved stays. [own] are this computer's addresses: its own answers aren't another
  /// device's. With no multicast here it keeps [label]: a conflict only costs that name.
  static Future<String> claim(String label, {String? previous, List<InternetAddress> own = const [], int attempts = 9}) async {
    final RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } on SocketException {
      return label;
    }

    final mine = {for (final address in own) address.address};
    var asking = "";
    var heard = Completer<bool>();
    final listening = socket.listen((event) {
      if (event != RawSocketEvent.read) return;

      final datagram = socket.receive();
      if (datagram == null || mine.contains(datagram.address.address)) return;
      if (MdnsResponder.answersHost(datagram.data, asking) && !heard.isCompleted) heard.complete(true);
    });

    try {
      final names = {
        if (previous != null && previous.startsWith(label)) previous,
        for (var attempt = 1; attempt <= attempts; attempt++) candidate(label, attempt),
      };

      for (final name in names) {
        asking = "$name.local";
        heard = Completer<bool>();

        // A one-shot question from another port: responders answer it directly (RFC 6762 §6.7).
        socket.send([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, ...MdnsResponder._name(asking), 0, 1, 0, 1],
          MdnsResponder.group, MdnsResponder.mdnsPort);
        final taken = await heard.future.timeout(probeWait, onTimeout: () => false);
        if (!taken) return name;
      }

      return label;
    } on SocketException {
      return label;
    } finally {
      await listening.cancel();
      socket.close();
    }
  }

  /// How long a name is asked for before it counts as free.
  static const Duration probeWait = Duration(milliseconds: 700);
}

/// Answers mDNS / DNS-SD queries for `_lyra._tcp.local` (plan §5.2): PTR to this master's
/// instance, SRV with the port, TXT with the advertised id, A records of its addresses.
///
/// A minimal responder, not a general one: it only answers questions about its own names and
/// announces itself at start and with a goodbye at stop (RFC 6762 §8.3, §10.1). Its addresses
/// answer to this computer's name and to the master's [alias] (`LanName`), once there is one.
/// The alias is said only to a question about it: it is made from the company's name, and the
/// advertisement names nothing about the company (plan §5.2); who asks for it knows it already.
final class MdnsResponder {
  MdnsResponder({
    required this.instanceId,
    required this.port,
    required List<InternetAddress> addresses,
    String? host,
    this.alias,
  }) : _addresses = addresses.where((address) => address.type == InternetAddressType.IPv4 && !address.isLoopback).toList(),
       _host = "${host ?? Platform.localHostname.toLowerCase()}.local";

  static final InternetAddress group = InternetAddress("224.0.0.251");
  static const int mdnsPort = 5353;
  static const int ttl = 120;

  final String instanceId;
  final int port;
  final List<InternetAddress> _addresses;
  final String _host;
  RawDatagramSocket? _socket;

  String get instance => Discovery.instanceName(instanceId);

  /// The master's own name (`label.local`), or none before its company exists; set while
  /// running when the company is created.
  String? alias;

  /// Starts answering. A computer where 5353 can't be bound (another responder without address
  /// reuse, a firewall policy) simply isn't discoverable: clients fall back to the QR or a typed
  /// address (plan §5.2).
  Future<bool> start() async {
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, mdnsPort, reuseAddress: true);

      for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        try {
          socket.joinMulticast(group, interface);
        } on SocketException {
          // An interface without multicast (a VPN): the others still answer.
        }
      }

      socket.listen((event) {
        if (event != RawSocketEvent.read) return;

        final datagram = socket.receive();
        if (datagram == null) return;

        final answer = answerFor(datagram.data, from: datagram.address);
        if (answer == null) return;

        socket.send(answer, group, mdnsPort);
        // A legacy (one-shot) resolver asks from another port and only hears a direct answer.
        if (datagram.port != mdnsPort) socket.send(answer, datagram.address, datagram.port);
      });

      _socket = socket;
      socket.send(_response(id: 0, ttl: ttl), group, mdnsPort);

      return true;
    } on SocketException {
      return false;
    }
  }

  Future<void> stop() async {
    final socket = _socket;
    _socket = null;

    if (socket == null) return;

    socket.send(_response(id: 0, ttl: 0), group, mdnsPort);
    socket.close();
  }

  /// The response to [query], or null when it asks nothing about this master. Queries are
  /// never trusted to be well formed: anything unreadable is ignored. [from] is who asked.
  Uint8List? answerFor(Uint8List query, {InternetAddress? from}) {
    try {
      final reader = _Reader(query);
      final id = reader.u16();
      final flags = reader.u16();
      final questions = reader.u16();

      if (flags & 0x8000 != 0) return null; // A response, not a question.
      reader.skip(6);

      var ours = false;
      var named = false;
      for (var i = 0; i < questions; i++) {
        final name = reader.name().toLowerCase();
        final type = reader.u16();
        reader.u16(); // class

        final any = type == 255;
        if ((name == Discovery.serviceType && (type == 12 || any)) ||
            (name == instance.toLowerCase() && (type == 33 || type == 16 || any)) ||
            ((name == _host || name == alias) && (type == 1 || any))) {
          ours = true;
          named = named || name == alias;
        }
      }

      return ours ? _response(id: id, ttl: ttl, named: named, to: from) : null;
    } on RangeError {
      return null;
    } on FormatException {
      return null;
    }
  }

  Uint8List _response({required int id, required int ttl, bool named = false, InternetAddress? to}) {
    final out = BytesBuilder();
    final addresses = reachableFrom(to);
    final records = <List<int>>[
      _record(Discovery.serviceType, 12, ttl, _name(instance), flush: false),
      _record(instance, 33, ttl, [0, 0, 0, 0, port >> 8, port & 0xff, ..._name(_host)]),
      _record(instance, 16, ttl, [
        ..._txt("id=${Discovery.advertisedId(instanceId)}"),
        ..._txt("v=$protocolVersion"),
      ]),
      for (final address in addresses) _record(_host, 1, ttl, address.rawAddress),
      if (alias case final alias? when named)
        for (final address in addresses) _record(alias, 1, ttl, address.rawAddress),
    ];

    out
      ..add(_u16(id))
      ..add(_u16(0x8400)) // response, authoritative
      ..add(_u16(0))
      ..add(_u16(records.length))
      ..add(_u16(0))
      ..add(_u16(0));
    for (final record in records) {
      out.add(record);
    }

    return out.takeBytes();
  }

  /// The addresses to answer [asker] with: those on its network (the same /24, what a shop's
  /// router hands out), so a browser doesn't try first an address of a virtual adapter (WSL, a
  /// VPN) it can't reach and wait on it (RFC 6762 §6.2). Every one when none matches, or when the
  /// asker is this computer or unknown.
  List<InternetAddress> reachableFrom(InternetAddress? asker) {
    if (asker == null || asker.type != InternetAddressType.IPv4) return _addresses;

    final from = asker.rawAddress;
    if (_addresses.any((address) => address.address == asker.address)) return _addresses;

    final near = _addresses.where((address) {
      final raw = address.rawAddress;
      return raw[0] == from[0] && raw[1] == from[1] && raw[2] == from[2];
    }).toList();

    return near.isEmpty ? _addresses : near;
  }

  /// Whether [packet] is a response with an address record of [host] (`LanName.claim`). A
  /// goodbye (TTL 0) is a name being let go, not one in use.
  static bool answersHost(Uint8List packet, String host) {
    try {
      final reader = _Reader(packet);
      reader.u16();
      if (reader.u16() & 0x8000 == 0) return false;

      final questions = reader.u16();
      final records = reader.u16() + reader.u16() + reader.u16();
      for (var i = 0; i < questions; i++) {
        reader.name();
        reader.skip(4);
      }

      for (var i = 0; i < records; i++) {
        final name = reader.name().toLowerCase();
        final type = reader.u16();
        reader.u16();
        final ttl = reader.u16() << 16 | reader.u16();
        final length = reader.u16();
        reader.skip(length);

        if (name == host && (type == 1 || type == 28) && ttl > 0) return true;
      }

      return false;
    } on RangeError {
      return false;
    } on FormatException {
      return false;
    }
  }

  static List<int> _record(String name, int type, int ttl, List<int> data, {bool flush = true}) => [
    ..._name(name),
    ..._u16(type),
    // Class IN, with the cache-flush bit on records only this master owns.
    ..._u16(flush ? 0x8001 : 0x0001),
    ttl >> 24 & 0xff, ttl >> 16 & 0xff, ttl >> 8 & 0xff, ttl & 0xff,
    ..._u16(data.length),
    ...data,
  ];

  static List<int> _name(String name) => [
    for (final label in name.split(".").where((label) => label.isNotEmpty)) ...[label.length, ...label.codeUnits],
    0,
  ];

  static List<int> _txt(String entry) => [entry.length, ...entry.codeUnits];

  static List<int> _u16(int value) => [value >> 8 & 0xff, value & 0xff];
}

final class _Reader {
  _Reader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  int u16() {
    final value = _bytes[_offset] << 8 | _bytes[_offset + 1];
    _offset += 2;

    return value;
  }

  void skip(int count) => _offset += count;

  /// A name, following compression pointers (at most 16, so a loop can't hang it).
  String name() {
    final labels = <String>[];
    var offset = _offset;
    var jumped = false;

    for (var hops = 0; hops < 16;) {
      final length = _bytes[offset];

      if (length == 0) {
        if (!jumped) _offset = offset + 1;
        return labels.join(".");
      }

      if (length & 0xc0 == 0xc0) {
        if (!jumped) _offset = offset + 2;
        offset = (length & 0x3f) << 8 | _bytes[offset + 1];
        jumped = true;
        hops++;
        continue;
      }

      labels.add(String.fromCharCodes(_bytes.sublist(offset + 1, offset + 1 + length)));
      offset += length + 1;
    }

    throw const FormatException("mDNS: name loop");
  }
}
