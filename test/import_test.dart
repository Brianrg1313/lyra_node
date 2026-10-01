import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'net_support.dart';

/// Importing a spreadsheet (`inventory.md` I-40 to I-47): reading `.csv` and `.xlsx`, the typing
/// rules, and the two steps over the LAN with their events and opening balances.
void main() {
  group('reading', () {
    test('a CSV finds its separator, keeps quoted ones, and reads Windows-1252 (I-40)', () {
      final text = Csv.decode(Uint8List.fromList([...latin1.encode('Nombre;Precio\n"Caf\xe9; molido";"1.234,50"\r\n')]));
      final rows = Csv.parse(text);

      expect(rows, [["Nombre", "Precio"], ["Café; molido", "1.234,50"]]);
      expect(Csv.parse('a,"say ""hi""\nthere",c\n'), [["a", 'say "hi"\nthere', "c"]]);
      expect(Csv.parse(Csv.decode(Uint8List.fromList([0xff, 0xfe, ...utf16le("a\tb\n1\t2")]))), [["a", "b"], ["1", "2"]]);
    });

    test('the header row is 1-based; empty and repeated names are fixed (I-41)', () async {
      final sheet = await Sheet.read(utf8.encode("Report\n\nName,,name,Price\nTea,x,y,2\n\n"), "csv", 3);

      expect(sheet.headers, ["Name", "Column 2", "name (2)", "Price"]);
      expect(sheet.rows, [["Tea", "x", "y", "2"]]);
      await expectLater(Sheet.read(utf8.encode("a,b\n"), "csv", 5), throwsA(isA<EngineFailure>().having((f) => f.code, "code", "empty_file")));
      await expectLater(Sheet.read(utf8.encode("a,b\n"), "pdf", 1), throwsA(isA<EngineFailure>().having((f) => f.code, "code", "unsupported_file")));
    });

    test('an .xlsx reads shared and inline strings, numbers, booleans and dated cells', () async {
      final sheet = await Sheet.read(xlsx(), "excel", 1);

      expect(sheet.headers, ["Producto", "Precio", "Vence", "Activo"]);
      expect(sheet.rows, [
        ["Café <molido>", "12.3", "2026-12-31", "true"],
        ["Té", "4", "", "false"],
      ]);
      await expectLater(Sheet.read(Uint8List.fromList([0x50, 0x4b, 3, 4, 1, 2, 3]), "excel", 1),
        throwsA(isA<EngineFailure>().having((f) => f.code, "code", "unsupported_file")));
    });
  });

  group('typing (I-43)', () {
    test('by header when the values agree, else by the values', () {
      final types = Typing.columns(
        ["Código de barras", "Nombre del producto", "Precio venta", "Cantidad", "Notas", "Vence", "Correo", "Peso"],
        [
          ["7501234567893"], ["Café"], [r"$1.234,50"], ["4"], ["fresh"], ["31/12/2026"], ["a@b.co"], ["1,5"],
        ],
        language: "es",
      );

      expect(types, ["BARCODE", "TITLE", "PRICE", "STOCK", "TEXT", "DATE", "EMAIL", "DECIMAL"]);
    });

    test('one title and one stock; with no title header the first text column takes it', () {
      expect(Typing.columns(["Name", "Product", "Stock", "Qty"], [["a"], ["b"], ["1"], ["2"]], language: "en"),
        ["TITLE", "TEXT", "STOCK", "TEXT"]);
      expect(Typing.columns(["Ref", "Detail", "Marca"], [["A1"], ["x"], ["Acme"]], language: "es"),
        ["SKU", "DESCRIPTION", "TITLE"]);
      // A "stock" header over words is not a stock column.
      expect(Typing.columns(["Name", "Stock"], [["a"], ["sí"]], language: "es"), ["TITLE", "BOOLEAN"]);
    });

    test('numbers read the language\'s marks; codes need their check digit', () {
      expect(Typing.cell("PRICE", r"$ 1.234,50", language: "es"), "1234.5");
      expect(Typing.cell("PRICE", "1,234.5", language: "en"), "1234.5");
      expect(Typing.cell("NUMBER", "1,500", language: "en"), 1500);
      expect(Typing.cell("DECIMAL", "1,5", language: "es"), "1.5");
      expect(Typing.cell("PRICE", "3.333", language: "es"), "3.33");
      expect(Typing.cell("DATE", "12/31/2026", language: "en"), "2026-12-31");
      expect(Typing.cell("DATE", "31/02/2026", language: "es"), isNull);
      expect(Typing.gtin("7501234567893"), isTrue);
      expect(Typing.gtin("7501234567890"), isFalse);
      expect(Typing.column("Code", ["12345678", "87654321"], language: "en"), "SKU");
      expect(Typing.column("Ids", ["12345678", "87654321"], language: "en"), "NUMBER");
    });
  });

  group('over the LAN', () {
    late TestMaster master;
    late RpcClient client;
    late Map<String, Object?> tokens;

    setUp(() async {
      master = await TestMaster.start();
      (client, tokens) = await master.signIn();
    });

    Future<Object?> write(Op op, Map<String, Object?> args) => client.call(op, args: args, commandId: const Uuid().v7());

    Future<String> upload(List<int> bytes) async {
      final http = HttpClient(context: master.master.context);
      addTearDown(() => http.close(force: true));
      final request = await http.openUrl("PUT", Uri.parse("https://127.0.0.1:${master.port}/f"));
      request.headers.set(HttpHeaders.authorizationHeader, "Bearer ${tokens["accessToken"]}");
      request.headers.set("X-Lyra-Purpose", "import");
      request.add(bytes);

      return (jsonDecode(await utf8.decodeStream(await request.close())) as Map)["fileId"] as String;
    }

    // Twenty more plain rows: a misfit is kept as text only in a column whose values are 95 %
    // of one type (I-43).
    final csv = "Nombre,SKU,Precio,Existencia,Foto,Notas\n"
      "Café,C-1,\"\$1.234,50\",7,https://example.com/cafe.png,suave\n"
      "Té,c-1,\"2,5\",x,,\n"
      "Mate,M-1,abc,0,,amargo\n"
      "${[for (var i = 0; i < 20; i++) "P$i,P-$i,10,1,,"].join("\n")}\n";

    test('the structure step types the columns, between its two events (I-42, I-43, I-45)', () async {
      final events = <RpcEvent>[];
      final subscription = client.events.listen(events.add);
      addTearDown(subscription.cancel);
      await client.call(Ops.eventsSubscribe);

      final answer = await write(Ops.inventoryImportStructure, {"fileId": await upload(utf8.encode(csv)), "format": "csv", "row": 1, "name": "Lista"}) as Map;
      final id = answer["id"] as String;
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(events.map((event) => event.event), [Events.tableNormalizing, Events.tableReady, Events.tableChanged]);
      expect(events[1].data, containsPair("normalized", true));
      expect((events[1].data as Map)["summarized"], 3);

      final structure = await client.call(Ops.inventoryTablesStructure, args: {"id": id}) as Map;
      final fields = ((structure["fields"] as Map)["values"] as List).cast<List>();
      expect(structure["name"], "Lista");
      expect(structure["importStage"], "loading");
      expect([for (final field in fields) (field[1], field[2])], [
        ("Nombre", "TITLE"), ("SKU", "SKU"), ("Precio", "PRICE"), ("Existencia", "STOCK"), ("Foto", "IMAGE"), ("Notas", "TEXT"),
      ]);
      expect((events[1].data as Map)["image"], fields[4][0]);
    });

    test('the records step keeps misfits as text, refuses a repeated SKU, opens the ledger (I-44, I-46)', () async {
      final id = (await write(Ops.inventoryImportStructure, {"fileId": await upload(utf8.encode(csv)), "format": "csv", "row": 1}) as Map)["id"] as String;
      final fileId = await upload(utf8.encode(csv));

      final answer = await write(Ops.inventoryImportRecords, {"fileId": fileId, "format": "csv", "tableId": id, "row": 1});
      expect(answer, {"imported": 23, "withInvalidCells": 2});

      final page = await client.call(Ops.inventoryRecordsList, args: {"tableId": id, "page": 1, "size": 50}) as Map;
      final rows = (page["values"] as List).cast<List>();
      expect([for (final row in rows.take(3)) row.sublist(1)], [
        ["Café", "C-1", "1234.5", 7, ["https://example.com/cafe.png"], "suave"],
        ["Té", null, "2.5", 0, null, null],
        ["Mate", "M-1", "abc", 0, null, "amargo"],
      ]);

      final history = await client.call(Ops.stockHistory, args: {"productId": rows.first.first}) as Map;
      final movement = (history["items"] as List).single as Map;
      expect((movement["operation"], movement["reason"], movement["note"], movement["source"]), ("add", "restock", "import", "import"));

      final tables = (await client.call(Ops.inventoryTablesList) as List).cast<Map>();
      expect(tables.single["importStage"], isNull);

      // The upload was read once.
      await expectRefusal(write(Ops.inventoryImportRecords, {"fileId": fileId, "format": "csv", "tableId": id, "row": 1}), "invalid_file");
    });

    test('an .xlsx imports as well; a table without an image column gets one', () async {
      final id = (await write(Ops.inventoryImportStructure, {"fileId": await upload(xlsx()), "format": "excel", "row": 1}) as Map)["id"] as String;
      await write(Ops.inventoryImportRecords, {"fileId": await upload(xlsx()), "format": "excel", "tableId": id, "row": 1});

      final structure = await client.call(Ops.inventoryTablesStructure, args: {"id": id}) as Map;
      final fields = ((structure["fields"] as Map)["values"] as List).cast<List>();
      expect(structure["name"], "Tabla importada");
      expect([for (final field in fields) (field[1], field[2])],
        [("Producto", "TITLE"), ("Precio", "PRICE"), ("Vence", "DATE"), ("Activo", "BOOLEAN"), ("Fotos", "IMAGE")]);

      final page = await client.call(Ops.inventoryRecordsList, args: {"tableId": id, "page": 1, "size": 50}) as Map;
      expect((page["values"] as List).first, contains("2026-12-31"));
    });

    test('normalizing re-types the columns nobody typed by hand (I-47)', () async {
      const file = "Nombre,Peso,Vence\nA,\"1,5\",31/12/2026\nB,2,01/01/2027\nC,x,02/01/2027\n";
      final id = (await write(Ops.inventoryImportStructure, {"fileId": await upload(utf8.encode(file)), "format": "csv", "row": 1}) as Map)["id"] as String;
      await write(Ops.inventoryImportRecords, {"fileId": await upload(utf8.encode(file)), "format": "csv", "tableId": id, "row": 1});

      final structure = await client.call(Ops.inventoryTablesStructure, args: {"id": id}) as Map;
      final fields = ((structure["fields"] as Map)["values"] as List).cast<List>();
      expect(fields.map((field) => field[2]), ["TITLE", "TEXT", "DATE", "IMAGE"]);

      // The date column is set back to text by hand, and the weight's odd value fixed.
      await write(Ops.inventoryFieldsEdit, {"id": fields[2][0], "type": "TEXT"});
      final page = await client.call(Ops.inventoryRecordsList, args: {"tableId": id, "page": 1, "size": 50}) as Map;
      final last = ((page["values"] as List).last as List).first;
      await write(Ops.inventoryRecordsEdit, {"tableId": id, "id": last, "data": {fields[1][0]: "3"}});

      final answer = await write(Ops.inventoryTablesNormalize, {"tableId": id}) as Map;
      expect(answer, containsPair("retyped", 1));
      expect(answer, containsPair("reindexed", false));

      final after = await client.call(Ops.inventoryTablesStructure, args: {"id": id}) as Map;
      expect((((after["fields"] as Map)["values"] as List).cast<List>()).map((field) => field[2]), ["TITLE", "DECIMAL", "TEXT", "IMAGE"]);
      final values = ((await client.call(Ops.inventoryRecordsList, args: {"tableId": id, "page": 1, "size": 50}) as Map)["values"] as List).cast<List>();
      expect(values.map((row) => row[2]), ["1.5", "2", "3"]);
    });

    test('a file that is too long is refused before anything is written', () async {
      final big = StringBuffer("Name\n");
      for (var i = 0; i <= Sheet.maxRows; i++) {
        big.writeln("p$i");
      }

      await expectRefusal(write(Ops.inventoryImportStructure, {"fileId": await upload(utf8.encode("$big")), "format": "csv", "row": 1}), "too_large");
      expect(await client.call(Ops.inventoryTablesList), isEmpty);
    });
  });
}

List<int> utf16le(String text) => [for (final unit in text.codeUnits) ...[unit & 0xff, unit >> 8]];

/// A small workbook: shared strings (one with an entity), an inline string, a number with float
/// noise, a date-formatted serial and booleans.
Uint8List xlsx() {
  final archive = Archive();
  void add(String name, String text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add("xl/workbook.xml", '<workbook xmlns:r="r"><sheets><sheet name="Hoja1" sheetId="1" r:id="rId1"/></sheets></workbook>');
  add("xl/_rels/workbook.xml.rels", '<Relationships><Relationship Id="rId1" Target="worksheets/data.xml"/></Relationships>');
  add("xl/sharedStrings.xml", '<sst><si><t>Producto</t></si><si><r><t>Pre</t></r><r><t>cio</t></r></si>'
    '<si><t>Café &lt;molido&gt;</t></si><si><t>Té</t></si></sst>');
  add("xl/styles.xml", '<styleSheet><cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs></styleSheet>');
  add("xl/worksheets/data.xml", '<worksheet><sheetData>'
    '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="inlineStr"><is><t>Vence</t></is></c><c r="D1" t="str"><v>Activo</v></c></row>'
    '<row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>12.300000000000001</v></c><c r="C2" s="1"><v>46387</v></c><c r="D2" t="b"><v>1</v></c></row>'
    '<row r="3"><c r="A3" t="s"><v>3</v></c><c r="B3"><v>4</v></c><c r="D3" t="b"><v>0</v></c></row>'
    '</sheetData></worksheet>');

  return Uint8List.fromList(ZipEncoder().encode(archive));
}
