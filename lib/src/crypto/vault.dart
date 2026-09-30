import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Thrown when the OS vault can't be reached (no Keychain session, no libsecret daemon, a
/// DPAPI failure). Not the same as a secret that isn't there, which reads as `null`.
final class VaultError implements Exception {
  const VaultError(this.message);

  final String message;

  @override
  String toString() => "VaultError: $message";
}

/// The signed-in OS user's secret store (plan §6.2): DPAPI on Windows, the Keychain on macOS,
/// libsecret on Linux. The engine runs as that user (plan §3), so the store is always there
/// while it runs, and a copied disk without the user's password can't open it.
abstract interface class KeyVault {
  Future<Uint8List?> read(String name);

  Future<void> write(String name, List<int> secret);

  Future<void> delete(String name);

  /// The vault of this OS. [root] is the engine's data folder (Windows keeps its DPAPI blobs
  /// there; the other two keep nothing on disk of their own).
  factory KeyVault.platform(String root) {
    if (Platform.isWindows) return WindowsVault(p.join(root, "vault"));
    if (Platform.isMacOS) return const MacVault();
    if (Platform.isLinux) return const LinuxVault();

    throw UnsupportedError("The engine runs on Windows, macOS and Linux only");
  }
}

/// A vault in memory, for tests and nothing else.
final class MemoryVault implements KeyVault {
  final Map<String, Uint8List> _secrets = {};

  /// A copy, as a real vault answers: the caller wipes what it reads.
  @override
  Future<Uint8List?> read(String name) async {
    final secret = _secrets[name];

    return secret == null ? null : Uint8List.fromList(secret);
  }

  @override
  Future<void> write(String name, List<int> secret) async =>
    _secrets[name] = Uint8List.fromList(secret);

  @override
  Future<void> delete(String name) async => _secrets.remove(name);
}

/// DPAPI, user scope: each secret is a file in [folder] that only this Windows user, on this
/// machine, can decrypt. [name] also goes in as the optional entropy, so one blob copied over
/// another's name doesn't open.
final class WindowsVault implements KeyVault {
  WindowsVault(this.folder);

  final String folder;

  File _file(String name) => File(p.join(folder, "$name.dpapi"));

  @override
  Future<Uint8List?> read(String name) async {
    final file = _file(name);
    if (!file.existsSync()) return null;

    return _Dpapi.unprotect(file.readAsBytesSync(), utf8.encode("lyra-node/$name"));
  }

  @override
  Future<void> write(String name, List<int> secret) async {
    final blob = _Dpapi.protect(secret, utf8.encode("lyra-node/$name"));
    final file = _file(name);
    final temporary = File("${file.path}.tmp");

    Directory(folder).createSync(recursive: true);
    temporary.writeAsBytesSync(blob, flush: true);
    temporary.renameSync(file.path);
  }

  @override
  Future<void> delete(String name) async {
    final file = _file(name);
    if (file.existsSync()) file.deleteSync();
  }
}

/// The login Keychain through the `security` tool. Secrets go in on its **stdin** (`-i`), never
/// on the command line, where any process could read them from the process list.
final class MacVault implements KeyVault {
  const MacVault();

  static const _service = "lyra-node";

  @override
  Future<Uint8List?> read(String name) async {
    final result = await Process.run(
      "security",
      ["find-generic-password", "-s", _service, "-a", name, "-w"],
    );

    // 44: the item isn't there.
    if (result.exitCode == 44) return null;
    if (result.exitCode != 0) throw VaultError("security: ${result.stderr}");

    return _fromHex((result.stdout as String).trim());
  }

  @override
  Future<void> write(String name, List<int> secret) async {
    final process = await Process.start("security", ["-i"]);
    process.stdin.writeln(
      "add-generic-password -U -s $_service -a $name -w ${_toHex(secret)}",
    );
    await process.stdin.close();

    if (await process.exitCode != 0) throw const VaultError("security refused the secret");
  }

  @override
  Future<void> delete(String name) async {
    await Process.run("security", ["delete-generic-password", "-s", _service, "-a", name]);
  }
}

/// libsecret through `secret-tool`, which reads the secret from stdin. Needs a Secret Service
/// (GNOME Keyring, KWallet); without one, setup offers passphrase mode instead.
final class LinuxVault implements KeyVault {
  const LinuxVault();

  List<String> _attributes(String name) => ["service", "lyra-node", "name", name];

  @override
  Future<Uint8List?> read(String name) async {
    final result = await Process.run("secret-tool", ["lookup", ..._attributes(name)]);
    final text = (result.stdout as String).trim();

    // secret-tool answers 1 and prints nothing when the item isn't there.
    if (result.exitCode != 0 || text.isEmpty) {
      if ((result.stderr as String).trim().isEmpty) return null;

      throw VaultError("secret-tool: ${result.stderr}");
    }

    return _fromHex(text);
  }

  @override
  Future<void> write(String name, List<int> secret) async {
    final process = await Process.start(
      "secret-tool",
      ["store", "--label=Lyra node", ..._attributes(name)],
    );
    process.stdin.write(_toHex(secret));
    await process.stdin.close();

    if (await process.exitCode != 0) throw const VaultError("secret-tool refused the secret");
  }

  @override
  Future<void> delete(String name) async {
    await Process.run("secret-tool", ["clear", ..._attributes(name)]);
  }
}

String _toHex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join();

Uint8List _fromHex(String hex) {
  if (hex.length.isOdd || !RegExp(r"^[0-9a-fA-F]*$").hasMatch(hex)) {
    throw const VaultError("The vault holds something that isn't ours");
  }

  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

// --- DPAPI (crypt32.dll) --------------------------------------------------------------------

final class _Blob extends Struct {
  @Uint32()
  external int size;

  external Pointer<Uint8> data;
}

typedef _CryptNative = Int32 Function(
  Pointer<_Blob> input,
  Pointer<Utf16> description,
  Pointer<_Blob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  Uint32 flags,
  Pointer<_Blob> output,
);
typedef _Crypt = int Function(
  Pointer<_Blob> input,
  Pointer<Utf16> description,
  Pointer<_Blob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  int flags,
  Pointer<_Blob> output,
);

typedef _UnprotectNative = Int32 Function(
  Pointer<_Blob> input,
  Pointer<Pointer<Utf16>> description,
  Pointer<_Blob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  Uint32 flags,
  Pointer<_Blob> output,
);
typedef _Unprotect = int Function(
  Pointer<_Blob> input,
  Pointer<Pointer<Utf16>> description,
  Pointer<_Blob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  int flags,
  Pointer<_Blob> output,
);

abstract final class _Dpapi {
  /// Never show a UI: the engine runs detached, and a prompt nobody sees would hang it.
  static const _uiForbidden = 0x1;

  static final _crypt32 = DynamicLibrary.open("crypt32.dll");
  static final _kernel32 = DynamicLibrary.open("kernel32.dll");

  static final _protect =
    _crypt32.lookupFunction<_CryptNative, _Crypt>("CryptProtectData");
  static final _unprotect =
    _crypt32.lookupFunction<_UnprotectNative, _Unprotect>("CryptUnprotectData");
  static final _localFree = _kernel32
    .lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>(
      "LocalFree",
    );

  static Uint8List protect(List<int> clear, List<int> entropy) => using((arena) {
    final input = _blob(arena, clear);
    final salt = _blob(arena, entropy);
    final output = arena<_Blob>();

    final ok = _protect(input, nullptr, salt, nullptr, nullptr, _uiForbidden, output);
    if (ok == 0) throw const VaultError("CryptProtectData failed");

    return _take(output);
  });

  static Uint8List? unprotect(List<int> sealed, List<int> entropy) => using((arena) {
    final input = _blob(arena, sealed);
    final salt = _blob(arena, entropy);
    final output = arena<_Blob>();

    final ok = _unprotect(input, nullptr, salt, nullptr, nullptr, _uiForbidden, output);

    // Another user's or another machine's blob, or a tampered one: to the engine, it simply
    // isn't there.
    if (ok == 0) return null;

    return _take(output);
  });

  static Pointer<_Blob> _blob(Arena arena, List<int> bytes) {
    final data = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);

    final blob = arena<_Blob>();
    blob.ref
      ..size = bytes.length
      ..data = data;

    return blob;
  }

  static Uint8List _take(Pointer<_Blob> output) {
    final bytes = Uint8List.fromList(output.ref.data.asTypedList(output.ref.size));

    // DPAPI allocates the output with LocalAlloc; clear it before handing it back.
    output.ref.data.asTypedList(output.ref.size).fillRange(0, output.ref.size, 0);
    _localFree(output.ref.data.cast());

    return bytes;
  }
}
