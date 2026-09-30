@TestOn("windows")
@Tags(["process"])
library;

import 'dart:convert';
import 'dart:io';

import 'package:lyra_node/lyra_node.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// The engine as the app runs it (plan §3, D4): the real executable, the real OS vault, and a
/// parent that exits right after starting it.
///
/// Windows only: there the vault is DPAPI blobs inside the test's own data folder. On macOS and
/// Linux the vault is the user's real Keychain or keyring, which a test must not fill.
void main() {
  late String exe;
  late String launcher;

  setUpAll(() async {
    final build = await Process.run(Platform.resolvedExecutable, ["build", "cli"]);
    expect(build.exitCode, 0, reason: "${build.stdout}\n${build.stderr}");

    exe = p.join("build", "cli", "windows_x64", "bundle", "bin", "lyra_node.exe");

    // Run from outside the package: `dart run` inside it would bundle the package's native
    // assets again, over the DLL a running engine holds open.
    final outside = Directory.systemTemp.createTempSync("lyra_launcher_");
    addTearDown(() => outside.deleteSync(recursive: true));
    launcher = p.join(outside.path, "launch_detached.dart");
    File(p.join("test", "support", "launch_detached.dart")).copySync(launcher);
  });

  late NodePaths paths;

  setUp(() => paths = tempPaths(addTearDown));

  Future<Map<String, Object?>> cli(List<String> args, {String? input}) async {
    final process = await Process.start(exe, [...args, "--data", paths.root]);
    if (input != null) process.stdin.write(input);
    await process.stdin.close();

    final out = await process.stdout.transform(utf8.decoder).join();
    await process.exitCode;

    return jsonDecode(out) as Map<String, Object?>;
  }

  Future<void> launch({String? passphrase}) async {
    final result = await Process.run(Platform.resolvedExecutable, [
      "run", launcher, p.absolute(exe), paths.root,
      ?passphrase,
    ]);
    expect(result.exitCode, 0, reason: "${result.stderr}");
  }

  Future<String> statusUntil(Set<String> wanted) async {
    for (var i = 0; i < 100; i++) {
      final status = (await cli(["status"]))["status"] as String;
      if (wanted.contains(status)) return status;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    return (await cli(["status"]))["status"] as String;
  }

  Future<void> setUpMasterCli({String? passphrase}) async {
    final answer = await cli(["setup"], input: jsonEncode({
      "owner": {"username": "owner", "password": "correct horse battery", "firstName": "Ada", "lastName": "L"},
      "passphrase": ?passphrase,
    }));

    expect(answer["recovery"], hasLength(24));
  }

  test('the engine outlives the process that started it, and stops when asked', () async {
    await setUpMasterCli();
    expect((await cli(["status"]))["status"], "stopped");

    await launch();

    // The launcher has exited by now: this is "the app was closed".
    expect(await statusUntil({"ready"}), "ready");
    final status = await cli(["status"]);
    expect(status["version"], engineVersion);

    // A second engine on the same data refuses to start.
    final second = await Process.run(exe, ["run", "--data", paths.root]);
    expect(second.exitCode, ExitCodes.alreadyRunning);

    expect((await cli(["stop"]))["stopped"], isTrue);
    expect((await cli(["status"]))["status"], "stopped");
    expect(File(paths.state).existsSync(), isFalse);

    final log = File(p.join(paths.logs, "engine.log")).readAsStringSync();
    expect(log, contains("engine ready"));
    expect(log, contains("engine stopped"));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('passphrase mode starts with the passphrase on stdin, and stays locked without it', () async {
    await setUpMasterCli(passphrase: "a long passphrase");

    await launch();
    expect(await statusUntil({"locked"}), "locked");
    expect((await cli(["stop"]))["stopped"], isTrue);

    await launch(passphrase: "a long passphrase");
    expect(await statusUntil({"ready"}), "ready");
    expect((await cli(["stop"]))["stopped"], isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a state file not signed by the engine is not trusted', () async {
    await setUpMasterCli();
    await launch();
    expect(await statusUntil({"ready"}), "ready");

    final forged = jsonDecode(File(paths.state).readAsStringSync()) as Map<String, Object?>;
    File(paths.state).writeAsStringSync(jsonEncode({...forged, "port": 9999}));

    expect((await cli(["status"]))["status"], "unverified");
    expect((await cli(["stop"]))["stopped"], isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('setup refuses a second master and prints the refusal as JSON', () async {
    await setUpMasterCli();

    final again = await cli(["setup"], input: jsonEncode({
      "owner": {"username": "owner", "password": "correct horse battery", "firstName": "A", "lastName": "L"},
    }));

    expect(again["error"], "already_set_up");
  });
}
