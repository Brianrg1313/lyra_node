import 'dart:convert';
import 'dart:typed_data';

import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'net_support.dart';
import 'support.dart';

/// The company's payment accounts (`money.md` money.method) and the sealed key they are kept with
/// (plan §6.3). Rule numbers name what each test checks.
void main() {
  group('sealed keys', () {
    late Engine engine;
    late RecoveryKey recovery;

    setUp(() async {
      final paths = tempPaths(addTearDown);
      final vault = MemoryVault();
      recovery = (await setUpMaster(paths, vault,
        device: DeviceDraft(device: deviceNamed("Server"), publicKey: EcKeyPair.generate().spki))).recovery;
      engine = await Engine.open(paths: paths, vault: vault, hasher: fastHasher);
      addTearDown(engine.close);
    });

    Future<({String session, String refresh})> signIn(String password) async {
      final account = await engine.accounts.verifyPassword(owner.username, password);
      final tokens = engine.sessions.open(accountId: account.id, deviceId: engine.devices.master!.id);
      await engine.sealed.signedIn(account, password, sessionId: tokens.sessionId, refreshToken: tokens.refreshToken);

      return (session: tokens.sessionId, refresh: tokens.refreshToken);
    }

    test('the first holder makes the key, wrapped to them and to the recovery key; nothing in clear', () async {
      final first = await signIn(owner.password);
      final key = engine.sealed.key(first.session, SealedScope.payments)!;
      final second = await signIn(owner.password);

      expect(engine.sealed.key(second.session, SealedScope.payments), key);
      expect(engine.sealed.key(first.session, SealedScope.hr), isNotNull, reason: "the owner holds every scope");
      expect(await SealedKeys.recover(engine.store, SealedScope.payments, recovery), key);

      final holders = engine.store.db.select("SELECT scope, holder FROM sealed_keys ORDER BY scope, holder");
      expect(holders.length, 4);
      expect(engine.audit.list().where((entry) => entry.kind == AuditKinds.sealedKeyCreated).length, 2);

      final stored = engine.store.db.select("SELECT private FROM account_keys").first["private"] as Uint8List;
      expect(String.fromCharCodes(stored), isNot(contains(base64.encode(key))));
    });

    test('a refresh carries the keys to the new token, also after a restart forgot them', () async {
      final session = await signIn(owner.password);
      final key = engine.sealed.key(session.session, SealedScope.payments);

      // A restart: the keys in memory are gone, only the session's sealed copy is left.
      final restarted = SealedKeys(engine.store, params: fastParams);
      expect(restarted.key(session.session, SealedScope.payments), isNull);

      final rotated = engine.sessions.refresh(session.refresh, deviceId: engine.devices.master!.id);
      await restarted.refreshed(session.session, grants: {"*"}, previous: session.refresh, next: rotated.refreshToken);
      expect(restarted.key(session.session, SealedScope.payments), key);

      // The spent token no longer opens it; the session ending drops it.
      final again = SealedKeys(engine.store, params: fastParams);
      await again.refreshed(session.session, grants: {"*"}, previous: session.refresh, next: "x");
      expect(again.key(session.session, SealedScope.payments), isNull);

      engine.sessions.end(session.session);
      expect(restarted.key(session.session, SealedScope.payments), isNull);
      expect(engine.store.db.select("SELECT sealed FROM sessions WHERE id = ?", [session.session]).first["sealed"],
        isNull);
    });

    test('a refresh keeps only the scopes the grants still hold', () async {
      final session = await signIn(owner.password);
      final rotated = engine.sessions.refresh(session.refresh, deviceId: engine.devices.master!.id);

      await engine.sealed.refreshed(session.session,
        grants: {"finance.view"}, previous: session.refresh, next: rotated.refreshToken);

      expect(engine.sealed.key(session.session, SealedScope.payments), isNull);
    });

    test('a password change moves the private key to the new password', () async {
      final before = await signIn(owner.password);
      final key = engine.sealed.key(before.session, SealedScope.payments);
      final account = engine.accounts.byId(engine.sessions.accountOf(before.session)!)!;
      const password = "a brand new password";

      final hash = await engine.accounts.newPasswordHash(account.id, current: owner.password, password: password);
      final wrap = await engine.sealed.rewrap(account.id, current: owner.password, password: password);
      engine.store.write((_) {
        engine.accounts.setPassword(account.id, hash);
        engine.sealed.save(wrap!);
      });

      final after = await signIn(password);
      expect(engine.sealed.key(after.session, SealedScope.payments), key);
      await expectLater(engine.sealed.rewrap(account.id, current: owner.password, password: "whatever else"),
        throwsA(isA<EnvelopeError>()));
    });

    test('someone who doesn\'t hold the permission opens nothing', () async {
      final account = engine.accounts.byId(engine.store.db.select("SELECT id FROM accounts").first["id"] as String)!;
      engine.store.write((db) {
        db.execute("DELETE FROM grants");
        db.execute("INSERT INTO grants (account, permission) VALUES (?, 'finance.view')", [account.id]);
      });

      final session = await signIn(owner.password);

      expect(engine.sealed.key(session.session, SealedScope.payments), isNull);
      expect(engine.store.db.select("SELECT 1 FROM sealed_keys"), isEmpty);
      expect(engine.store.db.select("SELECT 1 FROM account_keys"), isNotEmpty, reason: "made for a later grant");
    });
  });

  group('money.methods over the LAN', () {
    late TestMaster master;
    late RpcClient client;
    late Map<String, Object?> tokens;

    Future<Object?> write(Op op, Map<String, Object?> args, {RpcClient? as, String? commandId}) =>
      (as ?? client).call(op, args: args, commandId: commandId ?? const Uuid().v7());

    Future<Map> create(Map<String, Object?> args, {RpcClient? as, String? commandId}) async =>
      await write(Ops.moneyMethodsCreate, args, as: as, commandId: commandId) as Map;

    Future<List<Map>> list([RpcClient? as]) async =>
      (((await (as ?? client).call(Ops.moneyMethodsList)) as Map)["methods"] as List).cast<Map>();

    const pagoMovil = {
      "code": "pago_movil", "label": "Pago móvil Banesco", "institution": "0134", "document": "v-12345678",
      "account": "04121234567", "holder": "Never asked", "currency": "USD",
    };

    setUp(() async {
      master = await TestMaster.start();
      (client, tokens) = await master.signIn();
    });

    test('the rails of the company\'s country, their sheets and lists (M-40, M-41)', () async {
      final rails = await client.call(Ops.moneyMethodsRails) as Map;
      final codes = [for (final rail in (rails["methods"] as List).cast<Map>()) rail["code"]];

      expect(rails["country"], "VE");
      expect(codes, ["cash", "card", "visa", "mastercard", "amex", "transfer", "paypal", "crypto", "binance", "check",
        "pago_movil", "zelle"]);
      expect((rails["methods"] as List).cast<Map>().firstWhere((rail) => rail["code"] == "pago_movil"), {
        "code": "pago_movil", "name": "Pago móvil", "method": "mobile", "methodName": "Pago móvil", "scope": "country",
        "currency": "VES", "icon": null, "reference": true, "change": false, "position": 200,
      });

      final fields = rails["fields"] as Map;
      expect([for (final field in (fields["pago_movil"] as List).cast<Map>()) field["field"]],
        ["institution", "document", "account"]);
      expect(fields["cash"], isEmpty);

      final options = rails["options"] as Map;
      expect((options["banks"] as List).length, 25);
      expect((options["documents"] as List).first, {"code": "V", "name": "Cédula"});
      expect((options["networks"] as List).length, 9);
    });

    test('created against its sheet; the answer and everything at rest keep the account sealed (M-41, M-42, M-45)',
        () async {
      final created = await create(pagoMovil);

      expect(created.keys, isNot(anyOf(contains("holder"), contains("document"), contains("account"))));
      expect(created, allOf(
        containsPair("institution", "0134"),
        containsPair("institutionName", "Banesco"),
        containsPair("currency", "VES"),
        containsPair("method", "mobile"),
        containsPair("reference", true),
        containsPair("position", 200),
      ));

      final row = (await list()).single;
      expect(row, allOf(
        containsPair("document", "V-12345678"),
        containsPair("account", "0412 123 45 67"),
        containsPair("holder", null),
        containsPair("label", "Pago móvil Banesco"),
      ));
      expect(((await client.call(Ops.moneyMethodsList)) as Map)["fields"], contains("pago_movil"));

      final db = master.openEngine.store.db;
      for (final (table, column) in [("money_methods", "sealed"), ("commands", "answer"), ("commands", "args_hash"),
          ("oplog", "payload")]) {
        for (final value in db.select("SELECT $column AS v FROM $table").map((row) => row["v"])) {
          final text = value is Uint8List ? latin1.decode(value) : "$value";
          expect(text, isNot(anyOf(contains("12345678"), contains("0412"))), reason: "$table.$column");
        }
      }
      expect(master.openEngine.audit.list().map((entry) => entry.kind), contains(AuditKinds.sealedRead));
    });

    test('a retried create makes one account, whatever the sealed fields say', () async {
      final commandId = const Uuid().v7();
      await create(pagoMovil, commandId: commandId);
      await create({...pagoMovil, "account": "04241111111"}, commandId: commandId);

      expect((await list()).length, 1);
    });

    test('refusals: rail, sheet, options, currency, fee, limit (M-40 to M-43)', () async {
      await expectRefusal(create({"code": "spei"}), "unknown_rail");
      await expectRefusal(create({"code": "account"}), "unknown_rail");
      await expectRefusal(create({...pagoMovil, "institution": null}), ErrorCodes.required);
      await expectRefusal(create({...pagoMovil, "institution": "9999"}), "invalid_option");
      await expectRefusal(create({...pagoMovil, "document": "X-123"}), "invalid_option");
      await expectRefusal(create({...pagoMovil, "document": "12345678"}), "invalid_option");
      await expectRefusal(create({"code": "cash", "currency": "EUR"}), "unknown_currency");
      await expectRefusal(create({"code": "cash", "feeType": "percent", "fee": 100}), "invalid_fee");
      await expectRefusal(create({"code": "cash", "feeType": "fixed", "fee": 0}), "invalid_fee");
      await expectRefusal(create({"code": "cash", "feeType": "fixed", "fee": 1.234}), "invalid_fee");
      await expectRefusal(create({"code": "cash", "feeType": "fixed", "fee": "-1"}), "invalid_fee");
      await expectRefusal(create({"code": "cash", "feeType": "gift"}), "invalid_fee");

      final crypto = await create({"code": "crypto", "institution": "trc20", "account": "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb"});
      expect(crypto["institution"], "TRC20");

      await write(Ops.moneyCurrenciesSave, {"currency": "EUR", "mode": "custom", "rate": 0.92});
      final euros = await create({"code": "cash", "label": "Caja en euros", "currency": "eur",
        "feeType": "percent", "fee": "2.50"});
      expect(euros["currency"], "EUR");
      expect(euros["fee"], {"type": "percent", "value": "2.5"});
      await expectRefusal(write(Ops.moneyCurrenciesRemove, {"currency": "EUR"}), "in_use");

      final main = await create({"code": "cash", "currency": "USD", "feeType": "fixed", "fee": "1.50"});
      expect(main["currency"], isNull, reason: "the main currency is stored as none");
      expect(main["fee"], {"type": "fixed", "value": 1.5});

      master.openEngine.store.write((db) {
        for (var i = 0; i < MoneyMethods.max - 3; i++) {
          db.execute("INSERT INTO money_methods (id, code, method, position, created, created_hlc, updated_hlc) "
            "VALUES (?, 'cash', 'cash', 10, '', '', '')", ["filler-$i"]);
        }
      });
      await expectRefusal(create({"code": "cash"}), "too_many_methods");
    });

    test('an edit merges over the row: left out keeps, null clears, the rail never changes (M-41, M-43)', () async {
      final id = (await create({...pagoMovil, "feeType": "percent", "fee": 3}))["id"];

      final relabelled = await write(Ops.moneyMethodsEdit, {"id": id, "label": "Banesco", "fee": 2}) as Map;
      expect(relabelled, allOf(containsPair("label", "Banesco"), containsPair("fee", {"type": "percent", "value": "2"})));

      await write(Ops.moneyMethodsEdit, {"id": id, "account": "0424-765.43.21", "feeType": "none", "fee": null});
      final row = (await list()).single;
      expect(row, allOf(containsPair("account", "0424 765 43 21"), containsPair("document", "V-12345678"),
        containsPair("fee", {"type": "none", "value": 0})));

      await expectRefusal(write(Ops.moneyMethodsEdit, {"id": id, "document": null}), ErrorCodes.required);
      await expectRefusal(write(Ops.moneyMethodsEdit, {"id": id, "code": "zelle"}), ErrorCodes.badRequest);
      await expectRefusal(write(Ops.moneyMethodsEdit, {"id": id}), ErrorCodes.badRequest);
      await expectRefusal(write(Ops.moneyMethodsEdit, {"id": "nope", "label": "x"}), ErrorCodes.notFound);
    });

    test('a payment names an account: its kind is the method; a removed one still reads (M-4, M-44)', () async {
      final id = (await create(pagoMovil))["id"];
      const base = {"concept": "supplier", "amount": 100};

      final paid = await write(Ops.moneyPaymentsRecord, {...base, "accountId": id}) as Map;
      expect(paid, allOf(containsPair("method", "mobile"), containsPair("accountId", id),
        containsPair("account", "Pago móvil Banesco")));
      await expectRefusal(write(Ops.moneyPaymentsRecord, {...base, "accountId": id, "method": "cash"}),
        "method_mismatch");

      await write(Ops.moneyMethodsRemove, {"id": id});
      expect(await list(), isEmpty);
      await expectRefusal(write(Ops.moneyMethodsRemove, {"id": id}), ErrorCodes.notFound);
      await expectRefusal(write(Ops.moneyPaymentsRecord, {...base, "accountId": id}), "unknown_account");

      final row = ((await client.call(Ops.moneyPaymentsSearch) as Map)["data"] as List).cast<Map>().single;
      expect(row["account"], "Pago móvil Banesco");
      expect(master.openEngine.audit.list().map((entry) => entry.kind), contains(AuditKinds.methodRemoved));
    });

    test('a session without the key: the list and a sealed account are locked, cash and removal are not (M-45)',
        () async {
      final id = (await create(pagoMovil))["id"];
      master.openEngine.sealed.dispose();

      await expectRefusal(client.call(Ops.moneyMethodsList), "sealed_locked");
      await expectRefusal(create(pagoMovil), "sealed_locked");
      await expectRefusal(write(Ops.moneyMethodsEdit, {"id": id, "account": "04120000000"}), "sealed_locked");
      await write(Ops.moneyMethodsEdit, {"id": id, "label": "Renamed"});
      await create({"code": "cash"});
      await write(Ops.moneyMethodsRemove, {"id": id});

      // Signing in again with the password opens it.
      final (again, _) = await master.signIn();
      expect((await list(again)).single["code"], "cash");
    });

    test('auth.refresh carries the key to the next access token', () async {
      await create(pagoMovil);
      final refreshed = await client.call(Ops.authRefresh, args: {"refreshToken": tokens["refreshToken"]}) as Map;
      final next = await master.connect();
      await next.call(Ops.sessionBind, args: {"accessToken": refreshed["accessToken"]});

      expect((await list(next)).single["account"], "0412 123 45 67");
    });

    test('each op asks for its own permission (money.md ops)', () async {
      final account = tokens["accountId"] as String;
      final id = (await create(pagoMovil))["id"];
      master.openEngine.store.write((db) {
        db.execute("DELETE FROM grants WHERE account = ?", [account]);
        db.execute("INSERT INTO grants (account, permission) VALUES (?, 'finance.methods.view')", [account]);
      });
      final (viewer, _) = await master.signIn();

      expect((await list(viewer)).single["document"], "V-12345678");
      await viewer.call(Ops.moneyMethodsRails);
      await expectRefusal(create({"code": "cash"}, as: viewer), ErrorCodes.forbidden);
      await expectRefusal(write(Ops.moneyMethodsEdit, {"id": id, "label": "x"}, as: viewer), ErrorCodes.forbidden);
      await expectRefusal(write(Ops.moneyMethodsRemove, {"id": id}, as: viewer), ErrorCodes.forbidden);

      master.openEngine.store.write((db) {
        db.execute("UPDATE grants SET permission = 'finance.view' WHERE account = ?", [account]);
      });
      final (outsider, _) = await master.signIn();
      await expectRefusal(outsider.call(Ops.moneyMethodsList), ErrorCodes.forbidden);
      await expectRefusal(outsider.call(Ops.moneyMethodsRails), ErrorCodes.forbidden);
    });
  });

  group('Rails', () {
    test('a mask spaces digits and leaves anything else as it was', () {
      expect(Rails.format("0000 000 00 00", "04121234567"), "0412 123 45 67");
      expect(Rails.format("0000 000 00 00", "0412123456789"), "0412 123 45 6789");
      expect(Rails.format("0000 000 00 00", "+58 412 1234567"), "+58 412 1234567");
      expect(Rails.format("0000 000 00 00", "pagos@tienda.com"), "pagos@tienda.com");
      expect(Rails.format(null, "0412"), "0412");
    });

    test('a closed field with no list in the country is typed instead (M-41)', () {
      final options = Rails.options("US");
      final transfer = Rails.sheet("transfer", options);

      expect(options.keys, ["networks"]);
      expect(transfer.firstWhere((field) => field.field == "institution").type, "text");
      expect(transfer.firstWhere((field) => field.field == "document").options, isNull);
      expect(Rails.offered("ach", "US", credit: false), isTrue);
      expect(Rails.offered("ach", "VE", credit: false), isFalse);
      expect(Rails.offered("unknown", "VE", credit: false), isFalse);
    });
  });
}
