import 'package:lyra_node/lyra_node.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support.dart';
import 'support/edge_cloud.dart';

/// Jobs on a master that syncs (`employee`, contract §11): an invitation made here reaches the
/// person's cloud account, their answer there comes back, and the owner's job filed on both sides
/// before the link stays one.
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

  String invite(String email) => engine.store.write((_) =>
    engine.employees.invite({"email": email, "jobTitle": "Barista"}, actor: owner)["id"] as String);

  Row job(String id) => db().select("SELECT * FROM employments WHERE id = ?", [id]).first;

  Row account(String email) => db().select("SELECT * FROM accounts WHERE email = ?", [email]).first;

  test("an invitation made here reaches the cloud, with the e-mail the cloud finds the person by", () async {
    await enroll();
    await cycle();

    final id = invite("grace@example.com");
    expect((await cycle()).ok, isTrue);

    final record = cloud.record("employee", cloud.cloudIdOf(device, "employee", id)!)!;
    expect(record.fields["email"], "grace@example.com");
    expect(record.fields["jobTitle"], "Barista");
    expect(record.fields["state"], "invited");
    // Pay and the private person are sealed and never travel.
    expect(record.fields.keys, isNot(contains("salary")));
  });

  test("accepted in the cloud, the job starts here and the pending account opens by the cloud's grant", () async {
    await enroll();
    await cycle();
    final id = invite("grace@example.com");
    await cycle();

    cloud.edit("employee", cloud.cloudIdOf(device, "employee", id)!,
      fields: {"state": "active", "responded": "2026-10-06T20:00:00.000Z"});
    await cycle();

    expect(job(id)["state"], "active");
    expect(job(id)["responded"], "2026-10-06T20:00:00.000Z");
    final grace = account("grace@example.com");
    expect(grace["status"], "active");
    expect(grace["password"], isNull);
    expect(db().select("SELECT 1 FROM activations WHERE account = ?", [grace["id"]]), isEmpty);
  });

  test("a job the cloud files for someone new here makes their account, pending and without a code", () async {
    await enroll();
    await cycle();

    final cloudId = cloud.create("employee", {
      "email": "Linus@Example.com", "firstName": "Linus", "lastName": "Torvalds", "jobTitle": "Cook", "state": "invited",
      "contract": "permanent", "startDate": "2026-10-07",
    });
    await cycle();

    final linus = account("linus@example.com");
    expect(linus["status"], "pending");
    expect(linus["first_name"], "Linus");
    expect(db().select("SELECT 1 FROM activations WHERE account = ?", [linus["id"]]), isEmpty);

    final rows = db().select("SELECT * FROM employments WHERE account = ?", [linus["id"]]);
    expect(rows, hasLength(1));
    expect(rows.first["job_title"], "Cook");
    expect(rows.first["start_date"], "2026-10-07");
    expect(cloud.cloudIdOf(device, "employee", rows.first["id"] as String), isNull, reason: "made from the cloud, not pushed back");
    expect(db().select("SELECT cloud_id FROM sync_ids WHERE entity = 'employee' AND local_id = ?", [rows.first["id"]]).first["cloud_id"],
      cloudId);
  });

  test("a state never moves back: an older answer arriving late is dropped", () async {
    await enroll();
    await cycle();
    final id = invite("grace@example.com");
    await cycle();
    final cloudId = cloud.cloudIdOf(device, "employee", id)!;

    cloud.edit("employee", cloudId, fields: {"state": "active"});
    await cycle();
    cloud.edit("employee", cloudId, fields: {"state": "invited", "department": "Kitchen"});
    await cycle();

    expect(job(id)["state"], "active");
    expect(job(id)["department"], "Kitchen");
  });

  test("the owner's job, filed on both sides before the link, stays one", () async {
    db().execute("UPDATE accounts SET email = 'ada@example.com' WHERE id = ?", [owner]);
    final local = db().select("SELECT id FROM employments WHERE account = ?", [owner]).first["id"] as String;
    final cloudId = cloud.create("employee", {"email": "ada@example.com", "jobTitle": "Owner", "state": "active"});

    await enroll();
    await cycle();

    final rows = db().select("SELECT id, job_title FROM employments WHERE account = ?", [owner]);
    expect(rows, hasLength(1));
    expect(rows.first["id"], local);
    expect(rows.first["job_title"], "Owner");
    expect(db().select("SELECT cloud_id FROM sync_ids WHERE entity = 'employee' AND local_id = ?", [local]).first["cloud_id"],
      cloudId);
    expect(cloud.ids("employee"), [cloudId], reason: "not uploaded as a second job");
  });

  test("a master linked before jobs synced uploads the ones it already had, once", () async {
    await enroll();
    await cycle();

    // What a version without `employee` left: the invitation in the oplog already pushed past, and
    // the link uploaded with the entities it had.
    final id = invite("grace@example.com");
    db().execute("UPDATE sync_link SET pushed_seq = ?, indexed_seq = ?, uploaded = ?",
      [Oplog(db()).lastSeq, Oplog(db()).lastSeq,
        '["company","site","product_table","product_field","product","currency","stock_movement","payment",'
        '"delivery_option","delivery_area","account","member"]']);
    expect(cloud.cloudIdOf(device, "employee", id), isNull);

    expect((await cycle()).ok, isTrue);
    expect(cloud.record("employee", cloud.cloudIdOf(device, "employee", id)!)!.fields["state"], "invited");

    final applied = cloud.applied;
    await cycle();
    expect(cloud.applied, applied, reason: "uploaded once");
  });
}
