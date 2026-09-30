import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

final Random _random = Random.secure();

/// [length] bytes from the OS's secure generator.
Uint8List randomBytes(int length) =>
  Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

/// Overwrites [bytes] with zeros, so a key that is no longer needed doesn't linger in memory
/// longer than the garbage collector keeps it. Best effort: Dart may already hold copies.
void wipe(Uint8List bytes) => bytes.fillRange(0, bytes.length, 0);

/// Compares in time that doesn't depend on where the first difference is.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;

  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }

  return difference == 0;
}

/// The cost of an Argon2id derivation. Stored next to every hash and wrap it produced, so
/// raising the defaults never makes an old one unreadable (`session.md` S-3).
final class Argon2Params {
  const Argon2Params({required this.memory, required this.iterations, required this.parallelism});

  factory Argon2Params.fromJson(Map<String, Object?> json) => Argon2Params(
    memory: json["m"] as int,
    iterations: json["t"] as int,
    parallelism: json["p"] as int,
  );

  /// `session.md` S-3: 64 MiB, t=3, p=1.
  static const standard = Argon2Params(memory: 65536, iterations: 3, parallelism: 1);

  /// Memory in KiB.
  final int memory;
  final int iterations;
  final int parallelism;

  bool isWeakerThan(Argon2Params other) =>
    memory < other.memory || iterations < other.iterations || parallelism < other.parallelism;

  Map<String, Object?> toJson() => {"m": memory, "t": iterations, "p": parallelism};
}

/// Argon2id of [secret] with [salt] (16 random bytes per use).
Future<Uint8List> argon2id(
  String secret,
  List<int> salt,
  Argon2Params params, {
  int length = 32,
}) async {
  final algorithm = Argon2id(
    memory: params.memory,
    iterations: params.iterations,
    parallelism: params.parallelism,
    hashLength: length,
  );
  final key = await algorithm.deriveKeyFromPassword(password: secret, nonce: salt);

  return Uint8List.fromList(await key.extractBytes());
}

/// HKDF-SHA256 of [key] for one [purpose]. Every key the engine uses is a subkey of the DEK
/// with its own purpose, so one leaked subkey says nothing about the others (plan §6.2).
Future<Uint8List> subkey(List<int> key, String purpose, {int length = 32}) async {
  final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: length).deriveKey(
    secretKey: SecretKey(key),
    info: purpose.codeUnits,
  );

  return Uint8List.fromList(await derived.extractBytes());
}
