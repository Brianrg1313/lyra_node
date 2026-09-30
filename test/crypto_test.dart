import 'dart:convert';

import 'package:lyra_node/lyra_node.dart';
import 'package:lyra_node/src/crypto/secrets.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('envelope', () {
    final key = List.filled(32, 7);

    test('opens what it sealed, with the same key and context', () async {
      final sealed = await Envelope.seal(key, utf8.encode("salary 1200"), context: "test");

      expect(utf8.decode(await Envelope.open(key, sealed, context: "test")), "salary 1200");
      expect(utf8.decode(sealed, allowMalformed: true), isNot(contains("salary")));
    });

    test('a wrong key, a wrong context or one flipped bit is refused', () async {
      final sealed = await Envelope.seal(key, [1, 2, 3], context: "a");
      final tampered = [...sealed]..[20] ^= 1;

      await expectLater(Envelope.open(List.filled(32, 8), sealed, context: "a"), throwsA(isA<EnvelopeError>()));
      await expectLater(Envelope.open(key, sealed, context: "b"), throwsA(isA<EnvelopeError>()));
      await expectLater(Envelope.open(key, tampered, context: "a"), throwsA(isA<EnvelopeError>()));
    });

    test('two seals of the same value differ (fresh nonce)', () async {
      final a = await Envelope.seal(key, [1], context: "x");
      final b = await Envelope.seal(key, [1], context: "x");

      expect(a, isNot(b));
    });
  });

  group('argon2id', () {
    // RFC 9106 / reference implementation test vector (test.c): "password", "somesalt",
    // t=2, m=64 MiB, p=1, 32 bytes, v=19.
    test('matches the reference implementation', () async {
      final hash = await argon2id(
        "password",
        utf8.encode("somesalt"),
        const Argon2Params(memory: 65536, iterations: 2, parallelism: 1),
      );

      expect(
        hash.map((b) => b.toRadixString(16).padLeft(2, "0")).join(),
        "09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7",
      );
    });
  });

  group('recovery key', () {
    test('24 words round-trip to the same key', () {
      final key = RecoveryKey.generate();
      final words = key.words;

      expect(words, hasLength(24));
      expect(RecoveryKey.parse(words.join(" ")).entropy, key.entropy);
    });

    test('reads any case and spacing, and four-letter prefixes', () {
      final key = RecoveryKey.generate();
      final typed = key.words.map((w) => w.length > 4 ? w.substring(0, 4).toUpperCase() : w).join("  ,\n");

      expect(RecoveryKey.parse(typed).entropy, key.entropy);
    });

    test('a mistyped word fails the checksum before any key is tried', () {
      final words = RecoveryKey.generate().words;
      final swapped = [words[1], words[0], ...words.skip(2)];

      if (swapped.join() != words.join()) {
        expect(() => RecoveryKey.parse(swapped.join(" ")), throwsFormatException);
      }
      expect(() => RecoveryKey.parse("abandon " * 23), throwsFormatException);
      expect(() => RecoveryKey.parse("${"abandon " * 23}notaword"), throwsFormatException);
    });
  });

  group('passwords', () {
    test('verify the right one only', () async {
      final hash = await fastHasher.hash("correct horse battery");

      expect(hash, startsWith(r"$argon2id$v=19$m=1024,t=1,p=1$"));
      expect(await fastHasher.verify("correct horse battery", hash), isTrue);
      expect(await fastHasher.verify("Correct horse battery", hash), isFalse);
      expect(await fastHasher.verify("x", "not a hash"), isFalse);
    });

    test('a hash with weaker parameters than today asks to be rewritten', () async {
      final hash = await fastHasher.hash("correct horse battery");

      expect(fastHasher.needsRehash(hash), isFalse);
      expect(const PasswordHasher().needsRehash(hash), isTrue);
    });
  });
}
