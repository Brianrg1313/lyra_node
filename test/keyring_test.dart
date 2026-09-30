import 'dart:convert';
import 'dart:io';

import 'package:lyra_node/lyra_node.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late NodePaths paths;
  late MemoryVault vault;
  late KeyringStore store;

  setUp(() {
    paths = tempPaths(addTearDown);
    vault = MemoryVault();
    store = KeyringStore(paths.keyring, vault);
  });

  Future<List<int>> dbKey(Keyring keyring) async => await keyring.databaseKey();

  test('unattended: the vault opens it again, and the file holds no key', () async {
    final created = await store.create(instanceId: "i1", params: fastParams);
    final key = await dbKey(created.keyring);

    expect(store.mode, UnlockMode.unattended);
    expect(await dbKey(await store.unlock()), key);
    expect(File(paths.keyring).readAsStringSync(), isNot(contains(base64.encode(key))));
  });

  test('passphrase: only the right passphrase opens it, and the vault keeps no KEK', () async {
    final created = await store.create(instanceId: "i1", passphrase: "long passphrase", params: fastParams);
    final key = await dbKey(created.keyring);

    expect(store.mode, UnlockMode.passphrase);
    expect(await vault.read(KeyringStore.kekName("i1")), isNull);
    expect(await dbKey(await store.unlock(passphrase: "long passphrase")), key);
    await expectLater(
      store.unlock(passphrase: "wrong"),
      throwsA(isA<KeyringError>().having((e) => e.failure, "failure", KeyringFailure.wrongPassphrase)),
    );
    await expectLater(
      store.unlock(),
      throwsA(isA<KeyringError>().having((e) => e.failure, "failure", KeyringFailure.passphraseRequired)),
    );
  });

  test('a lost vault is recovered with the 24 words, and only with them', () async {
    final created = await store.create(instanceId: "i1", params: fastParams);
    final key = await dbKey(created.keyring);

    await vault.delete(KeyringStore.kekName("i1"));

    await expectLater(
      store.unlock(),
      throwsA(isA<KeyringError>().having((e) => e.failure, "failure", KeyringFailure.vaultSecretMissing)),
    );
    await expectLater(
      store.recover(RecoveryKey.generate()),
      throwsA(isA<KeyringError>().having((e) => e.failure, "failure", KeyringFailure.wrongRecoveryKey)),
    );

    final recovered = await store.recover(RecoveryKey.parse(created.recovery.words.join(" ")));

    expect(await dbKey(recovered), key);
    expect(await dbKey(await store.unlock()), key, reason: "the vault holds a new KEK");
  });

  test('rewrap switches modes and keeps the same data key', () async {
    final created = await store.create(instanceId: "i1", params: fastParams);
    final key = await dbKey(created.keyring);

    await store.rewrap(created.keyring, passphrase: "now a passphrase", params: fastParams);

    expect(store.mode, UnlockMode.passphrase);
    expect(await dbKey(await store.unlock(passphrase: "now a passphrase")), key);
  });

  test('a keyring that was edited or is not one is corrupt', () async {
    await store.create(instanceId: "i1", params: fastParams);
    final json = jsonDecode(File(paths.keyring).readAsStringSync()) as Map<String, Object?>;
    final dek = base64.decode(json["dek"] as String)..[20] ^= 1;

    File(paths.keyring).writeAsStringSync(jsonEncode({...json, "dek": base64.encode(dek)}));
    await expectLater(
      store.unlock(),
      throwsA(isA<KeyringError>().having((e) => e.failure, "failure", KeyringFailure.corrupt)),
    );

    File(paths.keyring).writeAsStringSync("nope");
    await expectLater(store.unlock(), throwsA(isA<KeyringError>()));
  });
}
