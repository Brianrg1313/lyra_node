import 'dart:math';

final Random _random = Random.secure();
int _lastMs = 0;
int _sequence = 0;

/// A new record id: a UUIDv7 string (`docs/offline/README.md`, Identity). Time-ordered, so
/// fresh rows land at the end of an index, and never the backend's ids (plan principle 1).
///
/// **Monotonic** within this engine (RFC 9562 §6.2, method 1: `rand_a` is a counter): ids made in
/// the same millisecond still sort in the order they were made, which is what keeps an import's
/// rows in the file's order (lists sort by id). A clock that steps back keeps counting from the
/// last time used.
String newId() {
  var ms = DateTime.now().millisecondsSinceEpoch;

  if (ms <= _lastMs) {
    ms = _lastMs;
    if (++_sequence > 0xfff) {
      ms++;
      _sequence = 0;
    }
  } else {
    // Starting low leaves room to count in a busy millisecond.
    _sequence = _random.nextInt(0x400);
  }
  _lastMs = ms;

  final bytes = List<int>.filled(16, 0);
  for (var i = 0; i < 6; i++) {
    bytes[i] = (ms >> (8 * (5 - i))) & 0xff;
  }
  bytes[6] = 0x70 | (_sequence >> 8);
  bytes[7] = _sequence & 0xff;
  bytes[8] = 0x80 | _random.nextInt(0x40);
  for (var i = 9; i < 16; i++) {
    bytes[i] = _random.nextInt(0x100);
  }

  final hex = [for (final byte in bytes) byte.toRadixString(16).padLeft(2, "0")].join();

  return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}";
}
