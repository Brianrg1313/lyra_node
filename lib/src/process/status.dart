import 'dart:async';
import 'dart:io';

import '../crypto/keyring.dart';
import '../crypto/vault.dart';
import '../engine.dart';
import 'control.dart';
import 'lock.dart';
import 'paths.dart';

/// What `lyra_node status` answers about a data folder.
enum NodeStatus {
  /// No keyring: this computer isn't a master yet.
  notSetUp,

  /// Set up, and no engine is running.
  stopped,

  starting,
  locked,
  ready,
  stopping,

  /// Something holds the lock but can't prove it's our engine (no valid signed state). The app
  /// must not talk to it.
  unverified,
}

/// Reads the status of the engine of [paths], from another process (the app runs `lyra_node
/// status`). A just-started engine has the lock before it has written its state, so a missing
/// state is waited for up to [settle] before it counts as [NodeStatus.unverified].
Future<({NodeStatus status, EngineStatusFile? state})> readStatus(
  NodePaths paths,
  KeyVault vault, {
  Duration settle = const Duration(seconds: 3),
}) async {
  final keyrings = KeyringStore(paths.keyring, vault);
  if (!keyrings.exists) return (status: NodeStatus.notSetUp, state: null);

  final deadline = DateTime.now().add(settle);
  final controlKey = await Engine.controlKey(vault, keyrings.instanceId);

  while (true) {
    if (!InstanceLock.isHeld(paths.lock)) {
      // Left by an engine that died without cleaning up.
      final stale = File(paths.state);
      if (stale.existsSync()) stale.deleteSync();

      return (status: NodeStatus.stopped, state: null);
    }

    final state = EngineStatusFile.read(paths.state, controlKey);

    if (state != null && state.instanceId == keyrings.instanceId) {
      return (status: NodeStatus.values.byName(state.phase.name), state: state);
    }

    if (DateTime.now().isAfter(deadline)) return (status: NodeStatus.unverified, state: null);

    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Asks the engine of [paths] to stop and waits until it lets go of the lock. Answers whether it
/// did within [timeout].
Future<bool> stopEngine(
  NodePaths paths,
  KeyVault vault, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final keyrings = KeyringStore(paths.keyring, vault);
  if (!keyrings.exists || !InstanceLock.isHeld(paths.lock)) return true;

  ControlChannel(paths, await Engine.controlKey(vault, keyrings.instanceId)).requestStop();

  final deadline = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!InstanceLock.isHeld(paths.lock)) return true;
  }

  return false;
}
