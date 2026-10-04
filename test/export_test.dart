import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'net_support.dart';
import 'support.dart';

/// The accounting export (`money.md` export.accounting, plan §8.5). Rule numbers name what each
/// test checks.
void main() {
  group('writers', () {
    test('an amount is written from its minor units, never through a double (M-63)', () {
      expect(const Decimal(580, 2).text(), "5.80");
      expect(const Decimal(580, 2).text(","), "5,80");
      expect(const Decimal(5, 2).text(), "0.05");
      expect(const Decimal(-1234, 2).text(), "-12.34");
      expect(const Decimal(7, 0).text(), "7");
      expect(const Decimal(100000001, 8).text(), "1.00000001");
    });

    test('CSV: BOM, CRLF, quoted only when needed, a formula never runs (M-63)', () {
      const dataset = Dataset("sales", ["id", "note", "total", "credit"], [
        ["a", 'says "hi"; ok', Decimal(150, 2), false],
        ["b", "=HYPERLINK(\"x\")", null, true],
        ["c", "two\nlines", 3, null],
      ]);

      final bytes = CsvWriter.encode(dataset, decimalComma: true);
      expect(bytes.sublist(0, 3), [0xef, 0xbb, 0xbf]);
      expect(utf8.decode(bytes.sublist(3)).split("\r\n"), [
        "id;note;total;credit",
        'a;"says ""hi""; ok";1,50;false',
        "b;\"'=HYPERLINK(\"\"x\"\")\";;true",
        'c;"two\nlines";3;',
        "",
      ]);

      final dot = utf8.decode(CsvWriter.encode(dataset, decimalComma: false));
      expect(dot.split("\r\n")[1], 'a,"says ""hi""; ok",1.50,false');
    });
  });

  group('export.accounting', () {
    late TestMaster master;
    late RpcClient client;
    late Map<String, Object?> tokens;
    late String cafe;
    late String table;

    Future<Object?> write(Op op, Map<String, Object?> args) =>
      client.call(op, args: args, commandId: const Uuid().v7());

    Future<Map> export(Map<String, Object?> args) async =>
      await client.call(Ops.exportAccounting, args: args) as Map;

    Future<HttpClientResponse> download(String fileId, [String? token]) async {
      final http = HttpClient(context: master.master.context);
      addTearDown(() => http.close(force: true));
      final request = await http.getUrl(Uri.parse("https://127.0.0.1:${master.port}/f/$fileId"));
      request.headers.set(HttpHeaders.authorizationHeader, "Bearer ${token ?? tokens["accessToken"]}");

      return request.close();
    }

    Future<Uint8List> bytesOf(String fileId) async {
      final response = await download(fileId);
      expect(response.statusCode, 200);

      return Uint8List.fromList(await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk)));
    }

    String today() {
      final (start, _) = Zones.dayOf(master.openEngine.business.timezone, DateTime.now());
      final local = start.add(const Duration(hours: 12));
      // The company's day, written from its noon so the offset can't push it to another date.
      return Zones.local(master.openEngine.business.timezone, local).substring(0, 10);
    }

    setUp(() async {
      master = await TestMaster.start();
      (client, tokens) = await master.signIn();

      table = (await write(Ops.inventoryTablesCreate, {"title": "Products", "color": "0xFF60A5FA", "template": "FOOD"})
        as Map)["id"] as String;
      final structure = await client.call(Ops.inventoryTablesStructure, args: {"id": table}) as Map;
      final rows = ((structure["fields"] as Map)["values"] as List).cast<List>();
      String of(String type) => rows.firstWhere((field) => field[2] == type)[0] as String;

      cafe = (await write(Ops.inventoryRecordsCreate, {
        "tableId": table,
        "data": {of("TITLE"): "Café", of("PRICE"): "2.50"},
      }) as Map)["id"] as String;
      await write(Ops.stockMove, {"operation": "add", "tableId": table, "productId": cafe, "quantity": 20});

      // A sale of two cafés with 16 % tax (5.80), a cancelled ticket, a payment and a voided one.
      final sold = await write(Ops.posInvoicesOpen, {"tax": 16}) as Map;
      await write(Ops.posInvoicesLine, {"id": sold["id"], "productId": cafe, "add": 2});
      await write(Ops.posInvoicesClose, {"id": sold["id"], "method": "transfer", "reference": "0099"});

      final dropped = await write(Ops.posInvoicesOpen, {"tax": 16}) as Map;
      await write(Ops.posInvoicesLine, {"id": dropped["id"], "productId": cafe, "add": 1});
      await write(Ops.posInvoicesCancel, {"id": dropped["id"]});

      await write(Ops.moneyPaymentsRecord, {"concept": "supplier", "amount": 25050, "method": "cash",
        "counterpart": {"name": "Distribuidora; Lara"}});
      final voided = await write(Ops.moneyPaymentsRecord, {"concept": "supplier", "amount": 100, "method": "cash"}) as Map;
      await write(Ops.moneyPaymentsVoid, {"id": voided["id"], "reason": "typo"});
    });

    tearDown(() => master.stop());

    test('CSV: one file per dataset in a zip, ids and statuses kept, amounts with a decimal comma (M-60 to M-64)',
        () async {
      final day = today();
      final answer = await export({
        "from": day, "to": day, "format": "csv",
        "datasets": ["stock_movements", "payments", "sales", "sale_lines", "receivables"],
      });
      final expires = DateTime.parse(answer["expires"] as String);
      expect(expires.difference(DateTime.now()).inMinutes, inInclusiveRange(58, 60));

      final zip = ZipDecoder().decodeBytes(await bytesOf(answer["fileId"] as String));
      expect([for (final file in zip.files) file.name],
        ["sales.csv", "sale_lines.csv", "payments.csv", "receivables.csv", "stock_movements.csv"]);

      List<List<String>> read(String name) {
        final bytes = zip.findFile(name)!.content;
        expect(bytes.sublist(0, 3), [0xef, 0xbb, 0xbf]);
        // The company writes in Spanish: `;` between cells (M-63). No quoted separators here.
        return [
          for (final line in utf8.decode(bytes.sublist(3)).split("\r\n").where((line) => line.isNotEmpty)) line.split(";"),
        ];
      }

      final sales = read("sales.csv");
      expect(sales.first, Accounting.salesColumns);
      expect(sales.length, 3);
      final closed = Map.fromIterables(sales.first, sales.firstWhere((row) => row[2] == "closed"));
      expect(closed, containsPair("payment_method", "transfer"));
      expect(closed, containsPair("payment_reference", "0099"));
      expect(closed, containsPair("total", "5,80"));
      expect(closed, containsPair("tax", "0,80"));
      expect(closed, containsPair("units", "2"));
      expect(closed, containsPair("currency", "USD"));
      expect(closed["closed"], matches(RegExp(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$")));
      expect(closed["id"], isNotEmpty);
      expect(sales.where((row) => row[2] == "cancelled").single[5], isNotEmpty, reason: "cancelled, with its date");

      final lines = read("sale_lines.csv");
      expect(lines.length, 3);
      final line = Map.fromIterables(lines.first, lines.firstWhere((row) => row[1] == closed["id"]));
      expect(line, containsPair("unit_price", "2,50"));
      expect(line, containsPair("quantity", "2"));
      expect(line, containsPair("tax_rate", "16"));
      expect(line, containsPair("total", "5,80"));
      expect(line, containsPair("line", "1"));

      final payments = utf8.decode(zip.findFile("payments.csv")!.content);
      expect(payments, contains('"Distribuidora; Lara"'));
      expect(payments, contains(";250,50;USD;"));
      expect(payments, contains(";voided;"));

      expect(read("receivables.csv"), [Accounting.receivablesColumns], reason: "no credit offline yet");

      final movements = read("stock_movements.csv");
      final changes = [for (final row in movements.skip(1)) (row[2], row[5])];
      expect(changes, containsAll([("add", "20"), ("remove", "-2"), ("reserve", "0")]));

      final audit = master.openEngine.audit.list().where((entry) => entry.kind == AuditKinds.accountingExported).single;
      expect(audit.data, containsPair("from", day));
      expect(audit.data, containsPair("format", "csv"));
      expect(audit.data["datasets"], AccountingExport.datasets);
      expect(audit.actor, tokens["accountId"]);
    });

    test('XLSX: one sheet per dataset, amounts as numbers, text inline (M-61, M-63)', () async {
      final day = today();
      final answer = await export({"from": day, "to": day, "format": "xlsx", "datasets": ["sales", "payments"]});
      final response = await download(answer["fileId"] as String);
      expect(response.headers.contentType?.mimeType,
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");

      final bytes = Uint8List.fromList(await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk)));
      final zip = ZipDecoder().decodeBytes(bytes);
      String part(String name) => utf8.decode(zip.findFile(name)!.content);

      expect(part("xl/workbook.xml"), allOf(contains('name="sales"'), contains('name="payments"')));
      final sales = part("xl/worksheets/sheet1.xml");
      expect(sales, contains("<v>5.80</v>"));
      expect(sales, contains('t="inlineStr"'));
      expect(sales, isNot(contains("<f>")));
      expect(part("xl/worksheets/sheet2.xml"), contains("<v>250.50</v>"));

      // The import's own reader opens it: a workbook another program can read.
      final read = Xlsx.parse(bytes);
      expect(read.first, Accounting.salesColumns);
      expect(read.length, 3);
      expect(read.any((row) => row.contains("5.80") || row.contains("5.8")), isTrue);
    });

    test('the window is calendar days in the company zone, both included (M-60)', () async {
      final day = DateTime.parse(today());
      String text(DateTime at) => at.toIso8601String().substring(0, 10);

      final before = await export({
        "from": text(day.subtract(const Duration(days: 30))), "to": text(day.subtract(const Duration(days: 1))),
        "format": "csv", "datasets": ["sales"],
      });
      final zip = ZipDecoder().decodeBytes(await bytesOf(before["fileId"] as String));
      expect(utf8.decode(zip.findFile("sales.csv")!.content).split("\r\n").where((line) => line.isNotEmpty).length, 1);
    });

    test('refusals: the window, the datasets, the format, the permission', () async {
      final day = today();
      Future<Map> ask(Map<String, Object?> change) =>
        export({"from": day, "to": day, "format": "csv", "datasets": ["sales"], ...change});

      await expectRefusal(ask({"from": "2026-09-02", "to": "2026-09-01"}), "invalid_range");
      await expectRefusal(ask({"from": "2026-02-30"}), ErrorCodes.invalidField);
      await expectRefusal(ask({"to": "1/9/2026"}), ErrorCodes.invalidField);
      await expectRefusal(ask({"datasets": <String>[]}), ErrorCodes.invalidField);
      await expectRefusal(ask({"datasets": ["sales", "salaries"]}), ErrorCodes.invalidField);
      await expectRefusal(ask({"format": "pdf"}), ErrorCodes.invalidField);

      final account = tokens["accountId"] as String;
      grantKeys(master.openEngine, account, ["money"]);
      final (clerk, _) = await master.signIn();
      await expectRefusal(
        clerk.call(Ops.exportAccounting, args: {"from": day, "to": day, "format": "csv", "datasets": ["sales"]}),
        ErrorCodes.forbidden,
      );
    });
  });

  group('the export file', () {
    late Engine engine;
    late DateTime now;
    late String owner;

    setUp(() async {
      final paths = tempPaths(addTearDown);
      final vault = MemoryVault();
      await setUpMaster(paths, vault);
      now = DateTime.now();
      engine = await Engine.open(paths: paths, vault: vault, hasher: fastHasher, now: () => now);
      addTearDown(engine.close);
      owner = engine.store.db.select("SELECT id FROM accounts").first["id"] as String;
    });

    test('only its asker reads it, for one hour; it is never uploaded (protocol-v1 §6)', () async {
      final id = await engine.files.keep(FilePurpose.export, Uint8List.fromList([0x50, 0x4b, 3, 4]),
        contentType: ExportFormat.csv.contentType, owner: owner);

      expect((await engine.files.get(id, account: owner, grant: Grant.everything())).contentType, "application/zip");
      await expectLater(engine.files.get(id, account: "someone else", grant: Grant.everything()),
        throwsA(isA<EngineFailure>().having((failure) => failure.code, "code", "not_found")));

      now = now.add(const Duration(minutes: 61));
      await expectLater(engine.files.get(id, account: owner, grant: Grant.everything()),
        throwsA(isA<EngineFailure>().having((failure) => failure.code, "code", "not_found")));
      expect(engine.files.sweep(), 1);

      expect(FilePurpose.byHeader("export"), isNull);
    });
  });
}
