import 'dart:convert';
import 'dart:io';

import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_protocol/lyra_protocol.dart';

/// `lyra_node <command> [--data <folder>]`, the executable shipped next to the desktop app.
///
/// The app drives it with these commands (`LocalServerService`); every one but `run` prints
/// **one JSON line** on stdout and exits. Secrets (the owner's password, a passphrase, recovery
/// words) are only ever read from **stdin**, never from arguments, which other processes can
/// read from the process list.
///
/// | command | stdin | stdout |
/// |---|---|---|
/// | `setup` | `{owner: {username, password, firstName, lastName, email?}, passphrase?}` | `{instanceId, recovery: [24 words]}` |
/// | `run` | the passphrase, one line, with `--passphrase-stdin` | nothing; runs until stopped |
/// | `status` | — | `{status, pid?, version?, instanceId?, port?}` |
/// | `stop` | — | `{stopped: bool}` |
/// | `recover` | `{words, passphrase?}` | `{instanceId}` |
/// | `version` | — | `{engine, protocol, minApp}` |
///
/// A refusal prints `{error: <code>}` and exits with [ExitCodes.failed].
Future<void> main(List<String> arguments) async {
  final args = [...arguments];
  final command = args.isEmpty ? "" : args.removeAt(0);
  final data = _option(args, "--data");
  final paths = data == null ? NodePaths.platform() : NodePaths(data);
  final vault = KeyVault.platform(paths.root);

  try {
    switch (command) {
      case "setup":
        final input = await _readJson();
        final result = await Engine.setup(
          paths: paths,
          vault: vault,
          owner: OwnerDraft.fromJson((input["owner"] as Map?)?.cast<String, Object?>() ?? const {}),
          passphrase: input["passphrase"] as String?,
        );
        _answer({"instanceId": result.instanceId, "recovery": result.recovery.words});

      case "run":
        final fromStdin = args.contains("--passphrase-stdin");
        final runner = NodeRunner(
          paths,
          vault,
          passphrase: fromStdin ? () async => stdin.readLineSync(encoding: utf8) : null,
        );
        exitCode = await runner.run();

      case "status":
        final result = await readStatus(paths, vault);
        _answer({
          "status": result.status.name,
          if (result.state != null) ...{
            "pid": result.state!.pid,
            "version": result.state!.version,
            "instanceId": result.state!.instanceId,
            "port": result.state!.port,
          },
        });

      case "stop":
        _answer({"stopped": await stopEngine(paths, vault)});

      case "recover":
        final input = await _readJson();
        await Engine.recover(
          paths: paths,
          vault: vault,
          key: RecoveryKey.parse(input["words"] as String? ?? ""),
          passphrase: input["passphrase"] as String?,
        );
        _answer({"instanceId": KeyringStore(paths.keyring, vault).instanceId});

      case "version":
        _answer({"engine": engineVersion, "protocol": protocolVersion, "minApp": minAppVersion});

      default:
        stderr.writeln("usage: lyra_node setup|run|status|stop|recover|version [--data <folder>]");
        exitCode = ExitCodes.usage;
    }
  } on EngineFailure catch (failure) {
    _fail(failure.code, failure.data);
  } on KeyringError catch (error) {
    _fail(error.failure == KeyringFailure.missing ? "not_set_up" : "key_${error.failure.name}");
  } on StoreError catch (error) {
    _fail("store_${error.failure.name}");
  } on DatabaseTooNew {
    _fail("database_too_new");
  } on FormatException {
    _fail(ErrorCodes.badRequest);
  }
}

String? _option(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;

  return args[index + 1];
}

Future<Map<String, Object?>> _readJson() async {
  final text = await stdin.transform(utf8.decoder).join();
  final json = jsonDecode(text);
  if (json is! Map<String, Object?>) throw const FormatException("stdin must be one JSON object");

  return json;
}

void _answer(Map<String, Object?> json) => stdout.writeln(jsonEncode(json));

void _fail(String code, [Map<String, Object?> data = const {}]) {
  stdout.writeln(jsonEncode({"error": code, if (data.isNotEmpty) "data": data}));
  exitCode = ExitCodes.failed;
}
