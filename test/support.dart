import 'dart:io';

import 'package:lyra_node/lyra_node.dart';

/// Argon2id cheap enough for tests. Production uses [Argon2Params.standard].
const fastParams = Argon2Params(memory: 1024, iterations: 1, parallelism: 1);

const fastHasher = PasswordHasher(params: fastParams);

const owner = OwnerDraft(
  username: "Ada.Owner",
  password: "correct horse battery",
  firstName: "Ada",
  lastName: "Lovelace",
);

/// A fresh data folder, removed after the test.
NodePaths tempPaths(void Function(void Function()) addTearDown) {
  final folder = Directory.systemTemp.createTempSync("lyra_node_test_");
  addTearDown(() {
    try {
      folder.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold the WAL for a moment after close; the OS cleans temp later.
    }
  });

  return NodePaths(folder.path);
}

Future<({String instanceId, RecoveryKey recovery})> setUpMaster(
  NodePaths paths,
  KeyVault vault, {
  String? passphrase,
  DateTime Function()? now,
}) => Engine.setup(
  paths: paths,
  vault: vault,
  owner: owner,
  passphrase: passphrase,
  params: fastParams,
  hasher: fastHasher,
  now: now,
);
