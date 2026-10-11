import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support.dart';
import 'support/edge_cloud.dart';

/// A master is one site of its cloud company (the backend's branches): it sells at its site's own
/// price (`price`, `pos.md` POS-7b) and lets a person in as their document says for this site
/// (`member.branches` / `member.at`, `session.md`).
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

  group("price", () {
    late String table;
    late String rice;
    late String cloudRice;

    /// The counter's price of rice, in minor units.
    int? sells() => ((engine.pos.catalog(size: 10)["data"] as Map)["values"] as List).single[4] as int?;

    setUp(() async {
      table = engine.inventory.createTable({"title": "Pantry", "color": "0xFF60A5FA", "template": "FOOD"}, actor: owner)["id"] as String;
      engine.inventory.createField({"tableId": table, "name": "Offer", "type": FieldTypes.discount, "position": 99}, actor: owner);
      final fields = {
        for (final row in db().select("SELECT id, type FROM inventory_fields WHERE table_id = ?", [table])) row["type"] as String: row["id"] as String,
      };
      rice = engine.inventory.createRecord(table, {
        fields[FieldTypes.title]!: "Rice", fields[FieldTypes.price]!: "10.00", fields[FieldTypes.discount]!: "10",
      }, decimals: 2, actor: owner)["id"] as String;
      engine.stock.move(operation: "add", tableId: table, productId: rice, quantity: 5, actor: owner);

      await enroll();
      await cycle();
      cloudRice = cloud.cloudIdOf(device, "product", rice)!;
    });

    test("the site's own price replaces the catalog's, and its offer the product's unless it inherits it", () async {
      expect(sells(), 900, reason: "the catalog's, net of its offer (POS-7)");

      final price = cloud.create("price", {"product": cloudRice, "price": "12.50", "discount": null, "inheritsDiscount": true});
      await cycle();
      expect(sells(), 1125, reason: "the site's price, the product's offer still on");

      cloud.edit("price", price, fields: {"inheritsDiscount": false, "discount": null});
      await cycle();
      expect(sells(), 1250, reason: "not on offer at this site");

      cloud.edit("price", price, fields: {"price": null, "discount": "50"});
      await cycle();
      expect(sells(), 500, reason: "the catalog's price at the site's offer");

      cloud.delete("price", price);
      await cycle();
      expect(sells(), 900, reason: "back on the catalog's");
    });

    test("a new line takes the site's price; a line already on a ticket keeps what it froze", () async {
      final price = cloud.create("price", {"product": cloudRice, "price": "12.50", "discount": null, "inheritsDiscount": false});
      await cycle();

      final invoice = engine.pos.open(tax: 0, seller: owner, device: "d-counter", deviceCode: "A");
      engine.pos.line(invoice["id"] as String, {"productId": rice, "add": 1}, actor: owner, device: "d-counter");
      int frozen() => db().select("SELECT price FROM pos_lines WHERE invoice_id = ?", [invoice["id"]]).single["price"] as int;
      expect(frozen(), 1250);

      cloud.edit("price", price, fields: {"price": "20.00"});
      await cycle();
      expect(frozen(), 1250, reason: "POS-12");
      expect(sells(), 2000);
    });

    test("a price that isn't a decimal is refused, and nothing changes", () async {
      cloud.create("price", {"product": cloudRice, "price": "twelve", "discount": null, "inheritsDiscount": true});
      final report = await cycle();

      expect(report.rejected, 1);
      expect(sells(), 900);
    });
  });

  group("member", () {
    /// Someone invited and in, as the activation leaves them.
    String hire(String username, String email) => engine.store.write((_) {
      engine.employees.invite({"email": email, "username": username, "jobTitle": "Barista"}, actor: owner);
      final account = db().select("SELECT id FROM accounts WHERE email = ?", [email]).first["id"] as String;
      db().execute("UPDATE accounts SET status = 'active' WHERE id = ?", [account]);
      engine.employees.acceptInvitations(account);

      return account;
    });

    Map<String, Object?> document({List<String> keys = const [], List<String>? branches, Map<String, Object?> at = const {}}) => {
      "email": "grace@example.com",
      "access": true,
      "all": false,
      "sections": PermissionCatalog.fromKeys(keys),
      "template": null,
      "custom": true,
      "branches": branches,
      "at": at,
    };

    late String grace;
    late String cloudGrace;

    setUp(() async {
      grace = hire("grace", "grace@example.com");
      await enroll();
      await cycle();
      cloudGrace = cloud.cloudIdOf(device, "account", grace)!;
    });

    test("a person kept to other sites has no access here, and gets it back when this one is theirs", () async {
      cloud.edit("member", cloudGrace, fields: document(keys: ["pos", "pos.sell"], branches: ["c-elsewhere"]));
      await cycle();
      expect(Grants.hasAccess(db(), grace), isFalse);

      cloud.edit("member", cloudGrace, fields: {"branches": [cloud.site, "c-elsewhere"]});
      await cycle();
      expect(Grants.of(db(), grace).can("pos.sell"), isTrue);

      cloud.edit("member", cloudGrace, fields: {"branches": null});
      await cycle();
      expect(Grants.hasAccess(db(), grace), isTrue, reason: "null is every site");
    });

    test("a structure of their own here replaces the base; one for another site doesn't", () async {
      final cashier = {"sections": PermissionCatalog.fromKeys(["pos", "pos.sell"]), "template": {"scope": "global", "id": "seller"}, "custom": false};

      cloud.edit("member", cloudGrace, fields: document(keys: ["money", "money.charge"], at: {"c-elsewhere": cashier}));
      await cycle();
      expect(Grants.of(db(), grace).can("money.charge"), isTrue);
      expect(Grants.of(db(), grace).can("pos.sell"), isFalse);

      cloud.edit("member", cloudGrace, fields: {"at": {cloud.site: cashier}});
      await cycle();
      final grant = Grants.of(db(), grace);
      expect(grant.can("pos.sell"), isTrue);
      expect(grant.can("money.charge"), isFalse, reason: "the site's structure, not laid over the base");
      expect(Grants.read(db(), grace)!.template, (scope: "global", id: "seller"));
    });

    test("branches and at that aren't the contract's are refused", () async {
      cloud.edit("member", cloudGrace, fields: {...document(), "branches": "c-site"});
      cloud.edit("member", "c-other", fields: {...document(), "email": "x@example.com", "at": {"c-site": "manager"}});
      final report = await cycle();

      expect(report.rejected, 2);
    });
  });
}
