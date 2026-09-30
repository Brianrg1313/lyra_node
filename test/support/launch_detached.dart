import 'dart:io';

/// Plays the app in `process_test.dart`: starts the engine detached, the way
/// `LocalServerService` does, and exits at once. Whatever happens to the engine afterwards
/// happens with its parent gone.
///
/// `dart run test/support/launch_detached.dart <exe> <data folder> [passphrase]`
Future<void> main(List<String> args) async {
  final passphrase = args.length > 2 ? args[2] : null;
  final process = await Process.start(
    args[0],
    // A free port: several tests (and a real master) may run at once.
    ["run", "--data", args[1], "--port", "0", if (passphrase != null) "--passphrase-stdin"],
    mode: passphrase == null ? ProcessStartMode.detached : ProcessStartMode.detachedWithStdio,
  );

  if (passphrase != null) {
    process.stdin.writeln(passphrase);
    await process.stdin.flush();
    await process.stdin.close();
  }

  stdout.writeln(process.pid);
  exit(0);
}
