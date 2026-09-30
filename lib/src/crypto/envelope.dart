import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'secrets.dart';

/// Thrown when a sealed value can't be opened: wrong key, wrong context, or tampered bytes.
/// The three are indistinguishable on purpose.
final class EnvelopeError implements Exception {
  const EnvelopeError();

  @override
  String toString() => "EnvelopeError: the value can't be opened with this key";
}

/// AES-256-GCM with a fresh 96-bit nonce per seal.
///
/// Layout: `version (1) | nonce (12) | ciphertext | tag (16)`. The version byte lets a later
/// algorithm change coexist with values already written. [context] is authenticated but not
/// stored: a value sealed for one purpose (`"lyra/dek/kek"`) never opens as another.
abstract final class Envelope {
  static const int _version = 1;
  static final AesGcm _aes = AesGcm.with256bits();

  static Future<Uint8List> seal(List<int> key, List<int> clear, {required String context}) async {
    final box = await _aes.encrypt(
      clear,
      secretKey: SecretKey(key),
      nonce: randomBytes(12),
      aad: context.codeUnits,
    );

    return Uint8List.fromList([_version, ...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  static Future<Uint8List> open(List<int> key, List<int> sealed, {required String context}) async {
    if (sealed.length < 1 + 12 + 16 || sealed.first != _version) throw const EnvelopeError();

    final box = SecretBox(
      sealed.sublist(13, sealed.length - 16),
      nonce: sealed.sublist(1, 13),
      mac: Mac(sealed.sublist(sealed.length - 16)),
    );

    try {
      return Uint8List.fromList(
        await _aes.decrypt(box, secretKey: SecretKey(key), aad: context.codeUnits),
      );
    } on SecretBoxAuthenticationError {
      throw const EnvelopeError();
    }
  }
}
