import 'dart:io';

import 'package:lyra_node/lyra_node.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late NodePaths paths;
  late MemoryVault vault;
  var now = DateTime.utc(2026, 9, 30, 12);

  setUp(() {
    paths = tempPaths(addTearDown);
    vault = MemoryVault();
    now = DateTime.utc(2026, 9, 30, 12);
  });

  Future<Engine> open() async {
    final engine = await Engine.open(paths: paths, vault: vault, hasher: fastHasher, now: () => now);
    addTearDown(() {
      try {
        engine.close();
      } on Object {
        // Already closed by the test.
      }
    });

    return engine;
  }

  group('setup', () {
    test('makes the keys, the database and the owner, and audits it', () async {
      final master = await setUpMaster(paths, vault, now: () => now);
      final engine = await open();

      expect(engine.instanceId, master.instanceId);
      expect(master.recovery.words, hasLength(24));
      expect(await vault.read(Engine.controlKeyName(master.instanceId)), isNotNull);

      final owner = await engine.accounts.verifyPassword("ada.owner", "correct horse battery");
      expect(owner.isOwner, isTrue);
      expect(engine.audit.list().map((e) => e.kind), [
        AuditKinds.keyringCreated,
        for (final _ in migrations) AuditKinds.migrationApplied,
        AuditKinds.accountCreated,
        AuditKinds.engineStart,
      ]);
      expect(engine.audit.verify(), isNull);
      expect(engine.oplog.since(0).single.payload, isNot(contains("password")));
    });

    test('a refused owner leaves nothing behind, so a second try starts clean', () async {
      await expectLater(
        Engine.setup(
          paths: paths,
          vault: vault,
          owner: const OwnerDraft(username: "ada", password: "short", firstName: "Ada", lastName: "L"),
          params: fastParams,
          hasher: fastHasher,
        ),
        throwsA(isA<EngineFailure>().having((e) => e.code, "code", "weak_password")),
      );

      expect(File(paths.keyring).existsSync(), isFalse);
      expect(File(paths.database).existsSync(), isFalse);

      await setUpMaster(paths, vault);
    });

    test('is refused over an existing master or orphan data', () async {
      await setUpMaster(paths, vault);
      await expectLater(setUpMaster(paths, vault), throwsA(isA<EngineFailure>().having((e) => e.code, "code", "already_set_up")));

      File(paths.keyring).deleteSync();
      await expectLater(setUpMaster(paths, vault), throwsA(isA<EngineFailure>().having((e) => e.code, "code", "data_exists")));
    });
  });

  group('open', () {
    test('passphrase mode needs the passphrase', () async {
      await setUpMaster(paths, vault, passphrase: "a long passphrase");

      await expectLater(Engine.open(paths: paths, vault: vault), throwsA(isA<KeyringError>()));
      await Engine.open(paths: paths, vault: vault, passphrase: "a long passphrase").then((e) => e.close());
    });

    test('the clock continues after the last stamp written, even if the OS clock went back', () async {
      await setUpMaster(paths, vault, now: () => now);
      final first = await open();
      final last = first.clock.last;
      first.close();

      now = DateTime.utc(2020);
      final engine = await open();

      expect(engine.clock.tick().compareTo(last), greaterThan(0));
    });

    test('keys of one master never open the database of another', () async {
      await setUpMaster(paths, vault);
      final other = tempPaths(addTearDown);
      await setUpMaster(other, vault);

      File(other.keyring).copySync(paths.keyring);

      await expectLater(Engine.open(paths: paths, vault: vault), throwsA(isA<StoreError>()));
    });
  });

  group('accounts', () {
    test('five failures lock the account for 15 minutes, even to the right password', () async {
      await setUpMaster(paths, vault);
      final engine = await open();

      for (var i = 0; i < Accounts.maxFailures; i++) {
        await expectLater(
          engine.accounts.verifyPassword("ada.owner", "wrong password"),
          throwsA(isA<EngineFailure>().having((e) => e.code, "code", "invalid_credentials")),
        );
      }

      await expectLater(
        engine.accounts.verifyPassword("ada.owner", "correct horse battery"),
        throwsA(isA<EngineFailure>().having((e) => e.code, "code", "account_locked")),
      );

      now = now.add(Accounts.lockout);
      await engine.accounts.verifyPassword("ADA.OWNER", "correct horse battery");

      final kinds = engine.audit.list().map((e) => e.kind);
      expect(kinds.where((k) => k == AuditKinds.signInFailed), hasLength(Accounts.maxFailures));
      expect(kinds, contains(AuditKinds.accountLocked));
    });

    test('an unknown login is the same refusal as a wrong password', () async {
      await setUpMaster(paths, vault);
      final engine = await open();

      await expectLater(
        engine.accounts.verifyPassword("nobody", "whatever password"),
        throwsA(isA<EngineFailure>().having((e) => e.code, "code", "invalid_credentials")),
      );
    });

    test('a hash with weaker parameters is rewritten at the next sign in', () async {
      await setUpMaster(paths, vault);
      final before = await open();
      final hash = before.store.db.select("SELECT password FROM accounts").first["password"];
      before.close();

      const stronger = PasswordHasher(params: Argon2Params(memory: 2048, iterations: 1, parallelism: 1));
      final engine = await Engine.open(paths: paths, vault: vault, hasher: stronger);
      addTearDown(engine.close);
      await engine.accounts.verifyPassword("ada.owner", "correct horse battery");

      final after = engine.store.db.select("SELECT password FROM accounts").first["password"] as String;
      expect(after, isNot(hash));
      expect(after, contains("m=2048"));
    });

    test('usernames follow S-1 and there is only one first owner', () async {
      await setUpMaster(paths, vault);
      final engine = await open();

      await expectLater(
        engine.accounts.createOwner(username: "second", password: "correct horse battery", firstName: "B", lastName: "C"),
        throwsA(isA<EngineFailure>().having((e) => e.code, "code", "owner_exists")),
      );
      await expectLater(
        engine.accounts.createOwner(username: "1abc", password: "correct horse battery", firstName: "B", lastName: "C"),
        throwsA(isA<EngineFailure>().having((e) => e.data["field"], "field", "username")),
      );
    });
  });
}
