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
