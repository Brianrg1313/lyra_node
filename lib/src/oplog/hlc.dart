/// A hybrid logical clock stamp: wall time in milliseconds, a counter for stamps within the same
/// millisecond (or while the wall clock is behind), and the node that made it.
///
/// [pack] is fixed width, so comparing packed strings is comparing stamps: that is how they're
/// stored and indexed. Plan §9.3 settles concurrent edits by it (last writer wins per field).
final class Hlc implements Comparable<Hlc> {
  const Hlc(this.millis, this.counter, this.node);

  static const int _maxCounter = 99999;

  /// Reads a [pack]ed stamp. Throws [FormatException] on anything else.
  factory Hlc.parse(String packed) {
    final match = RegExp(r"^(\d{15}):(\d{5}):(.+)$").firstMatch(packed);
    if (match == null) throw FormatException("Not an HLC stamp: $packed");

    return Hlc(int.parse(match.group(1)!), int.parse(match.group(2)!), match.group(3)!);
  }

  final int millis;
  final int counter;
  final String node;

  String pack() =>
    "${millis.toString().padLeft(15, "0")}:${counter.toString().padLeft(5, "0")}:$node";

  @override
  int compareTo(Hlc other) => millis != other.millis
    ? millis.compareTo(other.millis)
    : counter != other.counter
      ? counter.compareTo(other.counter)
      : node.compareTo(other.node);

  @override
  bool operator ==(Object other) => other is Hlc && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(millis, counter, node);

  @override
  String toString() => pack();
}

/// A stamp from elsewhere is further ahead of this clock than [HlcClock.maxDrift]. Sync stops
/// and warns instead of dragging every later stamp into the future (plan §9.3).
final class ClockDrift implements Exception {
  const ClockDrift(this.remote, this.local);

  final Hlc remote;
  final int local;

  @override
  String toString() => "ClockDrift: ${remote.pack()} is ahead of $local";
}

/// The master's clock (plan §9.3: clients take the master's time).
///
/// Never goes backwards: seeded with the last stamp written, it keeps counting from there even
/// when the OS clock was set back or the machine booted with a wrong time.
final class HlcClock {
  HlcClock(this.node, {Hlc? last, int Function()? now, this.maxDrift = const Duration(minutes: 1)})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
      _last = last ?? Hlc(0, 0, node);

  final String node;
  final Duration maxDrift;
  final int Function() _now;
  Hlc _last;

  Hlc get last => _last;

  /// A stamp for something that happens here, now.
  Hlc tick() => _last = _after(_last.millis, _last.counter);

  /// Takes in a stamp made elsewhere, so every later local stamp sorts after it.
  Hlc receive(Hlc remote) {
    final wall = _now();
    if (remote.millis - wall > maxDrift.inMilliseconds) throw ClockDrift(remote, wall);

    final newest = remote.compareTo(_last) > 0 ? remote : _last;

    return _last = _after(newest.millis, newest.counter);
  }

  Hlc _after(int millis, int counter) {
    final wall = _now();

    if (wall > millis) return Hlc(wall, 0, node);
    if (counter < Hlc._maxCounter) return Hlc(millis, counter + 1, node);

    // 100 000 stamps in one millisecond: borrow the next millisecond rather than overflow.
    return Hlc(millis + 1, 0, node);
  }
}
