import 'dart:convert';

import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support.dart';
import 'support/edge_cloud.dart';

/// The edge sync (plan §9, `task-edge-sync-backend.md`) against the in-memory backend: the first
/// link both ways, the live push and pull, the stamp per field and the conflicts inbox, retries,
/// revocation, the allowance and the clock.
void main() {
  late Engine engine;
  late EdgeCloud cloud;
  late String owner;
  late String device;
  var now = DateTime.now();

  Database db() => engine.store.db;

  setUp(() async {
    now = DateTime.now();
    final paths = tempPaths(addTearDown);
    final vault = MemoryVault();
    await setUpMaster(paths, vault);
    engine = await Engine.open(paths: paths, vault: vault, hasher: fastHasher, now: () => now);
    addTearDown(engine.close);

    owner = (await engine.accounts.verifyPassword("ada.owner", "correct horse battery")).id;
    cloud = EdgeCloud();
  });

  /// Links the company and enrolls the master, as the app does with the owner's session.
  Future<void> enroll() async {
    engine.business.link(cloud.company, actor: owner);
    final enrolment = cloud.enroll(engine.instanceId, await engine.edge.prepare());
    device = enrolment.device;
    engine.edge.enroll(enrolment);
  }

  Future<SyncReport> cycle() => engine.edge.cycle(cloud);

  /// A FOOD table (title, SKU, price, stock, photos…) and its field ids by type.
  ({String table, Map<String, String> fields}) foodTable() {
    final table = engine.inventory.createTable({"title": "Pantry", "color": "0xFF60A5FA", "template": "FOOD"}, actor: owner)["id"] as String;
    final fields = {
      for (final row in db().select("SELECT id, type FROM inventory_fields WHERE table_id = ?", [table]))
        row["type"] as String: row["id"] as String,
    };

    return (table: table, fields: fields);
  }

  String product(({String table, Map<String, String> fields}) food, String name, {String? sku}) =>
    engine.inventory.createRecord(food.table, {
      food.fields[FieldTypes.title]!: name,
      food.fields[FieldTypes.sku]!: ?sku,
    }, decimals: 2, actor: owner)["id"] as String;

  Map<String, Object?> cells(String product) =>
    jsonDecode(db().select("SELECT data FROM inventory_records WHERE id = ?", [product]).first["data"] as String) as Map<String, Object?>;

  Future<void> later() => Future<void>.delayed(const Duration(milliseconds: 3));

  group('enrolment', () {
    test('the key is made once and kept until the enrolment takes it', () async {
      final key = await engine.edge.prepare();
      expect(await engine.edge.prepare(), key);
      expect(base64.decode(key), hasLength(32));
      expect(engine.edge.enrolled, isFalse);
      expect((await cycle()).skipped, "not_enrolled");
    });

    test('only for the cloud company this master is linked to', () async {
      await engine.edge.prepare();
      final answer = cloud.enroll(engine.instanceId, await engine.edge.prepare());

      expect(() => engine.edge.enroll(answer), throwsA(isA<EngineFailure>().having((f) => f.code, "code", "not_linked")));
      engine.business.link("another-company", actor: owner);
      expect(() => engine.edge.enroll(answer), throwsA(isA<EngineFailure>().having((f) => f.code, "code", "company_mismatch")));
    });

    test("a backend answer that isn't one is refused", () {
      expect(
        () => EdgeEnrolment.fromJson({"device": "d", "company": "c", "site": "s", "endpoint": "http://plain.test",
          "edgeKey": {"kid": "k", "publicKey": EdgeCloud.edgeKey}}),
        throwsA(isA<EngineFailure>()),
      );
    });

    test('pins the edge key and starts by downloading', () async {
      await enroll();

      expect(engine.edge.status(), containsPair("phase", SyncPhase.download));
      expect(engine.edge.edgeKeys.single, {"kid": "2026-10", "publicKey": EdgeCloud.edgeKey});
    });
  });

  group('the first link', () {
    test("the master's data goes up whole, with the cloud ids learnt; nothing twice", () async {
      final food = foodTable();
      final rice = product(food, "Rice", sku: "R-1");
      engine.stock.move(operation: "add", tableId: food.table, productId: rice, quantity: 10, actor: owner);
      final payment = engine.finance.record(
        {"concept": "supplier", "amount": 2500, "method": "cash", "date": "2026-09-30"}, actor: owner)["id"] as String;
      await enroll();

      final report = await cycle();
      expect(report.ok, isTrue, reason: "$report");
      expect(engine.edge.status(), containsPair("phase", SyncPhase.live));

      final cloudRice = cloud.cloudIdOf(device, "product", rice)!;
      final cloudTitle = cloud.cloudIdOf(device, "product_field", food.fields[FieldTypes.title]!)!;
      expect(cloud.record("product", cloudRice)!.cells[cloudTitle], "Rice");
      expect(cloud.record("product", cloudRice)!.fields["table"], cloud.cloudIdOf(device, "product_table", food.table));
      expect(cloud.record("company", cloud.company)!.fields["name"], "Lovelace Café");
      expect(cloud.ids("stock_movement"), hasLength(1));
      expect(cloud.record("payment", cloud.cloudIdOf(device, "payment", payment)!)!.fields["amount"], 2500);
      // Image cells name files, which don't travel yet.
      expect(cloud.ids("product_field").length, food.fields.length);

      final applied = cloud.applied;
      expect((await cycle()).pushed, 0);
      expect(cloud.applied, applied);
    });

    test("a master made from the cloud company gets the cloud's data first", () async {
      final table = cloud.create("product_table", {"name": "Drinks", "color": "0xFF000000", "primary": false});
      final title = cloud.create("product_field", {"table": table, "name": "Name", "type": FieldTypes.title, "position": 0});
      cloud.create("product", {"table": table}, cells: {title: "Lemonade"});
      cloud.edit("company", cloud.company, fields: {"caption": "From the cloud"});
      await enroll();

      final report = await cycle();
      expect(report.pulled, 4, reason: "$report");
      expect(engine.business.profile(owner: true)["caption"], "From the cloud");

      final local = db().select("SELECT id, data FROM inventory_records").single;
      final field = db().select("SELECT id FROM inventory_fields WHERE name = 'Name'").single["id"];
      expect(jsonDecode(local["data"] as String), {field: "Lemonade"});
      // What came down isn't sent back up.
      expect(cloud.ids("product"), hasLength(1));
    });
  });

  group('live', () {
    test('an edit here sends only what changed; an edit there comes down', () async {
      final food = foodTable();
      final rice = product(food, "Rice", sku: "R-1");
      await enroll();
      await cycle();

      final title = food.fields[FieldTypes.title]!;
      engine.inventory.editRecord(food.table, rice, {title: "Brown rice"}, decimals: 2, actor: owner);
      expect((await cycle()).pushed, 1);

      final cloudRice = cloud.cloudIdOf(device, "product", rice)!;
      final cloudTitle = cloud.cloudIdOf(device, "product_field", title)!;
      final cloudSku = cloud.cloudIdOf(device, "product_field", food.fields[FieldTypes.sku]!)!;
      expect(cloud.record("product", cloudRice)!.cells, containsPair(cloudTitle, "Brown rice"));

      await later();
      cloud.edit("product", cloudRice, cells: {cloudSku: "R-2"});
      final beans = cloud.create("product", {"table": cloud.cloudIdOf(device, "product_table", food.table)}, cells: {cloudTitle: "Beans"});

      final report = await cycle();
      expect(report.pulled, 2);
      expect(report.pushed, 0, reason: "a pulled change isn't pushed back");
      expect(cells(rice), containsPair(food.fields[FieldTypes.sku]!, "R-2"));
      expect(cells(rice), containsPair(title, "Brown rice"));
      expect(db().select("SELECT 1 FROM inventory_records WHERE data LIKE '%Beans%'"), hasLength(1));
      expect(engine.oplog.since(0).last.device, edgeOrigin);
      expect(cloud.ids("product"), contains(beans));
      expect(cloud.ids("product"), hasLength(2));
    });

    test('a table made here goes up with its fields; a field made there comes down', () async {
      await enroll();
      await cycle();

      final food = foodTable();
      await cycle();
      final cloudTable = cloud.cloudIdOf(device, "product_table", food.table)!;
      expect(cloud.ids("product_field").length, food.fields.length);

      cloud.create("product_field", {"table": cloudTable, "name": "Origin", "type": FieldTypes.text, "position": 9});
      await cycle();
      expect(db().select("SELECT name FROM inventory_fields WHERE table_id = ? AND name = 'Origin'", [food.table]), hasLength(1));
    });

    test("a movement made in the cloud moves the master's balance, flagged when it goes negative", () async {
      final food = foodTable();
      final rice = product(food, "Rice");
      await enroll();
      await cycle();

      cloud.append("stock_movement", {
        "product": cloud.cloudIdOf(device, "product", rice), "table": cloud.cloudIdOf(device, "product_table", food.table),
        "operation": "remove", "quantity": 2, "source": "whatsapp",
      });
      await cycle();

      final balance = engine.stock.balanceOf(rice);
      expect(balance["onHand"], -2);
      expect(balance["needsReview"], isTrue);
      expect(db().select("SELECT source FROM stock_movements").single["source"], Stock.cloudSource);
    });

    test('a payment voided here is voided there; one recorded there is recorded here', () async {
      await enroll();
      await cycle();

      final payment = engine.finance.record(
        {"concept": "supplier", "amount": 2500, "method": "cash", "date": "2026-09-30"}, actor: owner)["id"] as String;
      await cycle();
      engine.finance.voidPayment(payment, reason: "Typo", actor: owner);
      await cycle();
      expect(cloud.record("payment", cloud.cloudIdOf(device, "payment", payment)!)!.voided, isTrue);

      cloud.append("payment", {"concept": "sale", "direction": "in", "amount": 900, "currency": "USD", "method": "cash",
        "date": "2026-09-30"});
      await cycle();
      expect(db().select("SELECT amount FROM money_payments WHERE registered_by = ?", [edgeOrigin]).single["amount"], 900);
    });
  });

  group('the same field on both sides', () {
    late ({String table, Map<String, String> fields}) food;
    late String rice;
    late String cloudRice;
    late String cloudTitle;

    setUp(() async {
      food = foodTable();
      rice = product(food, "Rice");
      await enroll();
      await cycle();
      cloudRice = cloud.cloudIdOf(device, "product", rice)!;
      cloudTitle = cloud.cloudIdOf(device, "product_field", food.fields[FieldTypes.title]!)!;
    });

    test('the newer stamp wins on both sides, and the other value goes to the inbox', () async {
      engine.inventory.editRecord(food.table, rice, {food.fields[FieldTypes.title]!: "Rice (master)"}, decimals: 2, actor: owner);
      await later();
      cloud.edit("product", cloudRice, cells: {cloudTitle: "Rice (cloud)"});

      final report = await cycle();
      expect(report.conflicts, 1);
      expect(cells(rice)[food.fields[FieldTypes.title]!], "Rice (cloud)");
      expect(cloud.record("product", cloudRice)!.cells[cloudTitle], "Rice (cloud)");

      final conflict = engine.edge.conflicts().single;
      expect(conflict, containsPair("keptSide", "cloud"));
      expect(conflict, containsPair("lost", "Rice (master)"));

      // Putting it back is a new edit, which goes up like any other.
      engine.edge.resolve(conflict["id"] as String, restore: true, actor: owner);
      await cycle();
      expect(cells(rice)[food.fields[FieldTypes.title]!], "Rice (master)");
      expect(cloud.record("product", cloudRice)!.cells[cloudTitle], "Rice (master)");
      expect(engine.edge.conflicts(), isEmpty);
    });

    test('a cloud edit older than the one here loses on both sides', () async {
      final stale = cloud.clock.tick();
      await later();
      engine.inventory.editRecord(food.table, rice, {food.fields[FieldTypes.title]!: "Rice (master)"}, decimals: 2, actor: owner);
      cloud.edit("product", cloudRice, cells: {cloudTitle: "Rice (cloud, earlier)"}, at: stale);

      expect((await cycle()).conflicts, 1);
      expect(cloud.record("product", cloudRice)!.cells[cloudTitle], "Rice (master)");
      expect(cells(rice)[food.fields[FieldTypes.title]!], "Rice (master)");
      expect(engine.edge.conflicts().single, containsPair("keptSide", "master"));
    });

    test('an edit already agreed is no conflict', () async {
      engine.inventory.editRecord(food.table, rice, {food.fields[FieldTypes.title]!: "Rice 1"}, decimals: 2, actor: owner);
      await cycle();
      await later();
      cloud.edit("product", cloudRice, cells: {cloudTitle: "Rice 2"});

      expect((await cycle()).conflicts, 0);
      expect(cells(rice)[food.fields[FieldTypes.title]!], "Rice 2");
    });

    test('a delete older than an edit here waits for it', () async {
      final stamp = cloud.clock.tick();
      await later();
      engine.inventory.editRecord(food.table, rice, {food.fields[FieldTypes.title]!: "Rice, kept"}, decimals: 2, actor: owner);
      cloud.delete("product", cloudRice, at: stamp);

      final report = await cycle();
      expect(db().select("SELECT deleted FROM inventory_records WHERE id = ?", [rice]).single["deleted"], 0);
      expect(report.conflicts, 1);
      expect(engine.edge.conflicts().single["field"], "_deleted");
    });

    test('a delete newer than every edit deletes', () async {
      await later();
      cloud.delete("product", cloudRice);
      await cycle();

      expect(db().select("SELECT deleted FROM inventory_records WHERE id = ?", [rice]).single["deleted"], 1);
    });
  });

  group('failures', () {
    test('a batch whose answer was lost is sent again and applied once', () async {
      await enroll();
      await cycle();

      engine.finance.record({"concept": "supplier", "amount": 100, "method": "cash", "date": "2026-09-30"}, actor: owner);
      cloud.answersLost = 1;
      expect((await cycle()).error, "unreachable");
      expect(engine.edge.status(), containsPair("pending", greaterThan(0)));

      expect((await cycle()).ok, isTrue);
      expect(cloud.ids("payment"), hasLength(1));
      expect(engine.edge.status(), containsPair("pending", 0));
    });

    test("a change the cloud refuses is kept for the owner and not sent again", () async {
      await enroll();
      cloud.refuse = (change) => change["entity"] == "payment" ? "currency_unknown" : null;
      engine.finance.record({"concept": "supplier", "amount": 100, "method": "cash", "date": "2026-09-30"}, actor: owner);

      expect((await cycle()).rejected, 1);
      expect(db().select("SELECT reason, direction FROM sync_rejected").single, {"reason": "currency_unknown", "direction": "push"});
      expect((await cycle()).rejected, 0);
    });

    test('a pulled change naming something unknown is refused, the rest applied', () async {
      final food = foodTable();
      await enroll();
      await cycle();

      cloud.create("product", {"table": "c-nothing"});
      cloud.edit("company", cloud.company, fields: {"caption": "Still applied"});
      final report = await cycle();

      expect(report.rejected, 1);
      expect(engine.business.profile(owner: true)["caption"], "Still applied");
      expect(db().select("SELECT count(*) AS n FROM inventory_records WHERE table_id = ?", [food.table]).single["n"], 0);
    });

    test('a revoked master stops', () async {
      await enroll();
      await cycle();
      cloud.revoke(device);

      expect((await cycle()).error, "edge_revoked");
      expect(engine.edge.status(), containsPair("revoked", true));
      expect((await cycle()).skipped, "revoked");
    });

    test('past the allowance it pauses, asks again after an hour, and resumes without losing a change', () async {
      await enroll();
      await cycle();

      cloud.allowance = EdgeAllowance.exceeded;
      engine.business.edit({"caption": "Made while paused"}, owner: true, actor: owner);
      expect((await cycle()).error, "allowance_exceeded");
      expect((await cycle()).skipped, "allowance_exceeded");

      cloud.allowance = EdgeAllowance.subscribed;
      now = now.add(const Duration(hours: 2));
      expect((await cycle()).ok, isTrue);
      expect(cloud.record("company", cloud.company)!.fields["caption"], "Made while paused");
      expect(engine.edge.status(), containsPair("allowance", EdgeAllowance.subscribed));
    });

    test('a cloud stamp far in the future stops the pull and writes nothing', () async {
      await enroll();
      await cycle();

      final future = Hlc(DateTime.now().add(const Duration(hours: 3)).millisecondsSinceEpoch, 0, "cloud");
      cloud.edit("company", cloud.company, fields: {"caption": "From the future"}, at: future);

      expect((await cycle()).error, "clock_drift");
      expect(engine.business.profile(owner: true)["caption"], isNot("From the future"));
    });

    test("an error in the API's shape, not the edge's, is reported by its status", () async {
      await enroll();
      final report = await engine.edge.cycle(_Answering(EdgeResponse(404, {"code": 404, "message": "Not found"})));

      expect(report.error, "http_404");
      expect(engine.edge.status(), containsPair("revoked", false));
    });

    test('a request whose body was changed on the way fails its signature', () async {
      final pair = await EdgeSigner.generate();
      final signer = await EdgeSigner.fromSeed("d-1", pair.seed);
      final publicKey = pair.publicKey;
      final request = await signer.sign("POST", "/edge/v1/commands", {"changes": []});

      expect(await EdgeSigner.verify(request, publicKey), isTrue);
      final tampered = EdgeRequest(request.method, request.path, utf8.encode('{"changes":[1]}'), request.headers);
      expect(await EdgeSigner.verify(tampered, publicKey), isFalse);
      final moved = EdgeRequest(request.method, "/edge/v1/changes", request.body, request.headers);
      expect(await EdgeSigner.verify(moved, publicKey), isFalse);
    });
  });
}

/// A backend that answers every call the same.
final class _Answering implements EdgeTransport {
  _Answering(this.answer);

  final EdgeResponse answer;

  @override
  Future<EdgeResponse> send(EdgeRequest request) async => answer;
}
