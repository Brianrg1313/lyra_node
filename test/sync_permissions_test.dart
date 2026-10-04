import 'dart:convert';

import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support.dart';
import 'support/edge_cloud.dart';

/// Permissions on a master that syncs are the cloud's (`session.md` P-12, plan §9.3): the cloud's
/// document for each person comes down as `member` and is what counts here, the master's own
/// editor refuses meanwhile, and the first upload carries what the master had.
void main() {
  late Engine engine;
  late EdgeCloud cloud;
  late String owner;
  late String device;

  Database db() => engine.store.db;

  setUp(() async {
    final paths = tempPaths(addTearDown);
    final vault = MemoryVault();
    await setUpMaster(paths, vault);
    engine = await Engine.open(paths: paths, vault: vault, hasher: fastHasher);
    addTearDown(engine.close);

    owner = (await engine.accounts.verifyPassword("ada.owner", "correct horse battery")).id;
    cloud = EdgeCloud();
  });

  Future<void> enroll() async {
    engine.business.link(cloud.company, actor: owner);
    final enrolment = cloud.enroll(engine.instanceId, await engine.edge.prepare());
    device = enrolment.device;
    engine.edge.enroll(enrolment);
  }

  Future<SyncReport> cycle() => engine.edge.cycle(cloud);

  /// Someone invited and in, as the activation leaves them: admitted with nothing (P-5).
  String hire(String username, String email) => engine.store.write((_) {
    engine.employees.invite({"email": email, "username": username, "jobTitle": "Barista"}, actor: owner);
    final account = db().select("SELECT id FROM accounts WHERE email = ?", [email]).first["id"] as String;
    // What typing the activation code does, without the password.
    db().execute("UPDATE accounts SET status = 'active' WHERE id = ?", [account]);
    engine.employees.acceptInvitations(account);

    return account;
  });

  Map<String, Object?> assign(String username, Map<String, Object?> args) => engine.store.write((_) =>
    engine.permissions.assign({"username": username, ...args}, actor: owner, mine: Grant.everything()));

  Map<String, Object?> document({bool access = true, List<String> keys = const [], String? email}) => {
    "email": ?email,
    "access": access,
    "all": false,
    "sections": PermissionCatalog.fromKeys(keys),
    "template": null,
    "custom": true,
  };

  test("the first upload carries each person's permissions, for the cloud to admit them with", () async {
    final grace = hire("grace", "grace@example.com");
    assign("grace", {"template": "seller"});
    await enroll();
    await cycle();

    final record = cloud.record("account", cloud.cloudIdOf(device, "account", grace)!)!;
    final permissions = record.fields["permissions"] as Map;
    expect(permissions["access"], isTrue);
    expect(permissions["all"], isFalse);
    expect(permissions["template"], {"scope": "global", "id": "seller"});
    expect(((permissions["sections"] as Map)["pos"] as Map)["sell"], isTrue);
  });

  test("the cloud's document is what counts here, and the person's sessions are told at once", () async {
    final grace = hire("grace", "grace@example.com");
    assign("grace", {"template": "seller"});
    await enroll();
    await cycle();
    final cloudGrace = cloud.cloudIdOf(device, "account", grace)!;
    engine.takePulledGrants();

    cloud.edit("member", cloudGrace, fields: document(keys: ["money", "money.charge"], email: "grace@example.com"));
    await cycle();

    final grant = Grants.of(db(), grace);
    expect(grant.can("money.charge"), isTrue);
    expect(grant.can("pos.sell"), isFalse, reason: "the cloud's whole document, not laid over the master's");
    expect(engine.takePulledGrants(), [grace]);
    final event = db().select("SELECT data, audience FROM events WHERE name = ? ORDER BY seq DESC", [Events.permissionsChanged]).first;
    expect(jsonDecode(event["data"] as String), {"accountId": grace});
    expect(jsonDecode(event["audience"] as String), {"accounts": [grace]});
    expect(
      db().select("SELECT 1 FROM audit WHERE kind = ? AND device = ?", [AuditKinds.permissionsAssigned, edgeOrigin]),
      isNotEmpty,
    );

    // Out of the company in the cloud: out here, the document kept.
    cloud.delete("member", cloudGrace);
    await cycle();
    expect(Grants.hasAccess(db(), grace), isFalse);
    expect(Grants.read(db(), grace)!.sections!["money"]!["charge"], isTrue);
  });

  test('a person the cloud names by e-mail only is found by it, and the owner stays the owner', () async {
    final grace = hire("grace", "grace@example.com");
    await enroll();
    await cycle();

    cloud.edit("member", "c-elsewhere", fields: document(keys: ["pos", "pos.sell"], email: "GRACE@example.com"));
    cloud.edit("member", "c-ada", fields: document(access: false, email: "ada@example.com"));
    db().execute("UPDATE accounts SET email = 'ada@example.com' WHERE id = ?", [owner]);
    await cycle();

    expect(Grants.of(db(), grace).can("pos.sell"), isTrue);
    expect(Grants.of(db(), owner).all, isTrue);
  });

  test("someone with no account here yet gets the cloud's document when they are admitted", () async {
    await enroll();
    await cycle();

    cloud.edit("member", "c-linus", fields: document(keys: ["products"], email: "linus@example.com"));
    await cycle();
    expect(engine.takePulledGrants(), isEmpty);

    final linus = hire("linus", "linus@example.com");
    expect(Grants.of(db(), linus).can("products"), isTrue);
  });

  test("while the master syncs its permissions aren't changed here; revoked, they are again", () async {
    hire("grace", "grace@example.com");
    await enroll();

    expect(() => assign("grace", {"template": "seller"}),
      throwsA(isA<EngineFailure>().having((failure) => failure.code, "code", "permissions_online")));
    expect(() => engine.store.write((_) => engine.permissions.revoke("grace", actor: owner, mine: Grant.everything())),
      throwsA(isA<EngineFailure>().having((failure) => failure.code, "code", "permissions_online")));
    expect(() => engine.store.write((_) => engine.permissions.createTemplate({"name": "Night shift"}, actor: owner)),
      throwsA(isA<EngineFailure>().having((failure) => failure.code, "code", "permissions_online")));
    expect(engine.permissions.get(owner)["online"], isTrue);
    expect(engine.permissions.member("grace", viewer: owner)["online"], isTrue);

    cloud.revoke(device);
    await cycle();

    expect(engine.permissions.get(owner)["online"], isFalse);
    expect(assign("grace", {"template": "seller"}), {"username": "grace"});
  });

  test('past the allowance the sync pauses, and so does the cloud owning the permissions', () async {
    hire("grace", "grace@example.com");
    await enroll();
    await cycle();

    cloud.allowance = EdgeAllowance.exceeded;
    await cycle();

    expect(assign("grace", {"template": "seller"}), {"username": "grace"});
  });
}
