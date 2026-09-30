import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'secrets.dart';
import 'wordlist.dart';

/// The owner's last way back to the data: 256 random bits written as 24 words, shown once at
/// setup (plan §6.2). It wraps the DEK on its own, so losing the OS vault or the passphrase
/// isn't losing the company. Losing both is, by design.
///
/// Encoding is BIP-39's: the entropy plus an 8-bit checksum (the first byte of its SHA-256),
/// cut into 24 groups of 11 bits. The checksum catches a mistyped word before any key is tried.
final class RecoveryKey {
  RecoveryKey._(this.entropy);

  factory RecoveryKey.generate() => RecoveryKey._(randomBytes(32));

  /// Reads words typed by a person: any case and spacing, and each word may be cut to its first
  /// four letters (unique in the list). Throws [FormatException] on an unknown word, a count
  /// other than 24 or a failed checksum.
  factory RecoveryKey.parse(String text) {
    final typed = text.toLowerCase().split(RegExp(r"[\s,]+")).where((w) => w.isNotEmpty).toList();

    if (typed.length != 24) throw const FormatException("A recovery key has 24 words");

    var bits = BigInt.zero;
    for (final word in typed) {
      final index = _indexOf(word);
      if (index < 0) throw FormatException("Unknown word: $word");
      bits = (bits << 11) | BigInt.from(index);
    }

    final checksum = (bits & BigInt.from(0xff)).toInt();
    var entropyBits = bits >> 8;
    final entropy = Uint8List(32);
    for (var i = 31; i >= 0; i--) {
      entropy[i] = (entropyBits & BigInt.from(0xff)).toInt();
      entropyBits >>= 8;
    }

    if (sha256.convert(entropy).bytes.first != checksum) {
      throw const FormatException("The words don't form a recovery key");
    }

    return RecoveryKey._(entropy);
  }

  final Uint8List entropy;

  List<String> get words {
    var bits = BigInt.zero;
    for (final byte in entropy) {
      bits = (bits << 8) | BigInt.from(byte);
    }
    bits = (bits << 8) | BigInt.from(sha256.convert(entropy).bytes.first);

    return [
      for (var i = 23; i >= 0; i--)
        recoveryWords[((bits >> (i * 11)) & BigInt.from(0x7ff)).toInt()],
    ];
  }

  static int _indexOf(String word) {
    final exact = recoveryWords.indexOf(word);
    if (exact >= 0 || word.length != 4) return exact;

    return recoveryWords.indexWhere((candidate) => candidate.startsWith(word));
  }
}
