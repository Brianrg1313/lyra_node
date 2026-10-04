import 'dart:async';
import 'dart:io';

import 'package:lyra_protocol/lyra_protocol.dart';

import '../crypto/keyring.dart';
import '../crypto/vault.dart';
import '../engine.dart';
import '../failure.dart';
import '../net/discovery.dart';
import '../net/server.dart';
import '../net/tls.dart';
import '../sync/edge.dart';
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
/// is doing in `engine.state.json`, opens the [Engine], serves the LAN ([LanServer], announced
/// with mDNS), and keeps it all open until a signed stop request or a signal.
///
/// In passphrase mode the server starts locked (it can: the transport file opens with the
/// control key) and the engine opens when the passphrase comes, from stdin or `engine.unlock`.
///
/// Nothing here restarts it or starts it at boot: the engine never starts without the app
/// (plan D4).
final class NodeRunner {
  NodeRunner(
    this.paths,
    this.vault, {
    this.passphrase,
    this.poll = const Duration(milliseconds: 300),
    this.port = defaultPort,
    this.webRoot,
    this.discoverable = true,
    this.syncEvery = const Duration(minutes: 1),
  }) : log = EngineLog(paths.logs);

  /// How often a linked master syncs with the cloud (plan §9.1).
  final Duration syncEvery;

  /// The LAN port; 0 picks a free one (tests).
  final int port;

  /// The web build to serve (plan §3), when this install ships one.
  final String? webRoot;

  /// Whether to answer mDNS (tests turn it off).
  final bool discoverable;

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
      LanServer? server;
      MdnsResponder? mdns;

      /// The master's `.local` name for browsers, claimed on the LAN (`LanName`): the one its
      /// certificate carries. None before the company exists.
      Future<String?> claimHost(Engine opened) async {
        final label = opened.lanName;
        if (label == null) return null;

        final previous = (await Transport.read(paths.transport, controlKey))?.host;
        final claimed = await LanName.claim(
          label,
          previous: previous?.replaceAll(RegExp(r"\.local$"), ""),
          own: await LocalAddresses.current(),
        );

        return "$claimed.local";
      }

      /// A new address, an old certificate or a new name: issued again now that the CA is
      /// readable, and served from the next handshake on.
      Future<Transport> renew(Engine opened) async {
        final transport = await opened.prepareTransport(controlKey, host: await claimHost(opened));
        server?.transport = transport;
        mdns?.alias = transport.host;

        return transport;
      }

      Future<Engine> open(String? secret) async {
        final opened = await Engine.open(paths: paths, vault: vault, passphrase: secret);
        if (server != null) await renew(opened);

        return opened;
      }

      Future<Engine> unlock(String secret) async {
        try {
          engine = await open(secret);
          publish(EnginePhase.ready);
          log.info("engine ready");

          return engine!;
        } on KeyringError catch (error) {
          log.error("unlock failed: ${error.failure.name}");
          throw EngineFailure(error.failure == KeyringFailure.wrongPassphrase ? "wrong_passphrase" : "locked");
        }
      }

      if (keyrings.mode == UnlockMode.unattended) {
        engine = await open(null);
      } else {
        publish(EnginePhase.locked);
      }

      final opened = engine;
      final transport = opened != null
        ? await renew(opened)
        : await Transport.read(paths.transport, controlKey);

      if (transport != null) {
        server = LanServer(
          instanceId: keyrings.instanceId,
          transport: transport,
          requestedPort: port,
          webRoot: webRoot,
          log: log,
          unlock: unlock,
          engine: engine,
        );
        server.onCompanyCreated = () {
          final opened = server?.engine;
          if (opened == null) return;

          unawaited(renew(opened).then((transport) => log.info("browsers open https://${transport.host}:${server?.port}"),
            onError: (Object error) => log.error("no name for browsers: $error")));
        };

        try {
          await server.start();
          status = status.copyWith(port: server.port);
          publish(status.phase);
          log.info("listening on ${server.port}");

          if (discoverable) {
            mdns = MdnsResponder(
              instanceId: keyrings.instanceId,
              port: server.port,
              addresses: await LocalAddresses.current(),
              alias: server.transport.host,
            );
            if (!await mdns.start()) log.info("mDNS unavailable: clients use the QR or a typed address");
          }
        } on SocketException catch (error) {
          // The engine still serves the app's own status; the admin screen shows why no device
          // can connect.
          log.error("can't listen on $port: ${error.message}");
          server = null;
        }
      } else {
        log.error("no transport file: the LAN starts after the first unlocked start");
      }

      // `ready` only once the port is known: the app reads both from one state file.
      if (engine != null) {
        publish(EnginePhase.ready);
        log.info("engine ready");
      }

      // The edge sync (plan §9.1): the engine dials out while it is enrolled, app open or not.
      HttpEdgeTransport? edgeTransport;
      Future<void>? syncing;

      Future<void> sync() async {
        final current = server?.engine ?? engine;
        final endpoint = current?.edge.endpoint;
        if (current == null || endpoint == null) return;

        if (edgeTransport?.endpoint != endpoint) {
          edgeTransport?.close();
          edgeTransport = HttpEdgeTransport(endpoint);
        }

        final report = await current.edge.cycle(edgeTransport!);
        if (report.error != null) log.error("sync: ${report.error}");
      }

      void tick() {
        if (syncing != null) return;
        syncing = sync().catchError((Object error) => log.error("sync failed: $error")).whenComplete(() => syncing = null);
      }

      final syncer = Timer.periodic(syncEvery, (_) => tick());
      tick();

      if (keyrings.mode == UnlockMode.passphrase && engine == null) {
        final secret = await passphrase?.call();

        if (secret != null && engine == null) {
          try {
            final opened = await unlock(secret);
            server?.ready(opened);
          } on EngineFailure {
            // Stays locked, as if no passphrase had come: `engine.unlock` is still a way in.
          }
        }
      }

      await stop.future;
      poller.cancel();
      syncer.cancel();
      // A cycle in flight finishes its write before the database closes.
      await syncing?.timeout(const Duration(seconds: 30), onTimeout: () {});
      edgeTransport?.close();

      publish(EnginePhase.stopping);
      await mdns?.stop();
      await server?.close();
      (server?.engine ?? engine)?.close();
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
