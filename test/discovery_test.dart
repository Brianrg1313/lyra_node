import 'dart:io';
import 'dart:typed_data';

import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:multicast_dns/multicast_dns.dart';
// The package's own decoder: an independent reader of what the responder writes.
// ignore: implementation_imports
import 'package:multicast_dns/src/packet.dart';
import 'package:test/test.dart';

void main() {
  const instanceId = "0192f0aa-1111-7000-8000-000000000001";

  MdnsResponder responder() => MdnsResponder(
    instanceId: instanceId,
    port: 4780,
    addresses: [InternetAddress("192.168.1.20")],
    host: "server",
  );

  test('answers a PTR question for _lyra._tcp with PTR, SRV, TXT and A', () {
    final answer = responder().answerFor(Uint8List.fromList(encodeMDnsQuery(Discovery.serviceType, type: 12)))!;
    final records = decodeMDnsResponse(answer)!;

    final pointer = records.whereType<PtrResourceRecord>().single;
    final service = records.whereType<SrvResourceRecord>().single;
    final text = records.whereType<TxtResourceRecord>().single;
    final address = records.whereType<IPAddressResourceRecord>().single;

    expect(pointer.domainName, Discovery.instanceName(instanceId));
    expect(service.port, 4780);
    expect(service.target, "server.local");
    expect(text.text, contains("id=${Discovery.advertisedId(instanceId)}"));
    expect(address.address.address, "192.168.1.20");
  });

  test('the advertisement says nothing about the company, nor the instance id itself', () {
    final answer = responder().answerFor(Uint8List.fromList(encodeMDnsQuery(Discovery.serviceType, type: 12)))!;

    expect(String.fromCharCodes(answer), isNot(contains(instanceId)));
    expect(Discovery.advertisedId(instanceId), hasLength(12));
  });

  test('other questions, responses and garbage get no answer', () {
    final r = responder();

    expect(r.answerFor(Uint8List.fromList(encodeMDnsQuery("_printer._tcp.local", type: 12))), isNull);
    expect(r.answerFor(Uint8List.fromList([0, 0, 0x84, 0, 0, 1])), isNull);
    expect(r.answerFor(Uint8List.fromList([1, 2, 3])), isNull);
    // A compression pointer to itself.
    expect(r.answerFor(Uint8List.fromList([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xc0, 12, 0, 12, 0, 1])), isNull);
  });

  group('the name for browsers', () {
    test("is the company's name as a DNS label, accents off", () {
      expect(LanName.of("Panadería Don José"), "panaderia-don-jose");
      expect(LanName.of("  --Café & Té!! "), "cafe-te");
      expect(LanName.of("Ñandú 24/7"), "nandu-24-7");
    });

    test('a name with nothing it can write is lyra; a long one is cut, never ending in a dash', () {
      expect(LanName.of("東京"), LanName.fallback);
      expect(LanName.of("!!!"), LanName.fallback);

      final long = LanName.of("Distribuidora de Repuestos y Accesorios Automotrices Hermanos Pérez");
      expect(long.length, lessThanOrEqualTo(LanName.maxLength));
      expect(long, isNot(endsWith("-")));
      expect(long, startsWith("distribuidora-de-repuestos"));
    });

    test('the next candidates are numbered', () {
      expect([for (var i = 1; i <= 3; i++) LanName.candidate("cafe", i)], ["cafe", "cafe-2", "cafe-3"]);
    });

    test("the responder answers the master's name with its addresses, once it has one", () {
      final named = MdnsResponder(
        instanceId: instanceId,
        port: 4780,
        addresses: [InternetAddress("192.168.1.20")],
        host: "server",
        alias: "lovelace-cafe.local",
      );
      final answer = named.answerFor(Uint8List.fromList(encodeMDnsQuery("lovelace-cafe.local", type: 1)))!;
      final addresses = decodeMDnsResponse(answer)!.whereType<IPAddressResourceRecord>();

      expect(addresses.map((record) => (record.name, record.address.address)),
        containsAll([("lovelace-cafe.local", "192.168.1.20"), ("server.local", "192.168.1.20")]));
      expect(MdnsResponder.answersHost(answer, "lovelace-cafe.local"), isTrue);
      expect(MdnsResponder.answersHost(answer, "other.local"), isFalse);

      expect(responder().answerFor(Uint8List.fromList(encodeMDnsQuery("lovelace-cafe.local", type: 1))), isNull);

      // The advertisement still says nothing about the company (plan §5.2).
      final advertised = named.answerFor(Uint8List.fromList(encodeMDnsQuery(Discovery.serviceType, type: 12)))!;
      expect(String.fromCharCodes(advertised), isNot(contains("lovelace")));
    });

    test("who asks gets the addresses on its own network, so a virtual adapter's isn't tried first", () {
      final named = MdnsResponder(
        instanceId: instanceId,
        port: 4780,
        addresses: [InternetAddress("172.17.208.1"), InternetAddress("192.168.1.20"), InternetAddress("10.0.0.2")],
        host: "server",
        alias: "lovelace-cafe.local",
      );
      final question = Uint8List.fromList(encodeMDnsQuery("lovelace-cafe.local", type: 1));
      List<String> answered(String? from) => [
        for (final record in decodeMDnsResponse(named.answerFor(question, from: from == null ? null : InternetAddress(from))!)!
          .whereType<IPAddressResourceRecord>()
          .where((record) => record.name == "lovelace-cafe.local"))
          record.address.address,
      ];

      expect(answered("192.168.1.57"), ["192.168.1.20"]);
      // Another network, this computer itself, or unknown: every address.
      expect(answered("192.168.7.9"), hasLength(3));
      expect(answered("10.0.0.2"), hasLength(3));
      expect(answered(null), hasLength(3));
    });

    test('a question or garbage is no answer for a name', () {
      expect(MdnsResponder.answersHost(Uint8List.fromList(encodeMDnsQuery("server.local", type: 1)), "server.local"), isFalse);
      expect(MdnsResponder.answersHost(Uint8List.fromList([1, 2, 3]), "server.local"), isFalse);
    });

    test('a name another device answers is not claimed: the next one is', () async {
      final busy = MdnsResponder(
        instanceId: instanceId,
        port: 4780,
        addresses: await LocalAddresses.current(),
        alias: "lyra-claim-test.local",
      );
      if (!await busy.start()) return markTestSkipped("port 5353 not available here");
      addTearDown(busy.stop);

      final claimed = await LanName.claim("lyra-claim-test");
      if (claimed == "lyra-claim-test") return markTestSkipped("multicast is blocked on this computer");

      expect(claimed, "lyra-claim-test-2");
      expect(await LanName.claim("lyra-claim-test", previous: "lyra-claim-test-3"), "lyra-claim-test-3");
      expect(await LanName.claim("lyra-free-test"), "lyra-free-test");
    }, tags: "network");
  });

  test('a client on this computer finds it', () async {
    final live = MdnsResponder(instanceId: instanceId, port: 4780, addresses: await LocalAddresses.current());
    if (!await live.start()) return markTestSkipped("port 5353 not available here");
    addTearDown(live.stop);

    final client = MDnsClient();
    await client.start();
    addTearDown(client.stop);

    final found = await client
      .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(Discovery.serviceType))
      .map((record) => record.domainName)
      .firstWhere((name) => name == Discovery.instanceName(instanceId), orElse: () => "")
      .timeout(const Duration(seconds: 5), onTimeout: () => "");

    if (found.isEmpty) return markTestSkipped("multicast is blocked on this computer");
    expect(found, Discovery.instanceName(instanceId));
  }, tags: "network");
}
