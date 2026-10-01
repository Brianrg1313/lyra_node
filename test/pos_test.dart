import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'net_support.dart';

/// The counter over the LAN (`pos.md`): the catalogue read by field type, the ticket and its holds,
/// checkout, cancel, codes and events. Rule numbers name what each test checks.
void main() {
  group('money', () {
    test('minor units, percents and rounding half away from zero, once per line (README, POS-7, POS-20)', () {
      expect(Money.minor("22.5", 2), 2250);
      expect(Money.minor("22.505", 2), 2251);
      expect(Money.minor("1500", 0), 1500);
      expect(Money.minor("abc", 2), isNull);

      expect(Money.percent(16), "16");
      expect(Money.percent(7.5), "7.5");
      expect(Money.percent("12.50"), "12.5");
      expect(Money.percent(16.0), "16");
      expect(Money.percent("100.5"), isNull);
      expect(Money.percent(-1), isNull);

      expect(Money.percentOf(1005, "16"), 161);
      expect(Money.percentOf(1, "50"), 1);
      expect(Money.percentOf(333, "7.5"), 25);
      expect(Money.discounted(999, "15"), 849);
      expect(Money.discounted(1000, "100"), 0);
    });

    test('a day in the company\'s zone is not always 24 hours (README, time)', () {
      final (start, end) = Zones.dayOf("America/Caracas", DateTime.utc(2026, 9, 30, 3));
      expect(start, DateTime.utc(2026, 9, 29, 4));
      expect(end, DateTime.utc(2026, 9, 30, 4));

      final (spring, after) = Zones.dayOf("America/Santiago", DateTime.utc(2026, 9, 6, 12));
      expect(after.difference(spring), const Duration(hours: 23));
      expect(Zones.known("America/Caracas"), isTrue);
      expect(Zones.known("Mars/Olympus"), isFalse);
    });
  });

  late TestMaster master;
  late RpcClient client;
  late Map<String, Object?> tokens;
  late String tableId;
  late Map<String, String> fields;

  Future<Object?> write(Op op, Map<String, Object?> args, {RpcClient? as}) =>
    (as ?? client).call(op, args: args, commandId: const Uuid().v7());

  Future<String> record(Map<String, Object?> cells) async => (await write(Ops.inventoryRecordsCreate, {
    "tableId": tableId,
    "data": {for (final MapEntry(:key, :value) in cells.entries) fields[key]!: value},
  }) as Map)["id"] as String;

  Future<void> restock(String product, int units) =>
    write(Ops.stockMove, {"operation": "add", "tableId": tableId, "productId": product, "quantity": units});

  Future<Map> balance(String product) async {
    final row = master.openEngine.store.db.select("SELECT * FROM stock_balances WHERE product_id = ?", [product]).first;
    return {"onHand": row["on_hand"], "reserved": row["reserved"]};
  }

  Future<Map> open({Object? tax = 16, RpcClient? as}) async => await write(Ops.posInvoicesOpen, {"tax": tax}, as: as) as Map;

  Future<Map> line(String id, Map<String, Object?> args, {RpcClient? as}) async =>
    ((await write(Ops.posInvoicesLine, {"id": id, ...args}, as: as) as Map)["invoice"] as Map);

  void grant(String account, List<String> permissions) => master.openEngine.store.write((db) {
    db.execute("DELETE FROM grants WHERE account = ?", [account]);
    for (final permission in permissions) {
      db.execute("INSERT INTO grants (account, permission) VALUES (?, ?)", [account, permission]);
    }
  });

  setUp(() async {
    master = await TestMaster.start();
    (client, tokens) = await master.signIn();

    tableId = (await write(Ops.inventoryTablesCreate, {"title": "Products", "color": "0xFF60A5FA", "template": "FOOD"})
      as Map)["id"] as String;
    final discount = await write(Ops.inventoryFieldsCreate, {"tableId": tableId, "name": "Oferta", "type": "DISCOUNT", "position": 99});
    final structure = await client.call(Ops.inventoryTablesStructure, args: {"id": tableId}) as Map;
    final rows = ((structure["fields"] as Map)["values"] as List).cast<List>();
    String of(String type) => rows.firstWhere((field) => field[2] == type)[0] as String;

    fields = {
      "name": of("TITLE"), "sku": of("SKU"), "price": of("PRICE"), "categories": of("CATEGORIES"),
      "barcode": of("BARCODE"), "discount": (discount as Map)["id"] as String,
    };
    await write(Ops.inventoryFieldsEdit, {"id": fields["categories"], "options": ["Bebidas", "Panadería"]});
  });

  group('pos.catalog', () {
    test('products by type, ordered without case or accents, priced net of their discount (POS-1, POS-4, POS-7)', () async {
      final cafe = await record({"name": "café", "sku": "C-1", "price": "9.99", "discount": "15", "categories": "Bebidas"});
      await record({"name": "Agua", "price": "1.00", "barcode": "7591234567891"});
      await record({"name": "Ácido", "sku": "X"});
      await restock(cafe, 5);

      final page = await client.call(Ops.posCatalog, args: {"size": 10}) as Map;
      final data = page["data"] as Map;
      final products = [
        for (final row in (data["values"] as List).cast<List>())
          {for (var i = 0; i < (data["keys"] as List).length; i++) (data["keys"] as List)[i]: row[i]},
      ];

      expect(page["table"], tableId);
      expect(page["currency"], "USD");
      expect(products.map((product) => product["name"]), ["Ácido", "Agua", "café"]);
      expect(products[0]["price"], isNull);
      expect(products[1]["barcode"], "7591234567891");
      expect(products[2], containsPair("price", 849));
      expect(products[2], containsPair("stock", 5));
      expect(products[2], containsPair("reserved", 0));
      expect(products[2]["categories"], ["Bebidas"]);
    });

    test('search reads name, SKU and barcode; category is an exact label; the cursor never repeats (POS-3, POS-4)', () async {
      for (var i = 0; i < 5; i++) {
        await record({"name": "Pan $i", "sku": "P-$i", "price": "1", "categories": i.isEven ? "Panadería" : "Bebidas"});
      }
      await record({"name": "Leche", "barcode": "123", "price": "2"});

      Future<List<Object?>> names(Map<String, Object?> args) async {
        final page = await client.call(Ops.posCatalog, args: {"size": 10, ...args}) as Map;
        return [for (final row in ((page["data"] as Map)["values"] as List).cast<List>()) row[1]];
      }

      expect(await names({"search": "p-3"}), ["Pan 3"]);
      expect(await names({"search": "12"}), ["Leche"]);
      expect(await names({"category": "Panadería"}), ["Pan 0", "Pan 2", "Pan 4"]);
      expect(await names({"category": "panadería"}), isEmpty);

      final first = await client.call(Ops.posCatalog, args: {"size": 4}) as Map;
      final second = await client.call(Ops.posCatalog, args: {"size": 4, "cursor": first["cursor"]}) as Map;
      expect(first["more"], isTrue);
      expect(second["more"], isFalse);
      expect(second["cursor"], isNull);
      expect([for (final row in ((second["data"] as Map)["values"] as List).cast<List>()) row[1]], ["Pan 3", "Pan 4"]);
    });

    test('an untracked product carries no counters (POS-6); the summary lists the categories (POS-5)', () async {
      final summary = await client.call(Ops.posSummary) as Map;
      expect(summary, {"mine": {"sales": 0}, "categories": ["Bebidas", "Panadería"]});

      final stock = (await client.call(Ops.inventoryTablesStructure, args: {"id": tableId}) as Map)["fields"] as Map;
      final stockField = (stock["values"] as List).cast<List>().firstWhere((field) => field[2] == "STOCK")[0];
      await write(Ops.inventoryFieldsDelete, {"id": stockField});
      await record({"name": "Servicio", "price": "5"});

      final page = await client.call(Ops.posCatalog, args: {"size": 10}) as Map;
      final row = ((page["data"] as Map)["values"] as List).single as List;
      expect(row.sublist(5, 7), [null, null]);
    });

    test('the methods are the settlement kinds in the company\'s language, without credit (POS-33)', () async {
      final answer = await client.call(Ops.posMethods) as Map;
      final methods = (answer["methods"] as List).cast<Map>();

      expect(answer["channels"], ["pos"]);
      expect(methods.first, {"method": "cash", "name": "Efectivo", "reference": false, "change": true, "credit": false, "default": true});
      expect(methods.map((method) => method["method"]), isNot(contains("account")));
    });
  });

  group('pos.invoice', () {
    test('codes are per device, zero-padded and never reused; mine is this device (POS-40, POS-41, POS-45)', () async {
      final first = await open();
      final second = await open();
      expect([first["ticket"], second["ticket"]], ["A-000001", "A-000002"]);
      expect(first["open"], isTrue);
      expect(first["items"], isEmpty);

      final till = await master.pairNative("Till", code: (await master.openPairing())["code"] as String);
      final (other, _) = await master.signIn(till);
      expect((await open(as: other))["ticket"], "B-000001");

      await write(Ops.posInvoicesCancel, {"id": first["id"]});
      expect((await open())["ticket"], "A-000003");

      final mine = (await client.call(Ops.posInvoicesList, args: {"mine": true}) as Map)["invoices"] as List;
      final all = (await client.call(Ops.posInvoicesList) as Map)["invoices"] as List;
      expect(mine.map((invoice) => (invoice as Map)["ticket"]), ["A-000002", "A-000003"]);
      expect(all, hasLength(3));
    });

    test('a product line holds its units; adding it again grows it; shrinking gives them back (POS-11, POS-13, POS-15)', () async {
      final cafe = await record({"name": "Café", "price": "2.50"});
      await restock(cafe, 3);
      final invoice = await open();

      var ticket = await line(invoice["id"], {"productId": cafe, "add": 1, "tax": 16});
      ticket = await line(invoice["id"], {"productId": cafe, "add": 1, "tax": 16});
      final lineId = ((ticket["items"] as List).single as Map)["lineId"];
      expect((ticket["items"] as List).single, containsPair("qty", 2));
      expect(ticket["held"], 2);
      expect(await balance(cafe), {"onHand": 3, "reserved": 2});

      await expectRefusal(line(invoice["id"], {"productId": cafe, "add": 2}), "insufficient_stock");
      expect(await balance(cafe), {"onHand": 3, "reserved": 2});

      ticket = await line(invoice["id"], {"lineId": lineId, "add": -1});
      expect(ticket["held"], 1);
      ticket = await line(invoice["id"], {"lineId": lineId, "quantity": 0});
      expect(ticket["items"], isEmpty);
      expect(await balance(cafe), {"onHand": 3, "reserved": 0});
    });

    test('money is computed per line and rounded once; a line freezes its price (POS-12, POS-20, POS-22)', () async {
      final pan = await record({"name": "Pan", "price": "3.33", "discount": "10"});
      await restock(pan, 10);
      final invoice = await open(tax: "7.5");

      var ticket = await line(invoice["id"], {"productId": pan, "quantity": 3, "tax": "7.5"});
      await write(Ops.inventoryRecordsEdit, {"tableId": tableId, "id": pan, "data": {fields["price"]: "9.00"}});
      ticket = await line(invoice["id"], {"concept": "Envío", "price": 150, "add": 1, "tax": 0});

      final items = (ticket["items"] as List).cast<Map>();
      expect(items.first, containsPair("price", 300));
      expect(items.first, containsPair("list", 333));
      expect(items.first, containsPair("discount", "10"));
      expect(items.first, containsPair("subtotal", 900));
      expect(items.first, containsPair("tax", 68));
      expect(items.last, containsPair("productId", null));
      expect(items.last, containsPair("held", 0));
      expect([ticket["subtotal"], ticket["tax"], ticket["total"], ticket["units"]], [1050, 68, 1118, 4]);
      expect(ticket["taxes"], [
        {"rate": "7.5", "base": 900, "amount": 68},
        {"rate": "0", "base": 150, "amount": 0},
      ]);
    });

    test('refusals: no price, too many units, a typed charge or a new rate without their permission (POS-2, POS-14, POS-16, POS-17)', () async {
      final free = await record({"name": "Sin precio"});
      final cafe = await record({"name": "Café", "price": "1"});
      await restock(cafe, 1);
      final invoice = await open();

      await expectRefusal(line(invoice["id"], {"productId": free, "add": 1}), "no_price");
      await expectRefusal(line(invoice["id"], {"productId": cafe, "quantity": 10000}), "too_many_units");
      await expectRefusal(line(invoice["id"], {"productId": cafe, "add": 1, "quantity": 2}), ErrorCodes.badRequest);

      grant(tokens["accountId"] as String, ["pos.view", "pos.sell"]);
      final (cashier, _) = await master.signIn();

      await expectRefusal(line(invoice["id"], {"concept": "Propina", "price": 100, "add": 1}, as: cashier), ErrorCodes.forbidden);
      await expectRefusal(line(invoice["id"], {"productId": cafe, "add": 1, "tax": 8}, as: cashier), ErrorCodes.forbidden);
      final ticket = await line(invoice["id"], {"productId": cafe, "add": 1, "tax": 16}, as: cashier);
      expect(((ticket["items"] as List).single as Map)["taxRate"], "16");
    });

    test('closing consumes the holds as one sale each; the ticket is sealed (POS-30, POS-32, POS-18, ST-23)', () async {
      final cafe = await record({"name": "Café", "price": "2"});
      final servicio = await record({"name": "Servicio", "price": "5"});
      await restock(cafe, 5);
      final invoice = await open();

      await expectRefusal(write(Ops.posInvoicesClose, {"id": invoice["id"], "method": "cash"}), "empty_invoice");
      await line(invoice["id"], {"productId": cafe, "add": 2});
      await expectRefusal(write(Ops.posInvoicesClose, {"id": invoice["id"], "method": "account"}), "unknown_method");
      await expectRefusal(write(Ops.posInvoicesClose, {"id": invoice["id"], "method": "barter"}), "unknown_method");
      expect(servicio, isNotEmpty);

      final sale = await write(Ops.posInvoicesClose, {"id": invoice["id"], "method": "transfer", "reference": " 0099 "}) as Map;
      expect(sale["open"], isFalse);
      expect(sale["status"], "closed");
      expect(sale["payment"], {"method": "transfer", "name": "Transferencia", "reference": "0099", "credit": false});
      expect(await balance(cafe), {"onHand": 3, "reserved": 0});

      final db = master.openEngine.store.db;
      expect(db.select("SELECT status FROM stock_holds").single["status"], "consumed");
      expect(
        db.select("SELECT operation, reason, source, invoice_id FROM stock_movements WHERE operation = 'remove'").single.values,
        ["remove", "sale", "pos", invoice["id"]],
      );
      expect(master.openEngine.stock.rebuild(), isEmpty);

      await expectRefusal(line(invoice["id"], {"productId": cafe, "add": 1}), "invoice_closed");
      expect((await client.call(Ops.posSummary) as Map)["mine"], {"sales": 1});
      expect((await client.call(Ops.posInvoicesList) as Map)["invoices"], isEmpty);
    });

    test('a hold released from the stock screen is taken again at close, or the close is refused (POS-31, ST-22)', () async {
      final cafe = await record({"name": "Café", "price": "2"});
      await restock(cafe, 2);
      final invoice = await open();
      await line(invoice["id"], {"productId": cafe, "add": 2});

      await write(Ops.stockMove, {"operation": "unreserve", "tableId": tableId, "productId": cafe, "quantity": 1});
      final read = ((await client.call(Ops.posInvoicesList) as Map)["invoices"] as List).single as Map;
      expect(((read["items"] as List).single as Map)["held"], 1);

      await write(Ops.stockMove, {"operation": "remove", "tableId": tableId, "productId": cafe, "quantity": 1});
      await expectRefusal(write(Ops.posInvoicesClose, {"id": invoice["id"], "method": "cash"}), "insufficient_stock");

      await restock(cafe, 1);
      await write(Ops.posInvoicesClose, {"id": invoice["id"], "method": "cash"});
      expect(await balance(cafe), {"onHand": 0, "reserved": 0});
      expect(master.openEngine.stock.rebuild(), isEmpty);
    });

    test('an untracked product is sold without holds and never refused for stock (POS-6, ST-1)', () async {
      final structure = await client.call(Ops.inventoryTablesStructure, args: {"id": tableId}) as Map;
      final stock = ((structure["fields"] as Map)["values"] as List).cast<List>().firstWhere((field) => field[2] == "STOCK");
      await write(Ops.inventoryFieldsDelete, {"id": stock[0]});
      final corte = await record({"name": "Corte", "price": "8"});
      final invoice = await open();

      final ticket = await line(invoice["id"], {"productId": corte, "quantity": 50});
      expect((ticket["items"] as List).single, allOf(containsPair("held", 0), containsPair("tracked", false)));

      await write(Ops.posInvoicesClose, {"id": invoice["id"], "method": "card", "reference": "A1"});
      final db = master.openEngine.store.db;
      expect(db.select("SELECT count(*) AS n FROM stock_holds").single["n"], 0);
      expect(db.select("SELECT count(*) AS n FROM stock_movements").single["n"], 0);
    });

    test('cancelling gives every unit back and keeps the ticket; an open ticket keeps its table (POS-35, I-4)', () async {
      final cafe = await record({"name": "Café", "price": "2"});
      await restock(cafe, 4);
      final invoice = await open();
      await line(invoice["id"], {"productId": cafe, "add": 3});

      await expectLater(
        write(Ops.inventoryTablesDelete, {"id": tableId}),
        throwsA(isA<RpcError>().having((error) => error.data, "data", {"tickets": ["A-000001"]})),
      );
      await write(Ops.posInvoicesCancel, {"id": invoice["id"]});

      expect(await balance(cafe), {"onHand": 4, "reserved": 0});
      expect(master.openEngine.store.db.select("SELECT status FROM pos_invoices").single["status"], "cancelled");
      await expectRefusal(write(Ops.posInvoicesCancel, {"id": invoice["id"]}), "invoice_cancelled");
      await write(Ops.inventoryTablesDelete, {"id": tableId});
    });

    test('every till hears of a ticket, a cashier hears of stock; the payload is thin (pos.md, events)', () async {
      final cafe = await record({"name": "Café", "price": "2"});
      await restock(cafe, 4);

      final till = await master.pairNative("Till", code: (await master.openPairing())["code"] as String);
      // The owner's session already bound keeps its grants; the till's new one has only the POS's.
      grant(tokens["accountId"] as String, ["pos.view", "pos.sell", "pos.checkout"]);
      final (cashier, _) = await master.signIn(till);

      final events = <RpcEvent>[];
      final subscription = cashier.events.listen(events.add);
      addTearDown(subscription.cancel);
      await cashier.call(Ops.eventsSubscribe);

      final invoice = await open();
      await line(invoice["id"], {"productId": cafe, "add": 1, "tax": 0});
      await write(Ops.posInvoicesClose, {"id": invoice["id"], "method": "cash"});
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(events.map((event) => event.event), [
        Events.invoiceOpened, Events.stockChanged, Events.invoiceUpdated, Events.stockChanged, Events.invoiceClosed,
      ]);
      expect(events.last.data, {"id": invoice["id"], "ticket": "A-000001", "units": 1, "total": 200});
    });
  });
}
