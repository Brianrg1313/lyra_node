import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'net_support.dart';

/// The cloud's permission system on a master (`session.md` session.permissions). Rule numbers name
/// what each test checks.
void main() {
  late TestMaster master;
  late RpcClient owner;
  late Engine engine;

  Future<Object?> write(Op op, Map<String, Object?> args, {RpcClient? as}) =>
    (as ?? owner).call(op, args: args, commandId: const Uuid().v7());

  Future<Map> assign(String username, {String? template, Map<String, Object?>? permissions, RpcClient? as}) async =>
    await write(Ops.permissionsMembersAssign, {
      "username": username,
      "template": ?template,
      "permissions": ?permissions,
    }, as: as) as Map;

  Future<Map> member(String username, [RpcClient? as]) async =>
    await (as ?? owner).call(Ops.permissionsMembersDetail, args: {"username": username}) as Map;

  /// Someone invited and activated on a phone of their own: their bound client.
  Future<RpcClient> hire(String email) async {
    final invited = await write(Ops.employeesInvite, {"email": email, "jobTitle": "Barista"}) as Map;
    final client = await master.connect(await master.pairNative("Phone", code: (await master.openPairing())["code"] as String));
    final tokens = await client.call(Ops.authActivate, args: {
      "login": email,
      "code": (invited["activation"] as Map)["code"],
      "password": "a long new password",
    }) as Map;
    await client.call(Ops.sessionBind, args: {"accessToken": tokens["accessToken"]});

    return client;
  }

  Future<Map> bootstrap(RpcClient client) async => await client.call(Ops.sessionBootstrap) as Map;

  setUp(() async {
    master = await TestMaster.start();
    (owner, _) = await master.signIn();
    engine = master.openEngine;
  });

  group('membership', () {
    test('a job admits with nothing granted: the company, and no area of it (P-5)', () async {
      final grace = await hire("grace@example.com");
      final answer = await bootstrap(grace);
      final company = (answer["businesses"] as List).single as Map;

      // `business.view` and the branch list are every member's in the cloud too.
      expect(answer["permissions"], {
        company["id"]: {"business": {"view": true, "branches": {"view": true}}},
      });
      expect(answer["owned"], isEmpty);
      expect((await member("grace"))["access"], isTrue);
      await expectRefusal(grace.call(Ops.inventoryTablesList), ErrorCodes.forbidden);
    });

    test('nobody else is a member: an unknown username or one without a job (P-6)', () async {
      await expectRefusal(member("nobody"), "permission_member_not_found");
      await expectRefusal(assign("nobody", template: "seller"), "permission_member_not_found");
    });
  });

  group('assigning', () {
    test('a template is copied, a key changed after marks it custom, and the session sees it at once (P-7, P-8)', () async {
      final grace = await hire("grace@example.com");
      final events = <RpcEvent>[];
      final subscription = grace.events.listen(events.add);
      addTearDown(subscription.cancel);
      await grace.call(Ops.eventsSubscribe);

      await assign("grace", template: "seller");
      var card = await member("grace");
      expect(card["template"], {"scope": "global", "id": "seller", "name": "Seller"});
      expect(card["custom"], isFalse);
      expect(((card["sections"] as Map)["pos"] as Map)["sell"], isTrue);

      // The open session checks the new permissions from its next frame.
      await grace.call(Ops.posSummary);

      await assign("grace", permissions: {"pos": {"sell": false}});
      card = await member("grace");
      expect(card["custom"], isTrue);
      expect(((card["sections"] as Map)["pos"] as Map)["sell"], isFalse);
      expect((card["template"] as Map)["id"], "seller");

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect([for (final event in events) if (event.event == Events.permissionsChanged) event.data], [
        {"accountId": engine.permissions.accountOf("grace")},
        {"accountId": engine.permissions.accountOf("grace")},
      ]);
      final tree = ((await bootstrap(grace))["permissions"] as Map).values.single as Map;
      expect(tree["pos"], {"view": true});
    });

    test('nobody changes themselves or the owner (P-6)', () async {
      final grace = await hire("grace@example.com");
      await assign("grace", template: "manager");

      await expectRefusal(assign("grace", template: "seller", as: grace), "permissions_self");
      await expectRefusal(assign("ada.owner", template: "seller", as: grace), "permissions_owner");
      await expectRefusal(assign("ada.owner", template: "seller"), "permissions_self");
    });

    test('nobody gives or takes what they don\'t hold; all needs all (P-6)', () async {
      final grace = await hire("grace@example.com");
      await hire("alan@example.com");
      await assign("grace", template: "manager");
      await assign("alan", template: "finance");

      // A manager holds money and money.void, not money.accounts: takes the one, not the other.
      await assign("alan", permissions: {"money": {"void": false}}, as: grace);
      await expectRefusal(assign("alan", permissions: {"money": {"accounts": false}}, as: grace), "escalation");
      await expectRefusal(assign("alan", template: "seller", as: grace), "escalation");
      await expectRefusal(assign("alan", template: "owner", as: grace), "escalation");

      await assign("alan", template: "seller");
      await assign("alan", permissions: {"pos": {"cancel": true}}, as: grace);
      await expectRefusal(assign("alan", permissions: {"server": {"access": true}}, as: grace), "escalation");
    });

    test('an unknown key is refused, never dropped', () async {
      await hire("grace@example.com");

      await expectLater(
        assign("grace", permissions: {"money": {"teleport": true}}),
        throwsA(isA<RpcError>()
          .having((error) => error.code, "code", "permissions_invalid")
          .having((error) => error.data, "data", {"key": "money.teleport"})),
      );
      await expectRefusal(assign("grace", template: "pirate"), "permission_template_not_found");
    });

    test('a revoke takes the access and keeps the document; giving it back starts from it (P-5, P-8)', () async {
      final grace = await hire("grace@example.com");
      await assign("grace", template: "seller");

      await write(Ops.permissionsMembersRevoke, {"username": "grace"});
      expect((await bootstrap(grace))["businesses"], isEmpty);
      await expectRefusal(grace.call(Ops.posSummary), ErrorCodes.forbidden);
      expect((await owner.call(Ops.permissionsMembersList) as List).map((card) => (card as Map)["username"]), ["ada.owner"]);

      await assign("grace");
      expect(((await member("grace"))["template"] as Map)["id"], "seller");
      await grace.call(Ops.posSummary);
    });
  });

  group('templates', () {
    test('global ones first and read-only; a company\'s own is made, edited and removed, keeping copies (P-7)', () async {
      await hire("grace@example.com");
      final made = await write(Ops.permissionsTemplatesCreate, {
        "name": "Cashier",
        "from": "seller",
        "permissions": {"pos": {"cancel": true}},
      }) as Map;

      final templates = (await owner.call(Ops.permissionsTemplatesList) as List).cast<Map>();
      expect([for (final template in templates) template["id"]],
        [for (final preset in PermissionPresets.all) preset.code, made["id"]]);
      expect(((templates.last["sections"] as Map)["pos"] as Map)["cancel"], isTrue);

      await expectRefusal(write(Ops.permissionsTemplatesCreate, {"name": "cashier"}), "permission_template_name_taken");
      await expectRefusal(write(Ops.permissionsTemplatesEdit, {"id": "seller", "name": "x"}), "permission_template_global");

      await assign("grace", template: made["id"] as String);
      await write(Ops.permissionsTemplatesEdit, {"id": made["id"], "permissions": {"pos": {"sell": false}}});
      expect((((await member("grace"))["sections"] as Map)["pos"] as Map)["sell"], isTrue, reason: "a copy, not a link");

      await write(Ops.permissionsTemplatesRemove, {"id": made["id"]});
      final card = await member("grace");
      expect(card["template"], isNull);
      expect(((card["sections"] as Map)["pos"] as Map)["cancel"], isTrue);
    });
  });

  group('requests', () {
    test('asking records the area and its keys, grants nothing, and reads granted once held (P-10, P-11)', () async {
      final grace = await hire("grace@example.com");
      Future<Object?> ask(String permission) =>
        write(Ops.permissionsRequestsCreate, {"permission": permission, "reason": " for the till "}, as: grace);

      await ask("pos.sell");
      await expectRefusal(ask("pos.sell"), "permission_request_pending");
      await expectRefusal(ask("business.delete"), "permission_request_owner");
      await expectRefusal(ask("nowhere.view"), "permission_request_invalid");
      await expectRefusal(ask("business.view"), "permission_request_granted");

      final stored = engine.store.db.select("SELECT * FROM permission_requests").single;
      expect(stored["keys"], '["pos.sell","pos"]');
      expect(stored["reason"], "for the till");

      var mine = (await grace.call(Ops.permissionsRequestsList) as List).cast<Map>();
      expect(mine.single["state"], "pending");

      await assign("grace", permissions: {"pos": {"access": true, "sell": true}});
      mine = (await grace.call(Ops.permissionsRequestsList) as List).cast<Map>();
      expect(mine.single["state"], "granted");
    });
  });

  test('permissions.get answers the catalog and one\'s own document', () async {
    final answer = await owner.call(Ops.permissionsGet) as Map;

    expect(answer["catalog"], PermissionCatalog.describe());
    expect((answer["mine"] as Map)["all"], isTrue);
    expect((answer["mine"] as Map)["template"], {"scope": "global", "id": "owner"});
  });
}
