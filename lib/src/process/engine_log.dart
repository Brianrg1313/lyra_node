import 'dart:io';

import 'package:path/path.dart' as p;

/// `logs/engine.log`: what the detached engine has to say, since it has no console. One line per
/// event, UTC time first. Rotated to `engine.1.log` past [maxBytes].
///
/// Never given a secret, a password or company data: support reads this file.
final class EngineLog {
  EngineLog(String folder) : _file = File(p.join(folder, "engine.log"));

  static const maxBytes = 5 * 1024 * 1024;

  final File _file;

  void info(String message) => _write("INFO", message);

  void error(String message) => _write("ERROR", message);

  void _write(String level, String message) {
    try {
      _file.parent.createSync(recursive: true);

      if (_file.existsSync() && _file.lengthSync() > maxBytes) {
        _file.renameSync(p.join(_file.parent.path, "engine.1.log"));
      }

      _file.writeAsStringSync(
        "${DateTime.now().toUtc().toIso8601String()} $level $message\n",
        mode: FileMode.append,
        flush: true,
      );
    } on FileSystemException {
      // A log that can't be written must never take the engine down with it.
    }
  }
}
