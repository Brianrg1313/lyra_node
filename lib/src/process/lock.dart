import 'dart:io';

/// The single-instance lock (plan §3): an exclusive OS lock on `engine.lock`, held for as long as
/// the engine runs. The OS drops it when the process dies, however it dies, so a crash never
/// leaves a stale lock behind.
///
/// Held per process: a second engine on the same folder fails to take it and exits before it
/// opens the database.
final class InstanceLock {
  InstanceLock._(this._file);

  final RandomAccessFile _file;

  /// Takes the lock, or answers null when another process holds it.
  static InstanceLock? tryAcquire(String path) {
    File(path).parent.createSync(recursive: true);
    final file = File(path).openSync(mode: FileMode.append);

    try {
      file.lockSync(FileLock.exclusive);
    } on FileSystemException {
      file.closeSync();
      return null;
    }

    return InstanceLock._(file);
  }

  /// Whether some other process holds the lock right now.
  ///
  /// Only meaningful from a process that doesn't hold it itself: POSIX locks belong to the
  /// process, so from inside the engine this would answer false.
  static bool isHeld(String path) {
    if (!File(path).existsSync()) return false;

    final lock = tryAcquire(path);
    if (lock == null) return true;

    lock.release();
    return false;
  }

  void release() {
    try {
      _file.unlockSync();
    } finally {
      _file.closeSync();
    }
  }
}
