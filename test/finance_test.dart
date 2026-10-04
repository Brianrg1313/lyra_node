import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'net_support.dart';

/// The company's money over the LAN (`money.md`): payments recorded by hand and voided, the
/// summary beside the register, the receivables, the exchange currencies, and who may do what.
/// Rule numbers name what each test checks.
void main() {
  Matcher pairs(Map<String, Object?> expected) =>
    allOf([for (final MapEntry(:key, :value) in expected.entries) containsPair(key, value)]);

  late TestMaster master;
  late RpcClient client;
  late Map<String, Object?> tokens;
  late String cafe;

  Future<Object?> write(Op op, Map<String, Object?> args, {RpcClient? as, String? commandId}) =>
    (as ?? client).call(op, args: args, commandId: commandId ?? const Uuid().v7());

  Future<Map> record(Map<String, Object?> args, {RpcClient? as}) async =>
    await write(Ops.moneyPaymentsRecord, args, as: as) as Map;

  Future<Map> search([Map<String, Object?> args = const {}]) async =>
    await client.call(Ops.moneyPaymentsSearch, args: args) as Map;

  /// A ticket of two cafés at 2.50 with 16 % tax (5.80), charged by transfer.
  Future<Map> sale() async {
    final invoice = await write(Ops.posInvoicesOpen, {"tax": 16}) as Map;
    await write(Ops.posInvoicesLine, {"id": invoice["id"], "productId": cafe, "add": 2});

    return await write(Ops.posInvoicesClose, {"id": invoice["id"], "method": "transfer"}) as Map;
  }

  String daysAgo(int days) => DateTime.now().toUtc().subtract(Duration(days: days)).toIso8601String();

  setUp(() async {
    master = await TestMaster.start();
    (client, tokens) = await master.signIn();

    final table = (await write(Ops.inventoryTablesCreate, {"title": "Products", "color": "0xFF60A5FA", "template": "FOOD"})
      as Map)["id"] as String;
    final structure = await client.call(Ops.inventoryTablesStructure, args: {"id": table}) as Map;
    final rows = ((structure["fields"] as Map)["values"] as List).cast<List>();
    String of(String type) => rows.firstWhere((field) => field[2] == type)[0] as String;

    cafe = (await write(Ops.inventoryRecordsCreate, {
      "tableId": table,
      "data": {of("TITLE"): "Café", of("PRICE"): "2.50"},
    }) as Map)["id"] as String;
    await write(Ops.stockMove, {"operation": "add", "tableId": table, "productId": cafe, "quantity": 20});
  });

  tearDown(() => master.stop());

  test('the catalogue offline: nothing settles a credit ticket, no credit kind (money.catalog)', () async {
    final catalog = await client.call(Ops.moneyCatalog) as Map;
    final concepts = catalog["concepts"] as Map;

    expect([for (final row in (concepts["in"] as List).cast<Map>()) row["concept"]],
      ["advance", "supplier_refund", "capital", "loan", "other_income"]);
    expect((concepts["out"] as List).first,
      {"concept": "supplier", "name": "Pago a proveedor", "direction": "out", "ticket": false, "settles": false});
    expect([for (final row in (catalog["methods"] as List).cast<Map>()) row["method"]], isNot(contains("account")));
  });

  group('money.payments', () {
    test('recorded with the concept\'s direction, answered whole; texts trimmed, blanks not kept (M-1, M-9)', () async {
      final payment = await record({
        "concept": "supplier", "amount": 25050, "method": "transfer", "reference": " 004512 ",
        "counterpart": {"name": "Distribuidora Lara", "contact": " "}, "note": "", "date": daysAgo(3),
      });

      expect(payment, pairs({
        "direction": "out", "concept": "supplier", "conceptName": "Pago a proveedor", "amount": 25050,
        "currency": "USD", "method": "transfer", "methodName": "Transferencia", "account": null, "reference": "004512",
        "counterpart": {"name": "Distribuidora Lara"}, "ticket": null, "note": null, "status": "recorded",
        "voided": null,
      }));
      expect(payment["registeredBy"], isNotEmpty);
      expect(DateTime.parse(payment["date"] as String).isBefore(DateTime.parse(payment["created"] as String)), isTrue);
    });

    test('a retried command records once', () async {
      final commandId = const Uuid().v7();
      final args = {"concept": "rent", "amount": 1000, "method": "cash"};

      final first = await write(Ops.moneyPaymentsRecord, args, commandId: commandId) as Map;
      final again = await write(Ops.moneyPaymentsRecord, args, commandId: commandId) as Map;

      expect(again["id"], first["id"]);
      expect((await search())["total"], 1);
    });

    test('the history: newest first, totals over the filter and never voided (M-8, M-10)', () async {
      final old = await record({"concept": "supplier", "amount": 300, "method": "transfer", "date": daysAgo(2)});
      final advance = await record({"concept": "advance", "amount": 1000, "method": "cash",
        "counterpart": {"contact": "+58412"}});
      final wrong = await record({"concept": "rent", "amount": 999, "method": "cash", "date": daysAgo(1)});

      final voided = await write(Ops.moneyPaymentsVoid, {"id": wrong["id"], "reason": " Doble "}) as Map;
      expect(voided, pairs({"status": "voided"}));
      expect(voided["voided"], pairs({"reason": "Doble"}));
      expect((voided["voided"] as Map)["by"], isNotEmpty);

      final all = await search();
      expect([for (final row in (all["data"] as List).cast<Map>()) row["id"]], [advance["id"], wrong["id"], old["id"]]);
      expect(all["totals"], {"in": {"count": 1, "total": 1000}, "out": {"count": 1, "total": 300}});
      expect((all["data"] as List).first, pairs({"counterpart": "+58412", "account": null}));
      expect((all["data"] as List).first, isNot(contains("voided")));

      final out = await search({"direction": "out", "status": "voided", "size": 1});
      expect(out["total"], 1);
      expect(out["totals"], {"in": {"count": 0, "total": 0}, "out": {"count": 1, "total": 300}});
      expect(((out["data"] as List).single as Map)["id"], wrong["id"]);
      expect((await search({"concept": "advance", "method": "transfer"}))["total"], 0);

      await expectRefusal(write(Ops.moneyPaymentsVoid, {"id": wrong["id"]}), "already_voided");
      await expectRefusal(write(Ops.moneyPaymentsVoid, {"id": "nope"}), ErrorCodes.notFound);
      await expectRefusal(search({"direction": "sideways"}), ErrorCodes.invalidField);
      await expectRefusal(search({"size": 101}), ErrorCodes.invalidField);

      final audit = master.openEngine.audit.list().where((entry) => entry.kind == AuditKinds.paymentVoided).single;
      expect(audit.data, pairs({"payment": wrong["id"], "amount": 999, "reason": "Doble"}));
    });

    test('refusals: direction, amount, date, account, method, tickets (M-1 to M-7)', () async {
      final ticket = await sale();
      const base = {"concept": "supplier", "amount": 100, "method": "cash"};

      await expectRefusal(record({...base, "direction": "in"}), ErrorCodes.badRequest);
      await expectRefusal(record({...base, "concept": "sale"}), ErrorCodes.invalidField);
      await expectRefusal(record({...base, "amount": 0}), "invalid_amount");
      await expectRefusal(record({...base, "amount": 1.5}), "invalid_amount");
      final ahead = DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String();
      await expectRefusal(record({...base, "date": ahead}), "future_date");
      await expectRefusal(record({...base, "date": "friday"}), ErrorCodes.invalidField);
      await expectRefusal(record({...base, "accountId": "a1"}), "unknown_account");
      await expectRefusal(record({...base, "method": "account"}), "unknown_method");
      await expectRefusal(record({"concept": "supplier", "amount": 100}), "unknown_method");
      await expectRefusal(record({...base, "ticket": ticket["ticket"]}), "ticket_not_allowed");
      await expectRefusal(record({...base, "concept": "customer_refund", "ticket": "Z-000009"}), "sale_not_found");
      await expectRefusal(record({...base, "concept": "settlement"}), "ticket_required");
      await expectRefusal(record({...base, "concept": "settlement", "ticket": ticket["ticket"]}), "not_credit");

      final refund = await record({...base, "concept": "customer_refund",
        "ticket": (ticket["ticket"] as String).toLowerCase()});
      expect(refund, pairs({"direction": "out", "ticket": ticket["ticket"]}));
    });
  });

  group('money.summary', () {
    test('the register and the payments side by side, today unless asked (M-20 to M-28)', () async {
      await sale();
      await record({"concept": "advance", "amount": 1000, "method": "cash"});
      await record({"concept": "supplier", "amount": 300, "method": "transfer"});
      final voided = await record({"concept": "rent", "amount": 5000, "method": "cash"});
      await write(Ops.moneyPaymentsVoid, {"id": voided["id"]});
      await record({"concept": "taxes", "amount": 70, "method": "cash", "date": daysAgo(3)});

      final today = await client.call(Ops.moneySummary) as Map;

      expect(today, pairs({
        "currency": "USD",
        "income": {"sales": {"count": 1, "total": 580}, "payments": {"count": 1, "total": 1000}, "total": 1580},
        "expenses": {"count": 1, "total": 300},
        "credit": {"count": 0, "total": 0},
        "net": 1280,
        "methods": [
          {"method": "cash", "name": "Efectivo", "in": 1000, "out": 0, "net": 1000, "count": 1},
          {"method": "transfer", "name": "Transferencia", "in": 580, "out": 300, "net": 280, "count": 2},
        ],
        "concepts": [
          {"concept": "advance", "name": "Anticipo de un pedido", "direction": "in", "count": 1, "total": 1000},
          {"concept": "supplier", "name": "Pago a proveedor", "direction": "out", "count": 1, "total": 300},
        ],
      }));
      expect(DateTime.parse(today["from"] as String).isAfter(DateTime.now().subtract(const Duration(days: 1))), isTrue);

      final week = await client.call(Ops.moneySummary, args: {"from": daysAgo(7)}) as Map;
      expect(week["expenses"], {"count": 2, "total": 370});
      expect(week["net"], 1210);

      await expectRefusal(client.call(Ops.moneySummary, args: {"from": "2999-01-01T00:00:00Z"}), ErrorCodes.invalidField);
      await expectRefusal(client.call(Ops.moneySummary, args: {"from": "yesterday"}), ErrorCodes.invalidField);
    });

    test('receivables: none while credit is deferred (M-30 to M-32)', () async {
      await sale();

      final page = await client.call(Ops.moneyReceivables, args: {"page": 1, "size": 30, "open": true}) as Map;

      expect(page, pairs({
        "total": 0, "currency": "USD", "data": isEmpty,
        "totals": {"count": 0, "sold": 0, "collected": 0, "outstanding": 0},
      }));
    });
  });

  group('money.currencies', () {
    test('custom rates only; official keeps the custom figure; removed and added back (M-50 to M-53)', () async {
      Future<Map> save(Map<String, Object?> args) async => await write(Ops.moneyCurrenciesSave, args) as Map;

      var answer = await save({"currency": "ves", "mode": "custom", "rate": 36.5});
      expect(answer, {
        "currency": "USD",
        "currencies": [
          {"currency": "VES", "mode": "custom", "rate": 36.5, "official": null, "custom": 36.5, "updated": null},
        ],
      });

      answer = await save({"currency": "EUR", "mode": "official"});
      expect((answer["currencies"] as List).first, pairs({"currency": "EUR", "rate": null, "custom": null}));

      answer = await save({"currency": "VES", "mode": "official"});
      expect((answer["currencies"] as List).last, pairs({"mode": "official", "rate": null, "custom": 36.5}));

      answer = await write(Ops.moneyCurrenciesRemove, {"currency": "VES"}) as Map;
      expect([for (final row in (answer["currencies"] as List).cast<Map>()) row["currency"]], ["EUR"]);
      await expectRefusal(write(Ops.moneyCurrenciesRemove, {"currency": "VES"}), ErrorCodes.notFound);

      answer = await save({"currency": "VES", "mode": "official"});
      expect((answer["currencies"] as List).last, pairs({"currency": "VES", "rate": null, "custom": 36.5}));
      expect(await client.call(Ops.moneyCurrenciesGet), answer);

      await expectRefusal(save({"currency": "USD", "mode": "custom", "rate": 1}), "is_main");
      await expectRefusal(save({"currency": "BTC", "mode": "custom", "rate": 1}), "unknown_currency");
      await expectRefusal(save({"currency": "XXX", "mode": "official"}), "unknown_currency");
      await expectRefusal(save({"currency": "COP", "mode": "custom"}), "invalid_rate");
      await expectRefusal(save({"currency": "COP", "mode": "custom", "rate": 0}), "invalid_rate");
      await expectRefusal(save({"currency": "COP", "mode": "custom", "rate": "lots"}), "invalid_rate");
      await expectRefusal(save({"currency": "COP", "mode": "feed"}), ErrorCodes.invalidField);
    });
  });

  test('each op asks for its cloud route\'s key: reading is money, charging and collecting money.charge (money.md ops)', () async {
    final account = tokens["accountId"] as String;
    grantKeys(master.openEngine, account, ["money", "money.charge"]);
    final (clerk, _) = await master.signIn();

    final payment = await record({"concept": "supplier", "amount": 100, "method": "cash"}, as: clerk);
    expect((await clerk.call(Ops.moneyPaymentsSearch) as Map)["total"], 1);
    await clerk.call(Ops.moneyCatalog);
    await clerk.call(Ops.moneySummary);
    await clerk.call(Ops.moneyReceivables);
    await clerk.call(Ops.moneyCurrenciesGet);

    await expectRefusal(write(Ops.moneyPaymentsVoid, {"id": payment["id"]}, as: clerk), ErrorCodes.forbidden);
    await expectRefusal(write(Ops.moneyCurrenciesSave, {"currency": "VES", "mode": "official"}, as: clerk),
      ErrorCodes.forbidden);

    grantKeys(master.openEngine, account, ["money"]);
    final (reader, _) = await master.signIn();
    await expectRefusal(record({"concept": "settlement", "amount": 100, "method": "cash"}, as: reader),
      ErrorCodes.forbidden);
  });
}
