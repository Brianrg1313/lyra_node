import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:lyra_protocol/lyra_protocol.dart';

/// Answers mDNS / DNS-SD queries for `_lyra._tcp.local` (plan §5.2): PTR to this master's
/// instance, SRV with the port, TXT with the advertised id, A records of its addresses.
///
/// A minimal responder, not a general one: it only answers questions about its own names and
/// announces itself at start and with a goodbye at stop (RFC 6762 §8.3, §10.1).
final class MdnsResponder {
  MdnsResponder({required this.instanceId, required this.port, required List<InternetAddress> addresses, String? host})
    : _addresses = addresses.where((address) => address.type == InternetAddressType.IPv4 && !address.isLoopback).toList(),
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

        final answer = answerFor(datagram.data);
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
  /// never trusted to be well formed: anything unreadable is ignored.
  Uint8List? answerFor(Uint8List query) {
    try {
      final reader = _Reader(query);
      final id = reader.u16();
      final flags = reader.u16();
      final questions = reader.u16();

      if (flags & 0x8000 != 0) return null; // A response, not a question.
      reader.skip(6);

      var ours = false;
      for (var i = 0; i < questions; i++) {
        final name = reader.name().toLowerCase();
        final type = reader.u16();
        reader.u16(); // class

        final any = type == 255;
        if ((name == Discovery.serviceType && (type == 12 || any)) ||
            (name == instance.toLowerCase() && (type == 33 || type == 16 || any)) ||
            (name == _host && (type == 1 || any))) {
          ours = true;
        }
      }

      return ours ? _response(id: id, ttl: ttl) : null;
    } on RangeError {
      return null;
    } on FormatException {
      return null;
    }
  }

  Uint8List _response({required int id, required int ttl}) {
    final out = BytesBuilder();
    final records = <List<int>>[
      _record(Discovery.serviceType, 12, ttl, _name(instance), flush: false),
      _record(instance, 33, ttl, [0, 0, 0, 0, port >> 8, port & 0xff, ..._name(_host)]),
      _record(instance, 16, ttl, [
        ..._txt("id=${Discovery.advertisedId(instanceId)}"),
        ..._txt("v=$protocolVersion"),
      ]),
      for (final address in _addresses) _record(_host, 1, ttl, address.rawAddress),
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
