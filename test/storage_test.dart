import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lyra_node/lyra_node.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late NodePaths paths;

  setUp(() => paths = tempPaths(addTearDown));

  Uint8List key(int fill) => Uint8List.fromList(List.filled(32, fill));

  group('encrypted at rest', () {
    test('the file has no SQLite header and none of its text', () {
      final store = Store.open(paths.database, key(1));
      store.write((db) => db.execute("CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('Ada Lovelace salary')"));
      store.checkpoint();
      store.close();

      final bytes = File(paths.database).readAsBytesSync();

      expect(latin1.decode(bytes.sublist(0, 15)), isNot("SQLite format 3"));
      expect(latin1.decode(bytes), isNot(contains("Ada Lovelace")));
    });

    test('reopens with its key, and a wrong key is refused', () {
      Store.open(paths.database, key(1))
        ..write((db) => db.execute("CREATE TABLE t (v INTEGER); INSERT INTO t VALUES (42)"))
        ..close();

      final again = Store.open(paths.database, key(1));
      expect(again.db.select("SELECT v FROM t").first["v"], 42);
      again.close();

      expect(
        () => Store.open(paths.database, key(2)),
        throwsA(isA<StoreError>().having((e) => e.failure, "failure", StoreFailure.wrongKey)),
      );
    });

    test('a write that throws leaves nothing behind', () {
      final store = Store.open(paths.database, key(1));
      addTearDown(store.close);
      store.write((db) => db.execute("CREATE TABLE t (v INTEGER)"));

      expect(
        () => store.write((db) {
          db.execute("INSERT INTO t VALUES (1)");
          throw StateError("rule refused it");
        }),
        throwsStateError,
      );
      expect(store.db.select("SELECT count(*) AS n FROM t").first["n"], 0);
    });
  });

  group('key loss', () {
    test('without the vault and the recovery key the data is unreadable; with the key it is back', () async {
      final vault = MemoryVault();
      final master = await setUpMaster(paths, vault);

      // The OS vault is gone (new OS user, reinstalled OS, stolen disk).
      await vault.delete(KeyringStore.kekName(master.instanceId));

      await expectLater(Engine.open(paths: paths, vault: vault), throwsA(isA<KeyringError>()));
      for (final guess in [key(0), key(255)]) {
        expect(() => Store.open(paths.database, guess), throwsA(isA<StoreError>()));
      }

      await Engine.recover(paths: paths, vault: vault, key: master.recovery, params: fastParams);
      final engine = await Engine.open(paths: paths, vault: vault, hasher: fastHasher);
      addTearDown(engine.close);

      expect(engine.accounts.isEmpty, isFalse);
      expect(engine.audit.list().map((e) => e.kind), contains(AuditKinds.keyringRecovered));
    });
  });

  group('migrations', () {
    const one = Migration(1, "one", "CREATE TABLE a (v INTEGER); INSERT INTO a VALUES (1);");
    const two = Migration(2, "two", "ALTER TABLE a ADD COLUMN w INTEGER NOT NULL DEFAULT 2;");
    const broken = Migration(3, "broken", "CREATE TABLE b (v INTEGER); INSERT INTO nowhere VALUES (1);");

    test('a new database gets every step, with no backup', () {
      final store = Store.open(paths.database, key(1));
      addTearDown(store.close);

      expect(migrate(store, backups: paths.backups, steps: const [one, two]), [1, 2]);
      expect(store.version, 2);
      expect(Directory(paths.backups).existsSync(), isFalse);
      expect(migrate(store, backups: paths.backups, steps: const [one, two]), isEmpty);
    });

    test('an existing database is copied first, and the copy is the old version, still encrypted', () {
      final store = Store.open(paths.database, key(1));
      migrate(store, backups: paths.backups, steps: const [one]);

      expect(migrate(store, backups: paths.backups, steps: const [one, two]), [2]);
      store.close();

      final copies = Directory(paths.backups).listSync().whereType<File>().toList();
      expect(copies, hasLength(1));
      expect(p.basename(copies.single.path), startsWith("pre-migration-1-"));

      final copy = Store.open(copies.single.path, key(1));
      expect(copy.version, 1);
      expect(copy.db.select("SELECT v FROM a").first["v"], 1);
      copy.close();
      expect(() => Store.open(copies.single.path, key(2)), throwsA(isA<StoreError>()));
    });

    test('a failing step rolls back to the last one that finished', () {
      final store = Store.open(paths.database, key(1));
      addTearDown(store.close);

      expect(() => migrate(store, backups: paths.backups, steps: const [one, two, broken]), throwsA(anything));
      expect(store.version, 2);
      expect(store.db.select("SELECT name FROM sqlite_master WHERE name = 'b'"), isEmpty);
    });

    test('a database from a newer engine is refused', () {
      final store = Store.open(paths.database, key(1));
      addTearDown(store.close);
      migrate(store, backups: paths.backups, steps: const [one, two]);

      expect(
        () => migrate(store, backups: paths.backups, steps: const [one]),
        throwsA(isA<DatabaseTooNew>().having((e) => e.found, "found", 2)),
      );
    });

    test('the released migrations apply to a new database', () {
      final store = Store.open(paths.database, key(1));
      addTearDown(store.close);

      migrate(store, backups: paths.backups);

      expect(store.version, migrations.last.version);
      final versions = [for (final m in migrations) m.version];
      expect(versions, [for (var i = 1; i <= versions.length; i++) i], reason: "numbered 1, 2, 3… with no gaps");
    });
  });
}
