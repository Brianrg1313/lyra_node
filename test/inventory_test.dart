import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'net_support.dart';

/// The inventory and stock domains over the LAN (`inventory.md`, `stock.md`): tables, fields,
/// records, images, the ledger and its summary. Rule numbers name what each test checks.
void main() {
  late TestMaster master;
  late RpcClient client;
  late Map<String, Object?> tokens;

  setUp(() async {
    master = await TestMaster.start();
    (client, tokens) = await master.signIn();
  });

  Future<Object?> write(Op op, Map<String, Object?> args) => client.call(op, args: args, commandId: const Uuid().v7());

  Future<String> table({String title = "Products", String? template}) async =>
    (await write(Ops.inventoryTablesCreate, {"title": title, "color": "0xFF60A5FA", "template": ?template}) as Map)["id"] as String;

  Future<Map<String, Object?>> field(String tableId, String name, String type, {int? position, Object? options, String? unit}) async =>
    (await write(Ops.inventoryFieldsCreate, {
      "tableId": tableId, "name": name, "type": type, "position": position ?? 99, "options": ?options, "unit": ?unit,
    }) as Map).cast<String, Object?>();

  Future<String> record(String tableId, Map<String, Object?> data) async =>
    (await write(Ops.inventoryRecordsCreate, {"tableId": tableId, "data": data}) as Map)["id"] as String;

  Future<Map<String, Object?>> page(String tableId, {String? match}) async =>
    (await client.call(Ops.inventoryRecordsList, args: {"tableId": tableId, "page": 1, "size": 50, "match": ?match}) as Map)
      .cast<String, Object?>();

  Future<String> upload(Uint8List bytes, {String purpose = "product_image"}) async {
    final http = HttpClient(context: master.master.context);
    addTearDown(() => http.close(force: true));
    final request = await http.openUrl("PUT", Uri.parse("https://127.0.0.1:${master.port}/f"));
    request.headers.set(HttpHeaders.authorizationHeader, "Bearer ${tokens["accessToken"]}");
    request.headers.set("X-Lyra-Purpose", purpose);
    request.add(bytes);

    return (jsonDecode(await utf8.decodeStream(await request.close())) as Map)["fileId"] as String;
  }

  Future<(String, Uint8List)> download(String id, {int? size}) async {
    final http = HttpClient(context: master.master.context);
    addTearDown(() => http.close(force: true));
    final request = await http.getUrl(Uri.parse("https://127.0.0.1:${master.port}/f/$id${size == null ? "" : "?size=$size"}"));
    request.headers.set(HttpHeaders.authorizationHeader, "Bearer ${tokens["accessToken"]}");
    final response = await request.close();
    final bytes = await response.fold<BytesBuilder>(BytesBuilder(), (builder, chunk) => builder..add(chunk));

    return (response.headers.contentType!.mimeType, bytes.takeBytes());
  }

  group('inventory.table', () {
    test('the first table is primary; a template adds its fields in the company\'s language (I-1, I-3)', () async {
      final first = await table(template: "FOOD");
      await table(title: "Services");

      final tables = (await client.call(Ops.inventoryTablesList) as List).cast<Map>();
      expect(tables.map((table) => table["primary"]), [true, false]);
      expect(tables.first["fields"], 9);

      final structure = await client.call(Ops.inventoryTablesStructure, args: {"id": first}) as Map;
      final fields = ((structure["fields"] as Map)["values"] as List).cast<List>();
      expect(fields.map((field) => field[1]), containsAllInOrder(["Nombre", "SKU", "Precio", "Existencia", "Fotos"]));
      expect(fields.firstWhere((field) => field[2] == "MEASURE")[5], "g");

      final detail = await client.call(Ops.inventoryTablesDetails, args: {"id": first}) as Map;
      expect((detail["columns"] as Map)["summary"], 3);
      expect(detail["channels"], {"reached": false, "linked": [], "open": []});
    });

    test('the flag moves to another table and can\'t be taken off; deleting the primary hands it on (I-2, I-3)', () async {
      final first = await table();
      final second = await table(title: "Second");
      final third = await table(title: "Third");

      expect((await write(Ops.inventoryTablesEdit, {"id": third, "primary": true}) as Map)["primary"], isTrue);
      await expectRefusal(write(Ops.inventoryTablesEdit, {"id": third, "primary": false}), "invalid_primary");

      await write(Ops.inventoryTablesDelete, {"id": third});
      final tables = (await client.call(Ops.inventoryTablesList) as List).cast<Map>();
      expect(tables.map((table) => table["id"]), [first, second]);
      expect(tables.map((table) => table["primary"]), [true, false]);
    });

    test('a bad colour, a missing title or an unknown template is refused', () async {
      await expectRefusal(write(Ops.inventoryTablesCreate, {"title": "A", "color": "red"}), ErrorCodes.invalidField);
      await expectRefusal(write(Ops.inventoryTablesCreate, {"title": " ", "color": "0xFF000000"}), ErrorCodes.required);
      await expectRefusal(write(Ops.inventoryTablesCreate, {"title": "A", "color": "0xFF000000", "template": "PETS"}), "unknown_template");
    });
  });

  group('inventory.field', () {
    test('positions stay dense through create, move and delete (I-13)', () async {
      final id = await table();
      final a = await field(id, "A", "TEXT", position: 0);
      final b = await field(id, "B", "TEXT", position: 1);
      final c = await field(id, "C", "TEXT", position: 0);

      Future<List<Object?>> names() async => (((await client.call(Ops.inventoryTablesStructure, args: {"id": id}) as Map)["fields"]
        as Map)["values"] as List).map((field) => (field as List)[1]).toList();

      expect(await names(), ["C", "A", "B"]);
      await write(Ops.inventoryFieldsEdit, {"id": c["id"], "position": 2});
      expect(await names(), ["A", "B", "C"]);
      await write(Ops.inventoryFieldsDelete, {"id": a["id"]});
      expect(await names(), ["B", "C"]);
      expect(b["position"], 1);
    });

    test('one STOCK and one COUNTER per table; options are trimmed and deduplicated (I-10, I-15)', () async {
      final id = await table();
      await field(id, "Stock", "STOCK");
      await expectRefusal(field(id, "Again", "STOCK"), "duplicate_field_type");

      final size = await field(id, "Size", "OPTIONS", options: [" S ", "M", "m", "", "L"]);
      expect(size["options"], ["S", "M", "L"]);
      await expectRefusal(field(id, "Weird", "SPACESHIP"), ErrorCodes.invalidField);
    });

    test('a width is anyone\'s who reads the table, a rename is not (I-17)', () async {
      final id = await table();
      final name = await field(id, "Name", "TITLE");
      final owner = tokens["accountId"] as String;

      master.openEngine.store.write((db) {
        db.execute("DELETE FROM grants WHERE account = ?", [owner]);
        db.execute("INSERT INTO grants (account, permission) VALUES (?, 'inventory.view')", [owner]);
      });
      final (reader, _) = await master.signIn();

      final dragged = await reader.call(Ops.inventoryFieldsEdit,
        args: {"id": name["id"], "name": "Name", "width": 240}, commandId: const Uuid().v7()) as Map;
      expect(dragged["width"], 240);
      await expectRefusal(
        reader.call(Ops.inventoryFieldsEdit, args: {"id": name["id"], "name": "Title"}, commandId: const Uuid().v7()),
        ErrorCodes.forbidden,
      );
    });

    test('a deleted field takes its values, and the audit log says how many (I-16)', () async {
      final id = await table();
      final note = await field(id, "Note", "TEXT");
      await record(id, {note["id"] as String: "fragile"});
      await record(id, {});

      await write(Ops.inventoryFieldsDelete, {"id": note["id"]});

      final entry = master.openEngine.audit.list().lastWhere((entry) => entry.kind == AuditKinds.fieldDeleted);
      expect(entry.data, containsPair("values", 1));
      expect(entry.data, containsPair("name", "Note"));
    });

    test('a type change keeps what doesn\'t fit as text (I-14); a new counter numbers the records (I-11)', () async {
      final id = await table();
      final code = await field(id, "Code", "TEXT");
      final first = await record(id, {code["id"] as String: "12"});
      await record(id, {code["id"] as String: "abc"});

      await write(Ops.inventoryFieldsEdit, {"id": code["id"], "type": "NUMBER"});
      final counter = await field(id, "N", "COUNTER");
      final third = await record(id, {});

      final rows = ((await page(id))["values"] as List).cast<List>();
      expect(rows.map((row) => row[1]), [12, "abc", null]);
      expect(rows.map((row) => row[2]), [1, 2, 3]);
      expect(rows.map((row) => row[0]), [first, isA<String>(), third]);
      await expectRefusal(
        write(Ops.inventoryRecordsEdit, {"tableId": id, "id": first, "data": {counter["id"]: "9"}}),
        "read_only_field",
      );
    });
  });

  group('inventory.record', () {
    test('values are checked and stored in their type (I-20, I-21)', () async {
      final id = await table();
      final price = (await field(id, "Price", "PRICE"))["id"] as String;
      final off = (await field(id, "Off", "DISCOUNT"))["id"] as String;
      final count = (await field(id, "Units", "NUMBER"))["id"] as String;
      final open = (await field(id, "Open", "BOOLEAN"))["id"] as String;
      final day = (await field(id, "Day", "DATE"))["id"] as String;
      final tags = (await field(id, "Tags", "CATEGORIES"))["id"] as String;

      await record(id, {price: "22.50", off: "20", count: "3", open: "true", day: "2024-02-29", tags: "a, b; c"});
      final row = ((await page(id))["values"] as List).single as List;
      expect(row.sublist(1), ["22.50", "20", 3, true, "2024-02-29", ["a", "b", "c"]]);

      for (final (key, value) in [(price, "22.505"), (price, "-1"), (off, "0.2x"), (off, "120"), (count, "1.5"), (open, "maybe"), (day, "2024-02-30")]) {
        await expectRefusal(record(id, {key: value}), "invalid_value");
      }
    });

    test('an edit writes only its cells, and "" clears one', () async {
      final id = await table();
      final name = (await field(id, "Name", "TITLE"))["id"] as String;
      final note = (await field(id, "Note", "TEXT"))["id"] as String;
      final product = await record(id, {name: "Café", note: "house blend"});

      await write(Ops.inventoryRecordsEdit, {"tableId": id, "id": product, "data": {note: ""}});

      expect(((await page(id))["values"] as List).single, [product, "Café", null]);
    });

    test('SKUs are unique within a table, without case or spaces (I-22)', () async {
      final id = await table();
      final sku = (await field(id, "SKU", "SKU"))["id"] as String;
      final product = await record(id, {sku: "ABC-1"});

      await expectRefusal(record(id, {sku: " abc-1 "}), "duplicate_sku");
      await write(Ops.inventoryRecordsEdit, {"tableId": id, "id": product, "data": {sku: "abc-1"}});
      expect(await record(await table(title: "Other"), {}), isA<String>());
    });

    test('the list is in creation order and match is text search without accents (I-25, I-26)', () async {
      final id = await table();
      final name = (await field(id, "Name", "TITLE"))["id"] as String;
      final price = (await field(id, "Price", "PRICE"))["id"] as String;

      final coffee = await record(id, {name: "Café molido", price: "5"});
      await record(id, {name: "Té verde", price: "4"});
      final bean = await record(id, {name: "CAFE en grano", price: "7"});

      final all = await page(id);
      expect(all["keys"], ["id", name, price]);
      expect(all["total"], 3);

      final found = await page(id, match: "cafe");
      expect((found["values"] as List).map((row) => (row as List).first), [coffee, bean]);
      expect(found["total"], 2);
      expect((await page(id, match: "5"))["total"], 0);
    });

    test('a deleted record leaves the list (I-23)', () async {
      final id = await table();
      final product = await record(id, {});

      await write(Ops.inventoryRecordsDelete, {"tableId": id, "id": product});

      expect((await page(id))["total"], 0);
      await expectRefusal(write(Ops.inventoryRecordsEdit, {"tableId": id, "id": product, "data": {}}), ErrorCodes.notFound);
    });
  });

  group('inventory.images', () {
    Uint8List png(int width) => img.encodePng(img.Image(width: width, height: width ~/ 2));

    test('an upload joins the cell, reads back small with size, and leaves when removed (I-30, I-31)', () async {
      final id = await table();
      await field(id, "Photos", "IMAGE");
      final product = await record(id, {});
      final fileId = await upload(png(640));

      final cell = await write(Ops.inventoryImagesAdd, {"tableId": id, "productId": product, "fileId": fileId}) as Map;
      expect(cell["images"], [{"id": fileId}]);
      expect(((await page(id))["values"] as List).single, [product, [fileId]]);

      final (type, small) = await download(fileId, size: 320);
      expect(type, "image/png");
      expect(img.decodePng(small)!.width, 320);
      expect(img.decodePng((await download(fileId)).$2)!.width, 640);

      final removed = await write(Ops.inventoryImagesRemove, {"tableId": id, "productId": product, "fileId": fileId}) as Map;
      expect(removed["images"], isEmpty);
    });

    test('eight at most; a logo upload or a record without an image column is refused', () async {
      final id = await table();
      await field(id, "Photos", "IMAGE");
      final product = await record(id, {});

      for (var i = 0; i < Inventory.maxImages; i++) {
        await write(Ops.inventoryImagesAdd, {"tableId": id, "productId": product, "fileId": await upload(png(8))});
      }
      await expectRefusal(
        write(Ops.inventoryImagesAdd, {"tableId": id, "productId": product, "fileId": await upload(png(8))}),
        "too_many_images",
      );

      final other = await table(title: "Plain");
      final plain = await record(other, {});
      await expectRefusal(
        write(Ops.inventoryImagesAdd, {"tableId": other, "productId": plain, "fileId": await upload(png(8))}),
        ErrorCodes.invalidField,
      );
      await expectRefusal(
        write(Ops.inventoryImagesAdd, {"tableId": id, "productId": await record(id, {}), "fileId": await upload(png(8), purpose: "logo")}),
        "invalid_file",
      );
    });
  });

  group('stock', () {
    late String tableId;
    late String product;
    late String name;

    setUp(() async {
      tableId = await table();
      name = (await field(tableId, "Name", "TITLE"))["id"] as String;
      await field(tableId, "Stock", "STOCK");
      product = await record(tableId, {name: "Coffee"});
    });

    Future<Map> move(String operation, int quantity, {String? reason}) async =>
      await write(Ops.stockMove, {
        "operation": operation, "tableId": tableId, "productId": product, "quantity": quantity, "reason": ?reason,
      }) as Map;

    test('movements move the counters and the STOCK cell reads available (ST-2, ST-12, I-12)', () async {
      expect(((await page(tableId))["values"] as List).single, [product, "Coffee", 0]);

      await move("add", 10);
      await move("reserve", 3);
      await move("return", 2);
      final after = await move("remove", 1, reason: "damage");

      expect(after, {"onHand": 9, "reserved": 3, "available": 6, "returns": 2, "needsReview": false});
      expect(((await page(tableId))["values"] as List).single, [product, "Coffee", 6]);

      final approved = await move("add", 2, reason: "return");
      expect(approved["returns"], 0);
      expect(approved["onHand"], 11);
    });

    test('online, nothing goes negative; the refusal carries the balance (ST-13)', () async {
      await move("add", 2);

      final refusal = await client.call(Ops.stockMove, args: {
        "operation": "remove", "tableId": tableId, "productId": product, "quantity": 3,
      }, commandId: const Uuid().v7()).then<RpcError?>((_) => null, onError: (Object error) => error as RpcError);

      expect(refusal!.code, "insufficient_stock");
      expect(refusal.data, containsPair("available", 2));
      await expectRefusal(move("unreserve", 1), "insufficient_stock");
      await expectRefusal(move("add", 1, reason: "return"), "insufficient_stock");
    });

    test('a reason belongs to its operation (ST-11); an untracked product has no ledger (ST-1)', () async {
      await expectRefusal(move("add", 1, reason: "theft"), "invalid_reason");
      await expectRefusal(move("reserve", 1, reason: "restock"), "invalid_reason");
      await expectRefusal(move("add", 0), ErrorCodes.invalidField);

      final plain = await table(title: "Services");
      final service = await record(plain, {});
      await expectRefusal(
        write(Ops.stockMove, {"operation": "add", "tableId": plain, "productId": service, "quantity": 1}),
        "untracked",
      );
      expect(master.openEngine.stock.balanceOf(service)["available"], isNull);
    });

    test('a replayed sale may go negative and flags the product until a correction (ST-14)', () {
      final stock = master.openEngine.stock;

      final replayed = stock.move(operation: "remove", tableId: tableId, productId: product, quantity: 2, reason: "sale", source: "outbox");
      expect(replayed["available"], -2);
      expect(replayed["needsReview"], isTrue);

      expect(stock.move(operation: "add", tableId: tableId, productId: product, quantity: 5)["needsReview"], isTrue);
      expect(stock.move(operation: "add", tableId: tableId, productId: product, quantity: 1, reason: "correction")["needsReview"], isFalse);
      expect(stock.rebuild(), isEmpty);
    });

    test('a release takes from manual holds, oldest first (ST-22)', () async {
      await move("add", 10);
      await move("reserve", 2);
      await move("reserve", 3);
      await move("unreserve", 4);

      final holds = master.openEngine.store.db.select("SELECT qty, status FROM stock_holds ORDER BY created, rowid");
      expect([for (final hold in holds) (hold["qty"], hold["status"])], [(0, "released"), (1, "active")]);
    });

    test('each movement reaches subscribers as stock/changed with the balance after it (ST-15)', () async {
      final events = <RpcEvent>[];
      final subscription = client.events.listen(events.add);
      addTearDown(subscription.cancel);
      await client.call(Ops.eventsSubscribe);

      await move("add", 4);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final stock = events.where((event) => event.event == Events.stockChanged).single;
      expect(stock.data, {"productId": product, "table": tableId, "onHand": 4, "reserved": 0, "available": 4});
    });

    test('history is newest first, by cursor, with the product\'s name frozen (ST-16)', () async {
      await move("add", 1);
      await move("add", 2);
      await write(Ops.inventoryRecordsEdit, {"tableId": tableId, "id": product, "data": {name: "Coffee beans"}});
      await move("add", 3);

      final first = await client.call(Ops.stockHistory, args: {"productId": product, "size": 2}) as Map;
      expect((first["items"] as List).map((item) => (item as Map)["quantity"]), [3, 2]);
      expect(first["more"], isTrue);
      expect(((first["items"] as List).last as Map)["productName"], "Coffee");

      final rest = await client.call(Ops.stockHistory, args: {"productId": product, "cursor": first["cursor"]}) as Map;
      expect((rest["items"] as List).map((item) => (item as Map)["quantity"]), [1]);
      expect(rest["more"], isFalse);
    });

    test('the summary is the primary table: photo, summary fields, then the numbers (ST-30 to ST-33)', () async {
      await write(Ops.inventoryFieldsEdit, {"id": name, "summary": true});
      final tea = await record(tableId, {name: "Tea"});
      master.openEngine.stock.move(operation: "remove", tableId: tableId, productId: tea, quantity: 1, source: "outbox");
      await move("add", 5);
      await move("reserve", 1);

      final summary = await client.call(Ops.stockSummary, args: {"page": 1, "size": 30}) as Map;
      final columns = (summary["columns"] as List).cast<Map>();

      expect(summary["table"], tableId);
      expect(columns.map((column) => column["key"]), ["image", name, "stock", "reserved", "performance"]);
      expect(columns.first["name"], isNull);

      final rows = ((summary["data"] as Map)["values"] as List).cast<List>();
      expect(rows.map((row) => row[2]), ["Tea", "Coffee"]);
      expect(rows.last.sublist(3, 6), [4, 1, null]);

      expect(((await client.call(Ops.stockSummary, args: {"page": 1, "size": 30, "match": "cof"}) as Map)["total"]), 1);
    });

    test('without a primary table there is no summary', () async {
      final (fresh, _) = await (await TestMaster.start()).signIn();

      await expectRefusal(fresh.call(Ops.stockSummary, args: {"page": 1, "size": 30}), "no_primary_table");
    });
  });
}
