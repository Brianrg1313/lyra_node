/// Money as the README writes it: integers in minor units, percents as decimal strings, rounded
/// half away from zero **once per line** and never on a sum.
///
/// Every product is done in integers ([BigInt]), so no binary fraction ever touches an amount.
abstract final class Money {
  static final _decimal = RegExp(r"^(\d{1,15})(?:\.(\d{1,8}))?$");
  static final _percent = RegExp(r"^(\d{1,3})(?:\.(\d{1,4}))?$");

  /// A stored decimal (`"22.50"`, a `PRICE` cell) in minor units of a currency with [decimals],
  /// or null when [value] isn't one.
  static int? minor(Object? value, int decimals) {
    final match = value is String ? _decimal.firstMatch(value.trim()) : null;
    if (match == null) return null;

    final fraction = match[2] ?? "";
    final scale = BigInt.from(10).pow(fraction.length);
    final units = BigInt.parse(match[1]! + fraction) * BigInt.from(10).pow(decimals);

    return _round(units, scale).toInt();
  }

  /// A sent price (a typed-in charge, POS-14) in minor units: an integer ≥ 0, or null.
  static int? sent(Object? value) => value is int && value >= 0 && value < 1000000000000000 ? value : null;

  /// A percent (`16`, `"7.5"`, `7.5`) as its canonical text (`"16"`, `"7.5"`), or null when it
  /// isn't a number from 0 to 100 with at most 4 decimals.
  static String? percent(Object? value) {
    final text = switch (value) {
      final int number => "$number",
      final double number when number.isFinite => number.toStringAsFixed(4),
      final String text => text.trim(),
      _ => null,
    };
    final match = text == null ? null : _percent.firstMatch(text);
    if (match == null) return null;

    final fraction = (match[2] ?? "").replaceFirst(RegExp(r"0+$"), "");
    final whole = int.parse(match[1]!);
    if (whole > 100 || whole == 100 && fraction.isNotEmpty) return null;

    return fraction.isEmpty ? "$whole" : "$whole.$fraction";
  }

  /// [amount] × [rate] / 100, rounded once (POS-20's tax of a line).
  static int percentOf(int amount, String rate) {
    final (numerator, scale) = _parts(rate);

    return _round(BigInt.from(amount) * numerator, scale * BigInt.from(100)).toInt();
  }

  /// [list] with [discount] percent off, rounded once (POS-7).
  static int discounted(int list, String discount) {
    final (numerator, scale) = _parts(discount);
    final hundred = scale * BigInt.from(100);

    return _round(BigInt.from(list) * (hundred - numerator), hundred).toInt();
  }

  /// A canonical percent as `numerator / scale` (`"7.5"` → 75 / 10).
  static (BigInt, BigInt) _parts(String percent) {
    final dot = percent.indexOf(".");
    final decimals = dot == -1 ? 0 : percent.length - dot - 1;

    return (BigInt.parse(percent.replaceFirst(".", "")), BigInt.from(10).pow(decimals));
  }

  /// [numerator] / [denominator], half away from zero (both ≥ 0 here; a sign is kept anyway).
  static BigInt _round(BigInt numerator, BigInt denominator) {
    final negative = numerator.isNegative != denominator.isNegative && numerator != BigInt.zero;
    final quotient = (numerator.abs() * BigInt.two + denominator.abs()) ~/ (denominator.abs() * BigInt.two);

    return negative ? -quotient : quotient;
  }
}
