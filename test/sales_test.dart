import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'net_support.dart';

/// The sales board over the LAN (`sales.md`): POS invoices measured into stages, the handover, the
/// detail, and who sees which sales. Rule numbers name what each test checks.
void main() {
  Matcher pairs(Map<String, Object?> expected) =>
    allOf([for (final MapEntry(:key, :value) in expected.entries) containsPair(key, value)]);

  late TestMaster master;
  late RpcClient client;
  late Map<String, Object?> tokens;
  late String tableId;
  late String cafe;

  Future<Object?> write(Op op, Map<String, Object?> args, {RpcClient? as}) =>
    (as ?? client).call(op, args: args, commandId: const Uuid().v7());

  /// A charged ticket of one café, or an open invoice with [close] false.
  Future<Map> sale({bool close = true, int units = 1}) async {
    final invoice = await write(Ops.posInvoicesOpen, {"tax": 16}) as Map;
    await write(Ops.posInvoicesLine, {"id": invoice["id"], "productId": cafe, "add": units});
    if (!close) return invoice;

    return await write(Ops.posInvoicesClose, {"id": invoice["id"], "method": "transfer", "reference": "0099"}) as Map;
  }

  Future<Map> board(String section, [Map<String, Object?> args = const {}, RpcClient? as]) async =>
    await (as ?? client).call(Ops.salesList, args: {"section": section, ...args}) as Map;

  List<Object?> stages(Map page) => [for (final row in (page["sales"] as List).cast<Map>()) row["stage"]];

  Future<Map> fulfil(String id, Map<String, Object?> args) async =>
    await write(Ops.salesFulfil, {"id": id, ...args}) as Map;

  void grant(String account, List<String> permissions) => master.openEngine.store.write((db) {
    db.execute("DELETE FROM grants WHERE account = ?", [account]);
    for (final permission in permissions) {
      db.execute("INSERT INTO grants (account, permission) VALUES (?, ?)", [account, permission]);
    }
  });

  /// Files [invoice] as sold by another person, who has no session here.
  void soldByAnother(String invoice) => master.openEngine.store.write((db) {
    db.execute(
      "INSERT OR IGNORE INTO accounts (id, username, first_name, last_name, status, created, created_hlc, updated_hlc) "
      "VALUES ('other', 'other', 'Otra', 'Persona', 'active', '2026-01-01', '0', '0')",
    );
    db.execute("UPDATE pos_invoices SET seller = 'other' WHERE id = ?", [invoice]);
  });

  setUp(() async {
    master = await TestMaster.start();
    (client, tokens) = await master.signIn();

    tableId = (await write(Ops.inventoryTablesCreate, {"title": "Products", "color": "0xFF60A5FA", "template": "FOOD"})
      as Map)["id"] as String;
    final structure = await client.call(Ops.inventoryTablesStructure, args: {"id": tableId}) as Map;
    final rows = ((structure["fields"] as Map)["values"] as List).cast<List>();
    String of(String type) => rows.firstWhere((field) => field[2] == type)[0] as String;

    cafe = (await write(Ops.inventoryRecordsCreate, {
      "tableId": tableId,
      "data": {of("TITLE"): "Café", of("SKU"): "C-1", of("PRICE"): "2.50"},
    }) as Map)["id"] as String;
    await write(Ops.stockMove, {"operation": "add", "tableId": tableId, "productId": cafe, "quantity": 20});
  });

  tearDown(() => master.stop());

  group('sales.list', () {
    test('the catalogue offline: only what a master measures, in the company\'s language (SA-2)', () async {
      final catalog = await client.call(Ops.salesCatalog) as Map;

      expect([for (final stage in (catalog["stages"] as List).cast<Map>()) stage["stage"]],
        ["open", "shipping", "handover", "transit", "pickup", "completed"]);
      expect((catalog["stages"] as List).first, containsPair("name", "Ticket abierto"));
      expect((catalog["handover"] as List).map((mode) => (mode as Map)["mode"]), ["immediate", "pickup", "delivery"]);
      expect(catalog["channels"], [{"channel": "pos", "name": "Punto de venta", "default": true}]);
    });

    test('an open invoice is in process, a charged one done, a cancelled one nowhere (sources, stages)', () async {
      final open = await sale(close: false);
      final ticket = await sale(units: 2);
      final cancelled = await sale(close: false);
      await write(Ops.posInvoicesCancel, {"id": cancelled["id"]});

      final process = await board("process");
      final done = await board("done");

      expect(process["total"], 1);
      expect((process["sales"] as List).single, pairs({
        "id": open["id"], "source": "invoice", "stage": "open", "label": "Ticket abierto", "attention": true,
        "mode": null,
      }));
      expect((process["sales"] as List).single, isNot(contains("section")));

      final row = (done["sales"] as List).single as Map;
      expect(row, pairs({
        "ticket": ticket["ticket"], "source": "ticket", "stage": "completed", "level": "success", "units": 2,
        "total": 580, "currency": "USD", "method": "transfer", "mode": "immediate", "state": "done",
        "channel": "pos", "customer": null, "outstanding": null,
      }));
      expect(row["seller"], isNotEmpty);
      expect(row["since"], ticket["closed"]);
    });

    test('attention first, then the oldest; a stage names its section; another channel is empty (SA-12)', () async {
      final first = await sale();
      final second = await sale();
      final open = await sale(close: false);
      await fulfil(first["id"], {"mode": "delivery", "state": "dispatched"});
      await fulfil(second["id"], {"mode": "pickup"});

      expect(stages(await board("process")), ["open", "transit", "pickup"]);
      expect(stages(await board("process", {"size": 1, "page": 2})), ["transit"]);
      expect((await board("process", {"size": 1}))["total"], 3);

      final transit = await board("done", {"stage": "transit"});
      expect(transit["section"], "process");
      expect(transit["total"], 1);
      expect(((transit["sales"] as List).single as Map)["id"], first["id"]);

      expect((await board("process", {"stage": "verifying"}))["total"], 0);
      expect((await board("process", {"channel": "whatsapp"}))["sales"], isEmpty);
      expect(((await board("process", {"channel": "pos"}))["sales"] as List).first, containsPair("id", open["id"]));
      await expectRefusal(board("process", {"stage": "lost"}), ErrorCodes.invalidField);
      await expectRefusal(board("later"), ErrorCodes.invalidField);
    });
  });

  group('sales.fulfil', () {
    test('a mode alone opens it, the state moves it, done closes the sale (SA-20 to SA-24)', () async {
      final ticket = await sale();

      var row = await fulfil(ticket["id"], {"mode": "delivery", "note": "Calle 4"});
      expect(row, pairs({"stage": "shipping", "state": "pending", "section": "process"}));

      row = await fulfil(ticket["id"], {"state": "dispatched", "note": "  "});
      expect(row, pairs({"stage": "transit", "label": "En camino"}));

      row = await fulfil(ticket["id"], {"state": "done"});
      expect(row, pairs({"stage": "completed", "section": "done"}));

      final detail = await client.call(Ops.salesDetail, args: {"reference": ticket["id"]}) as Map;
      expect(detail["fulfillment"], pairs({
        "mode": "delivery", "modeName": "Envío a domicilio", "stateName": "Entregado", "note": "Calle 4",
        "stored": true,
      }));
      expect((detail["fulfillment"] as Map)["by"], row["seller"]);

      // Naming the mode again starts it over.
      row = await fulfil(ticket["id"], {"mode": "delivery"});
      expect(row["state"], "pending");
    });

    test('refusals: an open invoice, nothing named, a step its mode lacks, no such sale (SA-20 to SA-22)', () async {
      final open = await sale(close: false);
      final ticket = await sale();

      await expectRefusal(fulfil(open["id"], {"mode": "pickup"}), "not_a_ticket");
      await expectRefusal(fulfil(ticket["id"], {"note": "x"}), "nothing_to_change");
      await expectRefusal(fulfil(ticket["id"], {"mode": "pickup", "state": "dispatched"}), "invalid_state");
      await expectRefusal(fulfil(ticket["id"], {"mode": "teleport"}), "invalid_state");
      await expectRefusal(fulfil(ticket["id"], {"state": "pending"}), "invalid_state");
      await expectRefusal(fulfil("nope", {"mode": "pickup"}), "sale_not_found");
      // A ticket code addresses the detail, not the write.
      await expectRefusal(fulfil(ticket["ticket"], {"mode": "pickup"}), "sale_not_found");
    });
  });

  group('sales.detail', () {
    test('an open invoice: its holds, what each line holds and what is left (SA-31, SA-32, SA-34)', () async {
      final open = await sale(close: false, units: 3);

      final code = (open["ticket"] as String).toLowerCase();
      final detail = await client.call(Ops.salesDetail, args: {"reference": code}) as Map;
      final item = (detail["items"] as List).single as Map;

      expect(detail, pairs({
        "source": "invoice", "status": "open", "stage": "open", "fulfillment": null, "held": 3, "subtotal": 750,
        "tax": 120, "total": 870,
      }));
      expect(item, pairs({"held": 3, "state": "reserved", "available": 17, "gone": false, "taxRate": "16"}));
      expect((detail["reservations"] as List).single, pairs({"productId": cafe, "qty": 3, "status": "pending"}));
      expect(detail["origin"], {"kind": "pos", "channel": "pos", "terminal": isNotEmpty});
    });

    test('a ticket: no holds list, its payment without proofs, a deleted product is gone (SA-31 to SA-35)', () async {
      final ticket = await sale();
      await write(Ops.inventoryRecordsDelete, {"tableId": tableId, "id": cafe});

      final detail = await client.call(Ops.salesDetail, args: {"reference": ticket["ticket"]}) as Map;

      expect(detail, pairs({
        "source": "ticket", "status": "completed", "reservations": null, "held": 0, "customer": null,
      }));
      expect(detail["payment"], pairs({
        "method": "transfer", "name": "Transferencia", "reference": "0099", "credit": false, "proofs": isEmpty,
      }));
      expect(detail["fulfillment"], pairs({"mode": "immediate", "stored": false}));
      expect((detail["items"] as List).single, pairs({"gone": true, "state": ""}));

      await expectRefusal(client.call(Ops.salesDetail, args: {"reference": "Z-000001"}), "sale_not_found");
    });
  });

  group('who sees which sales', () {
    test('without view_all only one\'s own: the list, the detail, the write and the notices (SA-11, SA-13)', () async {
      final mine = await sale();
      final theirs = await sale(close: false);
      soldByAnother(theirs["id"] as String);

      final account = tokens["accountId"] as String;
      grant(account, ["sales.view", "sales.process.view", "sales.fulfil"]);
      final (seller, _) = await master.signIn();

      final events = <RpcEvent>[];
      final subscription = seller.events.listen(events.add);
      addTearDown(subscription.cancel);
      await seller.call(Ops.eventsSubscribe);

      expect((await board("process", const {}, seller))["total"], 0);
      expect((await board("process"))["total"], 1);
      await expectRefusal(board("done", const {}, seller), ErrorCodes.forbidden);
      await expectRefusal(seller.call(Ops.salesDetail, args: {"reference": theirs["ticket"]}), "sale_not_found");
      await expectRefusal(write(Ops.salesFulfil, {"id": theirs["id"], "mode": "pickup"}, as: seller), "sale_not_found");

      // The owner's first session keeps every grant: it writes on both.
      await write(Ops.posInvoicesLine, {"id": theirs["id"], "productId": cafe, "add": 1});
      await fulfil(mine["id"], {"mode": "pickup"});
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final progress = [for (final event in events) if (event.event == Events.saleProgress) event.data as Map];
      expect(progress, [
        {
          "id": mine["id"], "source": "ticket", "ticket": mine["ticket"], "chat": null, "stage": "pickup",
          "label": "Listo para retirar", "section": "process", "level": "info", "attention": false,
          "since": progress.single["since"],
        },
      ]);
      expect((await board("process", const {}, seller))["total"], 1);
    });

    test('a cancelled invoice leaves both lists: its notice has no section (sales.md, events)', () async {
      final events = <RpcEvent>[];
      final subscription = client.events.listen(events.add);
      addTearDown(subscription.cancel);
      await client.call(Ops.eventsSubscribe);

      final invoice = await sale(close: false);
      await write(Ops.posInvoicesCancel, {"id": invoice["id"]});
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final progress = [for (final event in events) if (event.event == Events.saleProgress) event.data as Map];
      expect(progress.map((notice) => notice["stage"]), ["open", "open", null]);
      expect(progress.last, containsPair("section", null));
      expect(progress.last.keys, containsAll(["label", "level", "attention", "since"]));
    });
  });
}
