import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'net_support.dart';

/// The business domain over the LAN (`business.md`, `session.md` session.bootstrap): the one
/// company and site, their edits and events, the logo, the catalogues. Rule numbers name what
/// each test checks.
void main() {
  late TestMaster master;
  late RpcClient client;
  late Map<String, Object?> tokens;

  setUp(() async {
    master = await TestMaster.start();
    (client, tokens) = await master.signIn();
  });

  Future<Object?> write(Op op, Map<String, Object?> args, {String? commandId}) =>
    client.call(op, args: args, commandId: commandId ?? const Uuid().v7());

  group('session.bootstrap', () {
    test('answers the one company, the owner\'s grants, the catalogues and the deployment (S-30 to S-33)', () async {
      final answer = await client.call(Ops.sessionBootstrap) as Map<String, Object?>;
      final businesses = answer["businesses"] as List;
      final company = businesses.single as Map;

      expect(company["name"], "Lovelace Café");
      expect(company["currency"], "USD");
      expect(answer["permissions"], {company["id"]: ["*"]});
      expect(answer["tasks"], isEmpty);
      expect((answer["client"] as Map)["username"], "ada.owner");
      expect((answer["client"] as Map)["lastName"], "Lovelace");
      expect(((answer["catalogs"] as Map)["countries"] as List).map((row) => (row as Map)["code"]), contains("VE"));
      expect(answer["deployment"], containsPair("mode", "local"));
      // No zone set: the country's (B-9).
      expect((answer["deployment"] as Map)["timezone"], "America/Caracas");
    });
  });

  group('business.create', () {
    late TestMaster bare;
    late RpcClient owner;
    late Map<String, Object?> ownerTokens;

    setUp(() async {
      bare = await TestMaster.start(withCompany: false);
      (owner, ownerTokens) = await bare.signIn();
    });

    Future<Object?> create(RpcClient client, Map<String, Object?> args) =>
      client.call(Ops.businessCreate, args: args, commandId: const Uuid().v7());

    const draft = {"name": " Lovelace Café ", "country": "ve", "currency": "usd", "language": "es", "activity": "food"};

    test("a master set up without its company answers none and the welcome's task (S-30, S-31)", () async {
      final answer = await owner.call(Ops.sessionBootstrap) as Map<String, Object?>;

      expect(answer["businesses"], isEmpty);
      expect(answer["permissions"], isEmpty);
      expect(answer["tasks"], [{"key": "business.none"}]);
      expect((answer["deployment"] as Map)["timezone"], isNull);
    });

    test('the owner creates it once; the bootstrap then answers it (B-1)', () async {
      final created = await create(owner, draft) as Map;

      expect((created["name"], created["currency"], created["activity"]), ("Lovelace Café", "USD", "FOOD"));

      final answer = await owner.call(Ops.sessionBootstrap) as Map<String, Object?>;
      expect((answer["businesses"] as List).single, created);
      expect(answer["tasks"], isEmpty);
      expect((answer["deployment"] as Map)["timezone"], "America/Caracas");

      await expectRefusal(create(owner, draft), "company_exists");
    });

    test("creating it gives the master its name for browsers, which a rename doesn't move", () async {
      var told = 0;
      bare.server.onCompanyCreated = () => told++;
      expect(bare.openEngine.lanName, isNull);

      await create(owner, draft);

      expect(told, 1);
      expect(bare.openEngine.lanName, "lovelace-cafe");

      await owner.call(Ops.businessEdit, args: {"name": "Babbage Bakery"}, commandId: const Uuid().v7());
      expect(bare.openEngine.lanName, "lovelace-cafe");
    });

    test('a wrong field creates nothing', () async {
      await expectRefusal(create(owner, {...draft, "currency": "ZZZ"}), ErrorCodes.invalidField);
      await expectRefusal(create(owner, {...draft, "activity": "PIRACY"}), ErrorCodes.invalidField);
      await expectRefusal(create(owner, {...draft, "name": " "}), ErrorCodes.required);

      expect((await owner.call(Ops.sessionBootstrap) as Map)["businesses"], isEmpty);
    });

    test('only the owner creates it', () async {
      final account = ownerTokens["accountId"] as String;
      bare.openEngine.store.write((db) {
        db.execute("DELETE FROM grants WHERE account = ?", [account]);
        db.execute("INSERT INTO grants (account, permission) VALUES (?, 'business.view')", [account]);
      });
      final (reader, _) = await bare.signIn();

      await expectRefusal(create(reader, draft), ErrorCodes.forbidden);
    });
  });

  group('business.link', () {
    Future<Object?> link(RpcClient client, String cloudId) =>
      client.call(Ops.businessLink, args: {"cloudId": cloudId}, commandId: const Uuid().v7());

    test('the owner links the company once; the bootstrap carries it (B-30, B-31)', () async {
      final events = <RpcEvent>[];
      final subscription = client.events.listen(events.add);
      addTearDown(subscription.cancel);
      await client.call(Ops.eventsSubscribe);

      final bootstrap = await client.call(Ops.sessionBootstrap) as Map;
      expect(((bootstrap["businesses"] as List).single as Map)["cloudId"], isNull);

      final linked = await link(client, " 6650f1c2a9e4b8d3f0a1b2c3 ") as Map;
      expect(linked["cloudId"], "6650f1c2a9e4b8d3f0a1b2c3");

      final again = await client.call(Ops.sessionBootstrap) as Map;
      expect(((again["businesses"] as List).single as Map)["cloudId"], "6650f1c2a9e4b8d3f0a1b2c3");

      // The same id again answers as the first time; another one is refused.
      expect((await link(client, "6650f1c2a9e4b8d3f0a1b2c3") as Map)["cloudId"], "6650f1c2a9e4b8d3f0a1b2c3");
      await expectRefusal(link(client, "another"), "already_linked");

      final engine = master.openEngine;
      expect(engine.audit.list().where((entry) => entry.kind == AuditKinds.companyLinked), hasLength(1));
      expect(engine.business.cloudId, "6650f1c2a9e4b8d3f0a1b2c3");

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(events.single.event, Events.businessChanged);
      expect(events.single.data, {"keys": ["cloudId"]});
    });

    test("an id that isn't one is refused, and only the owner links", () async {
      await expectRefusal(link(client, "not an id"), ErrorCodes.invalidField);
      await expectRefusal(link(client, ""), ErrorCodes.invalidField);

      final account = tokens["accountId"] as String;
      master.openEngine.store.write((db) {
        db.execute("DELETE FROM grants WHERE account = ?", [account]);
        db.execute("INSERT INTO grants (account, permission) VALUES (?, 'business.view')", [account]);
      });
      final (reader, _) = await master.signIn();

      await expectRefusal(link(reader, "6650f1c2a9e4b8d3f0a1b2c3"), ErrorCodes.forbidden);
    });

    test('a company made from the cloud starts linked', () async {
      final bare = await TestMaster.start(withCompany: false);
      final (owner, _) = await bare.signIn();

      final created = await owner.call(Ops.businessCreate, args: {
        "name": "Lovelace Café", "country": "VE", "currency": "USD", "language": "es", "cloudId": "cloud-1",
      }, commandId: const Uuid().v7()) as Map;

      expect(created["cloudId"], "cloud-1");
      await expectRefusal(link(owner, "cloud-2"), "already_linked");
    });
  });

  group('business.company', () {
    test('an edit writes one key and answers the profile (B-2)', () async {
      final profile = await write(Ops.businessEdit, {"legalName": "  Lovelace C.A.  "}) as Map;

      expect(profile["legalName"], "Lovelace C.A.");
      expect(profile["owner"], isTrue);
      expect(profile["verification"], "untrusted");
      expect((await client.call(Ops.businessProfile) as Map)["legalName"], "Lovelace C.A.");

      final cleared = await write(Ops.businessEdit, {"legalName": ""}) as Map;
      expect(cleared["legalName"], isNull);
    });

    test('the name can\'t be cleared; unknown keys, the currency and two keys at once are refused', () async {
      await expectRefusal(write(Ops.businessEdit, {"name": " "}), ErrorCodes.required);
      await expectRefusal(write(Ops.businessEdit, {"currency": "EUR"}), ErrorCodes.invalidField);
      await expectRefusal(write(Ops.businessEdit, {"owner": "me"}), ErrorCodes.invalidField);
      await expectRefusal(write(Ops.businessEdit, {"name": "A", "caption": "B"}), ErrorCodes.badRequest);
      await expectRefusal(write(Ops.businessEdit, {"country": "ZZ"}), ErrorCodes.invalidField);
      await expectRefusal(write(Ops.businessEdit, {"language": "xx"}), ErrorCodes.invalidField);
      await expectRefusal(write(Ops.businessEdit, {"activity": "PIRACY"}), ErrorCodes.invalidField);
      await expectRefusal(write(Ops.businessEdit, {"incorporationDate": "2024-02-30"}), ErrorCodes.invalidField);
      await expectRefusal(write(Ops.businessEdit, {"timezone": "Caracas"}), "invalid_timezone");
    });

    test('a zone, a day and a sector are stored as codes', () async {
      await write(Ops.businessEdit, {"timezone": "America/Bogota"});
      await write(Ops.businessEdit, {"incorporationDate": "2020-02-29"});
      final profile = await write(Ops.businessEdit, {"activity": "food"}) as Map;

      expect(profile["timezone"], "America/Bogota");
      expect(profile["incorporationDate"], "2020-02-29");
      expect(profile["activity"], "FOOD");
      expect(((await client.call(Ops.sessionBootstrap) as Map)["deployment"] as Map)["timezone"], "America/Bogota");
    });

    test('the same commandId again answers the first result and writes nothing twice', () async {
      final commandId = const Uuid().v7();
      final first = await write(Ops.businessEdit, {"caption": "Coffee"}, commandId: commandId);
      await write(Ops.businessEdit, {"caption": "Tea"});

      expect(await write(Ops.businessEdit, {"caption": "Coffee"}, commandId: commandId), first);
      expect((await client.call(Ops.businessProfile) as Map)["caption"], "Tea");
      await expectRefusal(write(Ops.businessEdit, {"caption": "Other"}, commandId: commandId), ErrorCodes.commandReused);
    });

    test('a change reaches subscribers as business/changed with its keys', () async {
      final events = <RpcEvent>[];
      final subscription = client.events.listen(events.add);
      addTearDown(subscription.cancel);
      await client.call(Ops.eventsSubscribe);

      await write(Ops.businessEdit, {"phone": "+58 212 555 0101"});
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(events.single.event, Events.businessChanged);
      expect(events.single.data, {"keys": ["phone"]});
    });

    test('without the permission the master refuses, whatever the app shows', () async {
      final engine = master.openEngine;
      final owner = tokens["accountId"] as String;

      engine.store.write((db) {
        db.execute("DELETE FROM grants WHERE account = ?", [owner]);
        db.execute("INSERT INTO grants (account, permission) VALUES (?, 'business.view')", [owner]);
      });
      final (reader, _) = await master.signIn();

      expect(await reader.call(Ops.businessProfile), isA<Map>());
      await expectRefusal(
        reader.call(Ops.businessEdit, args: {"caption": "x"}, commandId: const Uuid().v7()),
        ErrorCodes.forbidden,
      );
      await expectRefusal(
        reader.call(Ops.businessSiteEdit, args: {"city": "x"}, commandId: const Uuid().v7()),
        ErrorCodes.forbidden,
      );
    });
  });

  group('business.site', () {
    test('only the changed keys are written, and null clears (B-10)', () async {
      await write(Ops.businessSiteEdit, {"address": "Av. Principal", "city": "Caracas", "postalCode": "1010"});
      final site = await write(Ops.businessSiteEdit, {"city": null}) as Map;

      expect(site["address"], "Av. Principal");
      expect(site["city"], isNull);
      expect(site["postalCode"], "1010");
      expect(site["main"], isTrue);
      expect(site["country"], "VE");
    });

    test('a point is both halves at 6 decimals, in range, or nothing (B-11)', () async {
      final site = await write(Ops.businessSiteEdit, {"latitude": 10.4880634, "longitude": -66.8791937}) as Map;

      expect(site["latitude"], 10.488063);
      expect(site["longitude"], -66.879194);

      await expectRefusal(write(Ops.businessSiteEdit, {"latitude": 10.5}), "invalid_point");
      await expectRefusal(write(Ops.businessSiteEdit, {"latitude": 10.5, "longitude": null}), "invalid_point");
      await expectRefusal(write(Ops.businessSiteEdit, {"latitude": 91, "longitude": 0}), "invalid_point");

      final cleared = await write(Ops.businessSiteEdit, {"latitude": null, "longitude": null}) as Map;
      expect(cleared["latitude"], isNull);
    });

    test('the country of a location write is the company\'s (B-12)', () async {
      final site = await write(Ops.businessSiteEdit, {"country": "co"}) as Map;

      expect(site["country"], "CO");
      expect((await client.call(Ops.businessProfile) as Map)["country"], "CO");
    });
  });

  group('logo', () {
    Future<String> upload(String purpose) async {
      final http = HttpClient(context: master.master.context);
      addTearDown(() => http.close(force: true));
      final request = await http.openUrl("PUT", Uri.parse("https://127.0.0.1:${master.port}/f"));
      request.headers.set(HttpHeaders.authorizationHeader, "Bearer ${tokens["accessToken"]}");
      request.headers.set("X-Lyra-Purpose", purpose);
      request.add(Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]));

      return (jsonDecode(await utf8.decodeStream(await request.close())) as Map)["fileId"] as String;
    }

    test('a logo upload becomes the logo; the one it replaces is let go (B-8)', () async {
      final first = await upload("logo");
      expect((await write(Ops.businessSetLogo, {"fileId": first}) as Map)["logo"], first);

      final second = await upload("logo");
      await write(Ops.businessSetLogo, {"fileId": second});

      final rows = master.openEngine.store.db.select("SELECT id, referenced, permission FROM files ORDER BY id");
      expect({for (final row in rows) row["id"]: row["referenced"]}, {first: 0, second: 1});
      expect(rows.last["permission"], "business.view");
      expect((await write(Ops.businessSetLogo, {"fileId": null}) as Map)["logo"], isNull);
    });

    test('an upload for something else, or an unknown id, is not a logo', () async {
      await expectRefusal(write(Ops.businessSetLogo, {"fileId": await upload("picture")}), "invalid_file");
      await expectRefusal(write(Ops.businessSetLogo, {"fileId": "0192f0aa-0000-7000-8000-000000000000"}), "invalid_file");
    });
  });

  group('catalog.get', () {
    test('answers the bundled snapshot with its version (B-20, B-21)', () async {
      final answer = await client.call(Ops.catalogGet, args: {"name": "currencies"}) as Map;

      expect(answer["version"], Catalogs.version);
      expect((answer["items"] as List).map((row) => (row as Map)["code"]), containsAll(["USD", "VES", "BTC"]));
      await expectRefusal(client.call(Ops.catalogGet, args: {"name": "money.rails"}), ErrorCodes.notFound);
    });
  });
}
