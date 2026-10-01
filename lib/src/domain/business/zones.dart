import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// The IANA zone database the engine carries (README, time: "today" is computed in the company's
/// zone, on the master's clock). Loaded on first use, from the copy compiled into the executable,
/// so it never depends on what the OS has.
abstract final class Zones {
  static bool _loaded = false;

  static void _load() {
    if (_loaded) return;

    tzdata.initializeTimeZones();
    _loaded = true;
  }

  /// Whether [name] is a zone of the database (`America/Caracas`, `UTC`).
  static bool known(String name) {
    _load();

    return name == "UTC" || tz.timeZoneDatabase.locations.containsKey(name);
  }

  /// The day [instant] falls on in [zone], as the UTC instants it starts and ends at (end
  /// excluded). A day isn't always 24 hours: daylight saving time makes some 23 or 25.
  static (DateTime, DateTime) dayOf(String zone, DateTime instant) {
    _load();

    final location = zone == "UTC" ? tz.UTC : tz.getLocation(zone);
    final local = tz.TZDateTime.from(instant, location);
    final start = tz.TZDateTime(location, local.year, local.month, local.day);
    final end = tz.TZDateTime(location, local.year, local.month, local.day + 1);

    return (start.toUtc(), end.toUtc());
  }

  /// The UTC instant the calendar day [year]-[month]-[day] starts at in [zone].
  static DateTime startOf(String zone, int year, int month, int day) {
    _load();

    return tz.TZDateTime(_location(zone), year, month, day).toUtc();
  }

  /// [instant] as ISO 8601 in [zone]'s wall clock, to the second, with its offset
  /// (`2026-09-01T10:00:00-04:00`): what an accountant's software reads as the local time.
  static String local(String zone, DateTime instant) {
    _load();

    final at = tz.TZDateTime.from(instant, _location(zone));
    String two(int value) => value.toString().padLeft(2, "0");
    final offset = at.timeZoneOffset;
    final minutes = offset.inMinutes.abs();

    return "${at.year.toString().padLeft(4, "0")}-${two(at.month)}-${two(at.day)}"
      "T${two(at.hour)}:${two(at.minute)}:${two(at.second)}"
      "${offset.isNegative ? "-" : "+"}${two(minutes ~/ 60)}:${two(minutes % 60)}";
  }

  static tz.Location _location(String zone) => zone == "UTC" ? tz.UTC : tz.getLocation(zone);
}
