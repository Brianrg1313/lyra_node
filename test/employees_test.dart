import 'dart:typed_data';

import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'net_support.dart';

/// The staff over the LAN (`employees.md`) and the activation of invited accounts (`session.md`
/// S-8). Rule numbers name what each test checks.
void main() {
  late TestMaster master;
  late RpcClient owner;
  late Engine engine;

  Future<Object?> write(Op op, Map<String, Object?> args, {RpcClient? as, String? commandId}) =>
    (as ?? owner).call(op, args: args, commandId: commandId ?? const Uuid().v7());

  Future<Map> invite(Map<String, Object?> args, {String? commandId}) async =>
    await write(Ops.employeesInvite, args, commandId: commandId) as Map;

  Future<Map> list([RpcClient? as]) async => await (as ?? owner).call(Ops.employeesList) as Map;

  Future<Map> detail(String id, [RpcClient? as]) async =>
    await (as ?? owner).call(Ops.employeesDetail, args: {"id": id}) as Map;

  Future<void> edit(String id, Map<String, Object?> changes, {RpcClient? as}) =>
    write(Ops.employeesEdit, {"id": id, ...changes}, as: as);

  /// A new device paired with a code, connected and said hello, as an invited person's phone.
  Future<RpcClient> phone() async {
    final pairing = await master.openPairing();
    final identity = await master.pairNative("Phone", code: pairing["code"] as String);

    return master.connect(identity);
  }

  /// [login] activates on [client] with [code] and binds the session.
  Future<Map> activate(RpcClient client, String login, String code, {String password = "a long new password"}) async {
    final tokens = await client.call(Ops.authActivate, args: {"login": login, "code": code, "password": password}) as Map;
    await client.call(Ops.sessionBind, args: {"accessToken": tokens["accessToken"]});

    return tokens;
  }

  /// Someone invited and activated on their own phone: the employment id and their client.
  Future<(String, RpcClient)> hire(String email, {String jobTitle = "Barista"}) async {
    final invited = await invite({"email": email, "jobTitle": jobTitle, "firstName": "Grace", "lastName": "Hopper"});
    final client = await phone();
    await activate(client, email, (invited["activation"] as Map)["code"] as String);

    return (invited["id"] as String, client);
  }

  String today() => Zones.local(engine.business.timezone, DateTime.now()).substring(0, 10);

  String shifted(int days) {
    final day = DateTime.parse("${today()}T00:00:00Z").add(Duration(days: days));

    return day.toIso8601String().substring(0, 10);
  }

  setUp(() async {
    master = await TestMaster.start();
    (owner, _) = await master.signIn();
    engine = master.openEngine;
  });

  group('invitations and activation', () {
    test('an unknown e-mail gets a pending account and a code shown once (E-10, S-8)', () async {
      final commandId = const Uuid().v7();
      final invited = await invite({"email": "Grace@Example.com", "jobTitle": "Barista"}, commandId: commandId);
      final activation = invited["activation"] as Map;

      expect(activation["code"], matches(RegExp(r"^\d{8}$")));
      expect(DateTime.parse(activation["expires"] as String).difference(DateTime.now()).inHours, inInclusiveRange(71, 72));

      final account = engine.store.db.select("SELECT * FROM accounts WHERE email = 'grace@example.com'").first;
      expect(account["status"], "pending");
      expect(account["username"], "grace");
      expect(account["password"], isNull);

      final stored = engine.store.db.select("SELECT code FROM activations").first["code"] as String;
      expect(stored, isNot(contains(activation["code"] as String)), reason: "only a hash is kept");

      // A replay answers without the code: it left the engine once.
      final replay = await invite({"email": "Grace@Example.com", "jobTitle": "Barista"}, commandId: commandId);
      expect(replay["id"], invited["id"]);
      expect(replay["activation"], isNull);
    });

    test('the list: the owner\'s unfiled card first, then the invitation with its e-mail (E-1)', () async {
      await invite({"email": "zoe@example.com", "jobTitle": "Cook", "firstName": "Zoe", "lastName": "Zed"});
      await invite({"username": "bob.b", "jobTitle": "Cashier", "firstName": "Bob"});

      final answer = await list();
      final cards = (answer["employees"] as List).cast<Map>();

      expect([for (final card in cards) card["username"]], ["ada.owner", "bob.b", "zoe"]);
      expect(cards.first["id"], isNull);
      expect(cards.first["me"], isTrue);
      expect(cards[2]["email"], "zoe@example.com");
      expect(cards[2]["state"], "invited");
      expect(cards[2]["branchId"], engine.business.site()["id"]);
      expect(answer["total"], 0, reason: "only active ones count");
    });

    test('already invited, already employed (E-10)', () async {
      await invite({"email": "grace@example.com", "jobTitle": "Barista"});
      await expectRefusal(invite({"email": "grace@example.com", "jobTitle": "Barista"}), "already_invited");
      await expectRefusal(invite({"jobTitle": "Barista"}), ErrorCodes.required);
      await expectRefusal(invite({"email": "not an e-mail", "jobTitle": "Barista"}), ErrorCodes.invalidField);

      final (_, _) = await hire("ada@example.com");
      await expectRefusal(invite({"email": "ada@example.com", "jobTitle": "Barista"}), "already_employed");
    });

    test('activating: identify says so, wrong codes and weak passwords refused, then signed in and hired (S-8)',
        () async {
      final invited = await invite({"email": "grace@example.com", "jobTitle": "Barista"});
      final code = (invited["activation"] as Map)["code"] as String;
      final client = await phone();

      expect(await client.call(Ops.authIdentify, args: {"login": "grace@example.com"}), {"method": "activation"});
      await expectRefusal(client.call(Ops.authActivate,
        args: {"login": "grace@example.com", "code": "00000000", "password": "a long new password"}), "invalid_code");
      await expectRefusal(client.call(Ops.authActivate,
        args: {"login": "nobody@example.com", "code": code, "password": "a long new password"}), "invalid_code");
      await expectRefusal(client.call(Ops.authActivate,
        args: {"login": "grace@example.com", "code": code, "password": "short"}), "weak_password");

      final tokens = await activate(client, "grace@example.com", code);
      expect(tokens["mustChangePassword"], isFalse);
      expect(engine.accounts.byId(tokens["accountId"] as String)!.status, AccountStatus.active);
      expect(await client.call(Ops.authIdentify, args: {"login": "grace"}), {"method": "password"});

      final mine = await detail(invited["id"] as String, client);
      expect(mine["state"], "active");
      expect(mine["responded"], isNotNull);

      // Spent: the same code doesn't work twice, and there's nothing left to reissue.
      await expectRefusal(client.call(Ops.authActivate,
        args: {"login": "grace@example.com", "code": code, "password": "a long new password"}), "invalid_code");
      await expectRefusal(write(Ops.employeesReissueActivation, {"id": invited["id"]}), "not_pending");
      expect(engine.audit.list().where((entry) => entry.kind == AuditKinds.accountActivated), hasLength(1));
    });

    test('five wrong codes void it; a reissued code works and the old one doesn\'t (E-11)', () async {
      final invited = await invite({"email": "grace@example.com", "jobTitle": "Barista"});
      final old = (invited["activation"] as Map)["code"] as String;
      final client = await phone();

      for (var i = 0; i < Accounts.maxActivationFailures; i++) {
        await expectRefusal(client.call(Ops.authActivate,
          args: {"login": "grace", "code": "1234567$i", "password": "a long new password"}), "invalid_code");
      }
      await expectRefusal(client.call(Ops.authActivate,
        args: {"login": "grace", "code": old, "password": "a long new password"}), "invalid_code");

      final reissued = await write(Ops.employeesReissueActivation, {"id": invited["id"]}) as Map;
      expect(reissued["code"], isNot(old));
      await activate(client, "grace", reissued["code"] as String);
    });

    test('an expired code says so (S-8)', () async {
      final invited = await invite({"email": "grace@example.com", "jobTitle": "Barista"});
      engine.store.write((db) => db.execute("UPDATE activations SET expires = '2020-01-01T00:00:00.000Z'"));

      await expectRefusal((await phone()).call(Ops.authActivate, args: {
        "login": "grace", "code": (invited["activation"] as Map)["code"], "password": "a long new password",
      }), "code_expired");
    });
  });

  group('the job and the person', () {
    test('job edits, cleared keys, dates, a manager and its cycle (E-12, E-14, E-15)', () async {
      final (boss, _) = await hire("boss@example.com", jobTitle: "Manager");
      final (barista, _) = await hire("barista@example.com");

      await edit(barista, {
        "DEPARTMENT": "Floor", "CONTRACT": "fixed_term", "WORKDAY": "part_time", "START_DATE": "2026-01-15",
        "END_DATE": "2027-01-14", "EMPLOYEE_CODE": "B-7", "WORK_EMAIL": "Bar@Cafe.com", "MANAGER_ID": boss,
        "BRANCH_ID": engine.business.site()["id"],
      });

      final job = (await detail(barista))["job"] as Map;
      expect(job["department"], "Floor");
      expect(job["contract"], "fixed_term");
      expect(job["workEmail"], "bar@cafe.com");
      expect((job["manager"] as Map)["id"], boss);
      expect(job["branchName"], engine.business.site()["name"]);

      await edit(barista, {"DEPARTMENT": ""});
      expect(((await detail(barista))["job"] as Map)["department"], isNull);

      await expectRefusal(edit(barista, {"JOB_TITLE": ""}), ErrorCodes.required);
      await expectRefusal(edit(barista, {"START_DATE": "2028-01-01"}), "invalid_dates");
      await expectRefusal(edit(barista, {"END_DATE": "2026-02-30"}), ErrorCodes.invalidField);
      await expectRefusal(edit(barista, {"CONTRACT": "forever"}), ErrorCodes.invalidField);
      await expectRefusal(edit(barista, {"BRANCH_ID": "elsewhere"}), ErrorCodes.invalidField);
      await expectRefusal(edit(barista, {"COLOR": "blue"}), ErrorCodes.invalidField);
      await expectRefusal(edit(boss, {"MANAGER_ID": barista}), "manager_cycle");
      await expectRefusal(edit(boss, {"MANAGER_ID": boss}), "manager_cycle");
    });

    test('the person\'s keys need an active job (E-12)', () async {
      final invited = await invite({"email": "grace@example.com", "jobTitle": "Barista"});

      await expectRefusal(edit(invited["id"] as String, {"PHONE": "+58 412 1234567"}), "profile_locked");
      await edit(invited["id"] as String, {"SALARY": "400"});
    });

    test('measured on the company\'s day: work and contract status, tenure (E-4)', () async {
      final (id, _) = await hire("grace@example.com");

      await edit(id, {"START_DATE": shifted(3)});
      var read = await detail(id);
      expect(read["workStatus"], "not_started");
      expect(read["contractStatus"], "pending");
      expect(read["tenure"], {"years": 0, "months": 0, "days": 0, "totalDays": 0});

      await edit(id, {"START_DATE": shifted(-400), "END_DATE": shifted(10)});
      read = await detail(id);
      expect(read["workStatus"], "working");
      expect(read["contractStatus"], "expiring");
      expect((read["tenure"] as Map)["totalDays"], 400);
      expect((read["tenure"] as Map)["years"], 1);
      expect(read["companySince"], shifted(-400));
      expect(read["companyDays"], 400);

      await edit(id, {"END_DATE": shifted(-1), "START_DATE": shifted(-30)});
      expect((await detail(id))["contractStatus"], "expired");

      await edit(id, {"END_DATE": ""});
      expect((await detail(id))["contractStatus"], "current");
    });
  });

  group('sealed fields', () {
    test('pay and the profile: never in clear at rest, the oplog or the ledger (E-16, plan §6.3)', () async {
      final (id, _) = await hire("grace@example.com");

      await edit(id, {"SALARY": "1500.5", "SALARY_CURRENCY": "USD", "PAY_PERIOD": "month", "NOTES": "Trusted keyholder",
        "PHONE": "+58 412 7654321", "DOCUMENT_NUMBER": "V-99887766", "BIRTHDAY": "1990-12-09", "SEX": "female"});

      final read = await detail(id);
      final job = read["job"] as Map;
      final person = read["person"] as Map;
      expect(read["fullProfile"], isTrue);
      expect(job["salary"], 1500.5);
      expect(job["payPeriod"], "month");
      expect(job["notes"], "Trusted keyholder");
      expect(person["phone"], "+58 412 7654321");
      expect(person["documentNumber"], "V-99887766");
      expect(person["email"], "grace@example.com");

      final db = engine.store.db;
      final atRest = [
        for (final row in db.select("SELECT hr, own FROM sealed_fields")) ...[
          String.fromCharCodes(row["hr"] as Uint8List),
          if (row["own"] != null) String.fromCharCodes(row["own"] as Uint8List),
        ],
        for (final row in db.select("SELECT payload FROM oplog")) "${row["payload"]}",
        for (final row in db.select("SELECT * FROM commands")) "$row",
      ].join("\n");
      for (final secret in ["1500.5", "Trusted keyholder", "7654321", "99887766", "1990-12-09"]) {
        expect(atRest, isNot(contains(secret)), reason: secret);
      }

      expect(engine.audit.list().where((entry) => entry.kind == AuditKinds.sealedRead), hasLength(1));
      await detail(id);
      expect(engine.audit.list().where((entry) => entry.kind == AuditKinds.sealedRead), hasLength(1),
        reason: "once per session per employee");
    });

    test('salary checks: decimals of its currency, an available currency, never negative (E-15)', () async {
      final (id, _) = await hire("grace@example.com");

      await expectRefusal(edit(id, {"SALARY": "10.123"}), ErrorCodes.invalidField);
      await expectRefusal(edit(id, {"SALARY": "-1"}), ErrorCodes.invalidField);
      await expectRefusal(edit(id, {"SALARY_CURRENCY": "EUR"}), ErrorCodes.invalidField);

      await edit(id, {"SALARY": "0"});
      expect(((await detail(id))["job"] as Map)["salary"], 0, reason: "zero is filed, unlike null");
      await edit(id, {"SALARY": ""});
      expect(((await detail(id))["job"] as Map)["salary"], isNull);
    });

    test('the person reads their own, without notes, and writes their own profile (E-3, E-13)', () async {
      final (id, grace) = await hire("grace@example.com");

      await edit(id, {"SALARY": "800", "NOTES": "Company only", "CITY": "Caracas"});

      final mine = await detail(id, grace);
      expect(mine["fullProfile"], isTrue);
      expect((mine["job"] as Map)["salary"], 800);
      expect((mine["job"] as Map).containsKey("notes"), isFalse);
      expect((mine["person"] as Map)["city"], "Caracas");

      await write(Ops.profileEdit, {"PHONE": "+58 414 0000001", "FIRST_NAME": "Gracie"}, as: grace);
      final seen = await detail(id);
      expect((seen["person"] as Map)["phone"], "+58 414 0000001");
      expect((seen["person"] as Map)["name"], "Gracie");

      await expectRefusal(write(Ops.profileEdit, {"SALARY": "9000"}, as: grace), ErrorCodes.forbidden);
      await expectRefusal(write(Ops.profileEdit, {"JOB_TITLE": "Owner"}, as: grace), ErrorCodes.forbidden);
      await expectRefusal(write(Ops.profileEdit, {"FIRST_NAME": ""}, as: grace), ErrorCodes.required);
    });

    test('written before the person had a key, they read it once an hr holder opened it', () async {
      final invited = await invite({"email": "grace@example.com", "jobTitle": "Barista"});
      final id = invited["id"] as String;
      await edit(id, {"SALARY": "650"});

      final grace = await phone();
      await activate(grace, "grace", (invited["activation"] as Map)["code"] as String);

      expect(((await detail(id, grace))["job"] as Map)["salary"], isNull, reason: "no copy of theirs yet");
      await detail(id);
      expect(((await detail(id, grace))["job"] as Map)["salary"], 650);
    });
  });

  group('permissions', () {
    void grant(String account, List<String> permissions) => engine.store.write((db) {
      db.execute("DELETE FROM grants WHERE account = ?", [account]);
      for (final permission in permissions) {
        db.execute("INSERT INTO grants (account, permission) VALUES (?, ?)", [account, permission]);
      }
    });

    /// [login] signed in again on a new connection (the master's app), so its grants are re-read.
    Future<RpcClient> again(String login) async {
      final client = await master.connect();
      final tokens = await client.call(Ops.authSignIn, args: {"login": login, "password": "a long new password"}) as Map;
      await client.call(Ops.sessionBind, args: {"accessToken": tokens["accessToken"]});

      return client;
    }

    test('without the view: only one\'s own card and detail; no former list (E-1, E-2, E-3)', () async {
      final (other, _) = await hire("other@example.com");
      final (id, _) = await hire("grace@example.com");
      final grace = await again("grace");

      final cards = ((await list(grace))["employees"] as List).cast<Map>();
      expect([for (final card in cards) card["id"]], [id]);
      expect(cards.single["me"], isTrue);

      await expectRefusal(detail(other, grace), ErrorCodes.notFound);
      await expectRefusal(grace.call(Ops.employeesFormer), ErrorCodes.forbidden);
      await expectRefusal(write(Ops.employeesInvite, {"email": "x@example.com", "jobTitle": "X"}, as: grace),
        ErrorCodes.forbidden);
    });

    test('the view without view_personal: no private fields, and no pay or person edits (E-3, E-12)', () async {
      final (id, _) = await hire("grace@example.com");
      final (_, viewerClient) = await hire("viewer@example.com");
      await edit(id, {"SALARY": "700", "CITY": "Maracay"});

      final viewerAccount = engine.store.db.select("SELECT id FROM accounts WHERE username = 'viewer'").first["id"] as String;
      grant(viewerAccount, ["business.view", "business.employees.view", "business.employees.invite"]);
      await viewerClient.close();
      final viewer = await again("viewer");

      final seen = await detail(id, viewer);
      expect(seen["fullProfile"], isFalse);
      expect(seen["person"], isNot(contains("city")));
      expect(seen["job"], isNot(contains("salary")));

      await edit(id, {"DEPARTMENT": "Bar"}, as: viewer);
      await expectRefusal(edit(id, {"SALARY": "900"}, as: viewer), ErrorCodes.forbidden);
      await expectRefusal(edit(id, {"CITY": "Valencia"}, as: viewer), ErrorCodes.forbidden);
    });
  });
}
