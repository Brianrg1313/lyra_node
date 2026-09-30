import 'dart:async';
import 'dart:io';

import 'package:lyra_protocol/lyra_protocol.dart';

import '../crypto/keyring.dart';
import '../crypto/vault.dart';
import '../engine.dart';
import 'control.dart';
import 'engine_log.dart';
import 'lock.dart';
import 'paths.dart';

/// Exit codes of `lyra_node`, read by the app's `LocalServerService`.
abstract final class ExitCodes {
  static const ok = 0;
  static const failed = 1;
  static const usage = 2;
  static const alreadyRunning = 3;
  static const notSetUp = 4;
}

/// The engine as a long-running process (plan §3): takes the single-instance lock, says what it
/// is doing in `engine.state.json`, opens the [Engine], and keeps it open until a signed stop
/// request or a signal.
///
/// Nothing here restarts it or starts it at boot: the engine never starts without the app
/// (plan D4).
final class NodeRunner {
  NodeRunner(
    this.paths,
    this.vault, {
    this.passphrase,
    this.poll = const Duration(milliseconds: 300),
  }) : log = EngineLog(paths.logs);

  final NodePaths paths;
  final KeyVault vault;
  final EngineLog log;
  final Duration poll;

  /// Passphrase mode: where the passphrase comes from when the process starts (the app writes
  /// it to stdin). Null, or null answered, leaves the engine `locked` until it's stopped; the
  /// `engine.unlock` op (phase 3) is the other way in.
  final Future<String?> Function()? passphrase;

  Future<int> run() async {
    final lock = InstanceLock.tryAcquire(paths.lock);
    if (lock == null) return ExitCodes.alreadyRunning;

    final keyrings = KeyringStore(paths.keyring, vault);
    StreamSubscription<ProcessSignal>? interrupt;
    StreamSubscription<ProcessSignal>? terminate;

    try {
      if (!keyrings.exists) return ExitCodes.notSetUp;

      final controlKey = await Engine.controlKey(vault, keyrings.instanceId);
      final control = ControlChannel(paths, controlKey);
      final stop = Completer<void>();
      var status = EngineStatusFile(
        pid: pid,
        instanceId: keyrings.instanceId,
        version: engineVersion,
        protocol: protocolVersion,
        phase: EnginePhase.starting,
        startedAt: DateTime.now(),
      );

      void publish(EnginePhase phase) {
        status = status.copyWith(phase: phase);
        status.write(paths.state, controlKey);
      }

      void requestStop() {
        if (!stop.isCompleted) stop.complete();
      }

      // Requests left from before this start never stop it.
      control.takeStopRequest();
      publish(EnginePhase.starting);

      final poller = Timer.periodic(poll, (_) {
        if (control.takeStopRequest()) requestStop();
      });
      interrupt = ProcessSignal.sigint.watch().listen((_) => requestStop());
      if (!Platform.isWindows) terminate = ProcessSignal.sigterm.watch().listen((_) => requestStop());

      log.info("engine $engineVersion starting, pid $pid");

      Engine? engine;
      String? secret;

      if (keyrings.mode == UnlockMode.passphrase) {
        publish(EnginePhase.locked);
        secret = await passphrase?.call();
      }

      if (keyrings.mode == UnlockMode.unattended || secret != null) {
        try {
          engine = await Engine.open(paths: paths, vault: vault, passphrase: secret);
        } on KeyringError catch (error) {
          // A wrong passphrase leaves it locked, as if none had come; anything else is logged
          // and the engine waits for a stop, so the app can read why.
          log.error("unlock failed: ${error.failure.name}");
        }
      }

      if (engine != null) {
        publish(EnginePhase.ready);
        log.info("engine ready");
      }

      await stop.future;
      poller.cancel();

      publish(EnginePhase.stopping);
      engine?.close();
      log.info("engine stopped");

      return ExitCodes.ok;
    } catch (error, stack) {
      log.error("engine failed: $error\n$stack");

      return ExitCodes.failed;
    } finally {
      await interrupt?.cancel();
      await terminate?.cancel();

      final state = File(paths.state);
      if (state.existsSync()) state.deleteSync();

      lock.release();
    }
  }
}
