import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'net_support.dart';

/// How and where the company delivers, over the LAN (`deliveries.md`): the settings, the options
/// with their carriers and reach, the areas on the map, and who may do what. The company is in
/// Venezuela, in dollars. Rule numbers name what each test checks.
void main() {
  Matcher pairs(Map<String, Object?> expected) =>
    allOf([for (final MapEntry(:key, :value) in expected.entries) containsPair(key, value)]);

  late TestMaster master;
  late RpcClient client;
  late Map<String, Object?> tokens;

  Future<Map> write(Op op, Map<String, Object?> args, {RpcClient? as, String? commandId}) async =>
    await (as ?? client).call(op, args: args, commandId: commandId ?? const Uuid().v7()) as Map;

  Future<List<Map>> options() async =>
    ((await client.call(Ops.deliveryGet) as Map)["options"] as List).cast<Map>();

  Future<List<Map>> areas() async =>
    ((await client.call(Ops.deliveryAreasList) as Map)["areas"] as List).cast<Map>();

  setUp(() async {
    master = await TestMaster.start();
    (client, tokens) = await master.signIn();
  });

  tearDown(() => master.stop());

  group('delivery.get / set', () {
    test('nothing said is three nulls and no meeting; flags and notes change one key at a time (D-1)', () async {
      expect(await client.call(Ops.deliveryGet),
        {"delivers": null, "pickup": null, "notes": null, "meeting": false, "currency": "USD", "options": []});

      await write(Ops.deliverySet, {"delivers": false});
      final settings = await write(Ops.deliverySet, {"pickup": true, "notes": "  Pedidos   antes de las 5 pm. "});
      expect(settings, pairs({"delivers": false, "pickup": true, "notes": "Pedidos antes de las 5 pm.", "meeting": false}));

      expect(await write(Ops.deliverySet, {"pickup": null, "notes": "", "meeting": true}),
        pairs({"pickup": null, "notes": null, "meeting": true}));
    });

    test('a company that lists a way to deliver has said yes, without it being written', () async {
      await write(Ops.deliveryOptionsCreate, {"mode": "own"});
      expect((await client.call(Ops.deliveryGet) as Map)["delivers"], isTrue);

      // A "no" said keeps the options, switched off.
      await write(Ops.deliverySet, {"delivers": false});
      expect(await client.call(Ops.deliveryGet), pairs({"delivers": false}));
      expect(await options(), hasLength(1));
    });

    test('refusals: a flag that isn\'t one, meeting without a third state, an unknown key, notes the cloud refuses', () async {
      await expectRefusal(write(Ops.deliverySet, {"delivers": "yes"}), "invalid_delivery_flag");
      await expectRefusal(write(Ops.deliverySet, {"meeting": null}), "invalid_delivery_flag");
      await expectRefusal(write(Ops.deliverySet, {"color": "red"}), ErrorCodes.badRequest);
      await expectRefusal(write(Ops.deliverySet, {}), ErrorCodes.badRequest);
      await expectRefusal(write(Ops.deliverySet, {"notes": "x" * 256}), ErrorCodes.invalidField);
      await expectRefusal(write(Ops.deliverySet, {"notes": "Entregas <script>"}), ErrorCodes.invalidField);
    });
  });

  group('delivery.options', () {
    test('the carriers of the company\'s country and the global ones, never another country\'s (D-2)', () async {
      final catalog = await client.call(Ops.deliveryProviders) as Map;
      final codes = [for (final row in (catalog["providers"] as List).cast<Map>()) row["code"]];

      expect(catalog, pairs({"country": "VE", "modes": ["own", "platform", "courier"],
        "coverages": ["local", "national", "international"]}));
      expect(codes, containsAll(["pedidos_ya", "yummy", "zoom", "mrw", "dhl", "fedex", "ups"]));
      expect(codes, isNot(contains("rappi")));
      expect((catalog["providers"] as List).first, {"code": "pedidos_ya", "name": "PedidosYa", "kind": "platform",
        "scope": "country", "icon": null});
    });

    test('a carrier decides the mode, a contradiction is refused; own riders name none (D-2)', () async {
      await write(Ops.deliveryOptionsCreate, {"provider": " MRW ", "fee": 500});
      expect((await options()).single, pairs({"mode": "courier", "provider": "mrw", "providerName": "MRW",
        "coverage": "national", "fee": 500}));

      await expectRefusal(write(Ops.deliveryOptionsCreate, {"mode": "platform", "provider": "zoom"}),
        "delivery_provider_mismatch");
      await expectRefusal(write(Ops.deliveryOptionsCreate, {"provider": "rappi"}), "invalid_delivery_provider");
      await expectRefusal(write(Ops.deliveryOptionsCreate, {"mode": "courier"}), "delivery_provider_required");
      await expectRefusal(write(Ops.deliveryOptionsCreate, {"mode": "bike"}), "invalid_delivery_mode");
      await expectRefusal(write(Ops.deliveryOptionsCreate, {}), "invalid_delivery_mode");

      final own = await write(Ops.deliveryOptionsCreate, {"mode": "own", "provider": "", "label": "Motorizados"});
      expect((own["options"] as List).last, pairs({"mode": "own", "provider": null, "providerName": null,
        "label": "Motorizados", "coverage": "local"}));

      // A carrier the catalogue lacks is named by its label alone.
      final named = await write(Ops.deliveryOptionsCreate, {"mode": "courier", "label": "Encomiendas Lara"});
      expect((named["options"] as List).last, pairs({"provider": null, "label": "Encomiendas Lara", "coverage": "national"}));
    });

    test('zones and radius only on a local reach; zones deduplicated by name; money in minor units (D-3, D-4, D-5)', () async {
      final settings = await write(Ops.deliveryOptionsCreate, {
        "mode": "own", "radius": 5004, "fee": 250, "freeFrom": 3000, "etaMin": 30, "etaMax": 60,
        "zones": ["Chacao", {"name": " chacáo ", "fee": 100}, {"name": "Altamira", "fee": 150}],
      });
      final option = (settings["options"] as List).single as Map;

      expect(option, pairs({"radius": 5000, "fee": 250, "freeFrom": 3000, "etaMin": 30, "etaMax": 60, "position": 100,
        "zones": [{"name": "Chacao", "fee": null}, {"name": "Altamira", "fee": 150}]}));

      final national = await write(Ops.deliveryOptionsEdit, {"id": option["id"], "coverage": "national"});
      expect((national["options"] as List).single, pairs({"coverage": "national", "radius": null, "zones": []}));
    });

    test('an edit changes what it names, null clears, the rest is checked whole (D-6)', () async {
      final created = await write(Ops.deliveryOptionsCreate, {"provider": "zoom", "fee": 800, "notes": "Ojo"});
      final id = ((created["options"] as List).single as Map)["id"];

      final edited = await write(Ops.deliveryOptionsEdit, {"id": id, "fee": null, "etaMax": 2880});
      expect((edited["options"] as List).single, pairs({"provider": "zoom", "fee": null, "etaMax": 2880, "notes": "Ojo"}));

      // Another kind of carrier is another carrier: a platform without one needs a name.
      await expectRefusal(write(Ops.deliveryOptionsEdit, {"id": id, "mode": "platform"}), "delivery_provider_required");
      final moved = await write(Ops.deliveryOptionsEdit, {"id": id, "mode": "own"});
      expect((moved["options"] as List).single, pairs({"mode": "own", "provider": null}));

      await expectRefusal(write(Ops.deliveryOptionsEdit, {"id": id, "etaMin": 3000}), "invalid_delivery_eta");
      await expectRefusal(write(Ops.deliveryOptionsEdit, {"id": id, "fee": -1}), "invalid_delivery_fee");
      await expectRefusal(write(Ops.deliveryOptionsEdit, {"id": id, "fee": 2.5}), "invalid_delivery_fee");
      await expectRefusal(write(Ops.deliveryOptionsEdit, {"id": id, "radius": 0}), "invalid_delivery_radius");
      await expectRefusal(write(Ops.deliveryOptionsEdit, {"id": id, "zones": [""]}), "invalid_delivery_zones");
      await expectRefusal(write(Ops.deliveryOptionsEdit, {"id": id, "coverage": "galaxy"}), "invalid_delivery_coverage");
      await expectRefusal(write(Ops.deliveryOptionsEdit, {"id": id, "position": 70000}), "invalid_order");
      await expectRefusal(write(Ops.deliveryOptionsEdit, {"id": id, "label": "Envíos <rápidos>"}), ErrorCodes.invalidField);
      await expectRefusal(write(Ops.deliveryOptionsEdit, {"id": "nope", "fee": 1}), ErrorCodes.notFound);

      await write(Ops.deliveryOptionsRemove, {"id": id});
      expect(await options(), isEmpty);
      await expectRefusal(write(Ops.deliveryOptionsRemove, {"id": id}), ErrorCodes.notFound);
    });

    test('in position order, at most 20 (D-11), and a retried create adds once', () async {
      final commandId = const Uuid().v7();
      await write(Ops.deliveryOptionsCreate, {"mode": "own", "position": 5}, commandId: commandId);
      await write(Ops.deliveryOptionsCreate, {"mode": "own", "position": 5}, commandId: commandId);
      await write(Ops.deliveryOptionsCreate, {"mode": "own", "label": "Primero", "position": 1});

      expect([for (final option in await options()) option["position"]], [1, 5]);

      for (var i = 2; i < Deliveries.maxOptions; i++) {
        await write(Ops.deliveryOptionsCreate, {"mode": "own"});
      }
      await expectRefusal(write(Ops.deliveryOptionsCreate, {"mode": "own"}), "delivery_options_limit");
    });
  });

  group('delivery.areas', () {
    const outline = [[10.5, -66.9], [10.5, -66.8], [10.4, -66.8], [10.4, -66.9], [10.5, -66.9]];

    test('a circle or an outline, each keeping only its own shape; points at six decimals (D-10)', () async {
      await write(Ops.deliveryAreasCreate, {"name": "Centro", "kind": "radius", "latitude": 10.4880001234,
        "longitude": -66.8791, "radius": 3000, "fee": 200, "polygon": outline});
      await write(Ops.deliveryAreasCreate, {"name": "Este", "kind": "polygon", "polygon": outline, "minimum": 1000,
        "position": 1});

      final list = await client.call(Ops.deliveryAreasList) as Map;
      expect(list["currency"], "USD");
      final [east, center] = (list["areas"] as List).cast<Map>();

      expect(center, pairs({"name": "Centro", "kind": "radius", "latitude": 10.488, "longitude": -66.8791,
        "radius": 3000, "polygon": [], "fee": 200, "minimum": null, "active": true}));
      // The closing point is dropped: an outline is open.
      expect(east, pairs({"kind": "polygon", "latitude": null, "radius": null, "minimum": 1000, "polygon": [
        [10.5, -66.9], [10.5, -66.8], [10.4, -66.8], [10.4, -66.9],
      ]}));

      final circle = await write(Ops.deliveryAreasEdit, {"id": east["id"], "kind": "radius", "latitude": 10.45,
        "longitude": -66.85, "radius": 1000});
      expect(((circle["areas"] as List).first as Map), pairs({"kind": "radius", "polygon": []}));
    });

    test('paused alone and back; removed for good (D-13)', () async {
      final created = await write(Ops.deliveryAreasCreate, {"name": "Centro", "kind": "radius", "latitude": 10.48,
        "longitude": -66.87, "radius": 3000});
      final id = ((created["areas"] as List).single as Map)["id"];

      expect(((await write(Ops.deliveryAreasEdit, {"id": id, "active": false}))["areas"] as List).single,
        pairs({"active": false, "radius": 3000}));
      expect(((await write(Ops.deliveryAreasEdit, {"id": id, "active": null}))["areas"] as List).single,
        pairs({"active": true}));

      await write(Ops.deliveryAreasRemove, {"id": id});
      expect(await areas(), isEmpty);
    });

    test('refusals: no name, no shape, a half point, too few or too many points, at most 20 (D-10, D-11)', () async {
      await expectRefusal(write(Ops.deliveryAreasCreate, {"kind": "radius"}), ErrorCodes.required);
      await expectRefusal(write(Ops.deliveryAreasCreate, {"name": " ", "kind": "radius"}), ErrorCodes.required);
      await expectRefusal(write(Ops.deliveryAreasCreate, {"name": "A"}), "invalid_delivery_area_kind");
      await expectRefusal(write(Ops.deliveryAreasCreate, {"name": "A", "kind": "radius", "radius": 100}),
        "invalid_delivery_area_center");
      await expectRefusal(write(Ops.deliveryAreasCreate, {"name": "A", "kind": "radius", "latitude": 91, "longitude": 0,
        "radius": 100}), "invalid_delivery_area_center");
      await expectRefusal(write(Ops.deliveryAreasCreate, {"name": "A", "kind": "radius", "latitude": 10, "longitude": 0}),
        "invalid_delivery_radius");
      await expectRefusal(write(Ops.deliveryAreasCreate, {"name": "A", "kind": "polygon", "polygon": outline.take(2).toList()}),
        "invalid_delivery_area_polygon");
      await expectRefusal(write(Ops.deliveryAreasCreate, {"name": "A", "kind": "polygon",
        "polygon": [for (var i = 0; i < 251; i++) [10 + i / 1000, -66.0]]}), "invalid_delivery_area_polygon");
      await expectRefusal(write(Ops.deliveryAreasCreate, {"name": "A", "kind": "polygon", "polygon": outline,
        "fee": -5}), "invalid_delivery_fee");

      for (var i = 0; i < Deliveries.maxAreas; i++) {
        await write(Ops.deliveryAreasCreate, {"name": "A$i", "kind": "polygon", "polygon": outline});
      }
      await expectRefusal(write(Ops.deliveryAreasCreate, {"name": "B", "kind": "polygon", "polygon": outline}),
        "delivery_areas_limit");
    });
  });

  test('each op asks for its cloud route\'s key: reading is delivery, writes create, edit and delete', () async {
    final account = tokens["accountId"] as String;
    final option = ((await write(Ops.deliveryOptionsCreate, {"mode": "own"}))["options"] as List).single as Map;

    grantKeys(master.openEngine, account, ["delivery"]);
    final (reader, _) = await master.signIn();
    await reader.call(Ops.deliveryGet);
    await reader.call(Ops.deliveryProviders);
    await reader.call(Ops.deliveryAreasList);
    await expectRefusal(write(Ops.deliverySet, {"pickup": true}, as: reader), ErrorCodes.forbidden);
    await expectRefusal(write(Ops.deliveryOptionsCreate, {"mode": "own"}, as: reader), ErrorCodes.forbidden);

    grantKeys(master.openEngine, account, ["delivery", "delivery.edit"]);
    final (editor, _) = await master.signIn();
    await write(Ops.deliveryOptionsEdit, {"id": option["id"], "fee": 100}, as: editor);
    await expectRefusal(write(Ops.deliveryOptionsRemove, {"id": option["id"]}, as: editor), ErrorCodes.forbidden);
    await expectRefusal(write(Ops.deliveryAreasCreate, {"name": "A", "kind": "radius"}, as: editor), ErrorCodes.forbidden);

    grantKeys(master.openEngine, account, []);
    final (nobody, _) = await master.signIn();
    await expectRefusal(nobody.call(Ops.deliveryGet), ErrorCodes.forbidden);
  });
}
