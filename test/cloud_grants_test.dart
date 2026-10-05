import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'net_support.dart';
import 'support.dart';
import 'support/edge_cloud.dart';

/// The cloud grant (`session.md` S-12, S-13; `task-edge-sync-backend.md` §9): someone signed in online
/// opens their session on the master with the backend's signed statement, checked here offline, once.
void main() {
  late TestMaster master;
  late Engine engine;
  late EdgeCloud cloud;
  late String device;
  late RpcClient client;

  const email = "ada@example.com";

  setUp(() async {
    master = await TestMaster.start();
    engine = master.openEngine;
    cloud = EdgeCloud();

    final ownerId = (await engine.accounts.verifyPassword(owner.username, owner.password)).id;
    engine.store.db.execute("UPDATE accounts SET email = ? WHERE id = ?", [email, ownerId]);
    engine.business.link(cloud.company, actor: ownerId);
    final enrolment = cloud.enroll(engine.instanceId, await engine.edge.prepare());
    device = enrolment.device;
    engine.edge.enroll(enrolment);

    client = await master.connect();
  });

  Future<Map> redeem(String grant) async => await client.call(Ops.authGrant, args: {"grant": grant}) as Map;

  test('a grant opens the session of the account with its e-mail, without the sealed keys', () async {
    final tokens = await redeem(await cloud.grant(device, "ADA@example.com"));

    expect(tokens["sealed"], isFalse);
    expect(tokens["mustChangePassword"], isFalse);
    await client.call(Ops.sessionBind, args: {"accessToken": tokens["accessToken"]});
    expect(((await client.call(Ops.sessionBootstrap) as Map)["client"] as Map)["email"], email);

    await expectRefusal(client.call(Ops.moneyMethodsList), "sealed_locked");
    expect(engine.audit.list().map((entry) => entry.kind), contains(AuditKinds.signedIn));
  });

  test('used once, for this master and its company, signed by the pinned key, in time', () async {
    final grant = await cloud.grant(device, email);
    await redeem(grant);
    await expectRefusal(redeem(grant), "grant_used");

    await expectRefusal(redeem(await cloud.grant("d-other", email)), "grant_invalid");
    await expectRefusal(redeem(await cloud.grant(device, email, payload: {"company": "c-other"})), "grant_invalid");
    await expectRefusal(redeem(await cloud.grant(device, email, seed: List.filled(32, 9))), "grant_invalid");
    await expectRefusal(redeem(await cloud.grant(device, email, payload: {"kid": "2027-01"})), "grant_invalid");
    await expectRefusal(redeem(await cloud.grant(device, email, payload: {"v": 2})), "grant_invalid");
    await expectRefusal(redeem("not.a-grant"), "grant_invalid");

    final old = DateTime.now().subtract(const Duration(minutes: 3));
    await expectRefusal(redeem(await cloud.grant(device, email, now: old)), "grant_expired");

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await expectRefusal(redeem(await cloud.grant(device, email, payload: {"exp": now + 3600})), "grant_invalid");

    // A forged payload under a real signature: the bytes signed are the bytes read.
    final [payload, signature] = (await cloud.grant(device, email)).split(".");
    await expectRefusal(redeem("${payload}A.$signature"), "grant_invalid");
  });

  test('nobody with that e-mail, or one not active, opens nothing', () async {
    await expectRefusal(redeem(await cloud.grant(device, "grace@example.com")), "grant_no_account");

    engine.store.write((_) => engine.employees.invite(
      {"email": "grace@example.com", "username": "grace", "jobTitle": "Barista"},
      actor: Grants.owner(engine.store.db)!,
    ));
    await expectRefusal(redeem(await cloud.grant(device, "grace@example.com")), "grant_no_account");

    engine.store.db.execute("UPDATE accounts SET status = 'disabled' WHERE email = 'grace@example.com'");
    await expectRefusal(redeem(await cloud.grant(device, "grace@example.com")), "account_disabled");
  });

  test('a revoked master takes none', () async {
    final grant = await cloud.grant(device, email);
    engine.store.db.execute("UPDATE sync_link SET revoked = 1");

    await expectRefusal(redeem(grant), "grant_invalid");
  });

  test('the password opens the sealed keys of a granted session, under a rotated token (S-13)', () async {
    final tokens = await redeem(await cloud.grant(device, email));
    await client.call(Ops.sessionBind, args: {"accessToken": tokens["accessToken"]});
    final job = engine.store.db.select("SELECT id FROM employments WHERE account = ?", [Grants.owner(engine.store.db)])
      .first["id"];
    final locked = await client.call(Ops.employeesDetail, args: {"id": job}) as Map;
    expect((locked["fullProfile"], locked["sealedLocked"]), (false, true));

    await expectRefusal(
      client.call(Ops.authUnseal, args: {"refreshToken": tokens["refreshToken"], "password": "wrong password"}),
      "invalid_credentials",
    );

    final next = await client.call(Ops.authUnseal, args: {"refreshToken": tokens["refreshToken"], "password": owner.password})
      as Map;
    expect(next["refreshToken"], isNot(tokens["refreshToken"]));
    await client.call(Ops.sessionBind, args: {"accessToken": next["accessToken"]});

    final whole = await client.call(Ops.employeesDetail, args: {"id": job}) as Map;
    expect((whole["fullProfile"], whole["sealedLocked"]), (true, false));

    final methods = await client.call(Ops.moneyMethodsList) as Map;
    expect(methods["methods"], isEmpty);
    await client.call(Ops.moneyMethodsCreate, commandId: const Uuid().v7(), args: {
      "code": "pago_movil", "label": "Pago móvil", "institution": "0134", "document": "v-12345678",
      "account": "04121234567", "holder": "Ada", "currency": "USD",
    });

    // The rotated token is the session's now; the old one ends it, as any reuse does (S-21).
    await expectRefusal(
      client.call(Ops.authUnseal, args: {"refreshToken": tokens["refreshToken"], "password": owner.password}),
      ErrorCodes.sessionExpired,
    );
  });
}
