import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

/// Why a database file didn't open.
enum StoreFailure {
  /// The SQLite library has no SQLCipher. Refused before anything is written: a plain SQLite
  /// would store the company in the clear (plan principle 2).
  noCipher,

  /// The key doesn't open the file, or the file isn't a database.
  wrongKey,
}

final class StoreError implements Exception {
  const StoreError(this.failure);

  final StoreFailure failure;

  @override
  String toString() => "StoreError(${failure.name})";
}

/// The company's database: one SQLCipher file (plan §8.1).
///
/// **One writer.** Every write goes through [write], a synchronous `BEGIN IMMEDIATE`
/// transaction. The engine is one isolate and the body can't `await`, so writes are applied one
/// at a time, in the order they arrive (plan principle 4), with nothing in between.
final class Store {
  Store._(this.path, this._db);

  /// Opens (or creates) [path] with the 32-byte raw [key].
  static Store open(String path, Uint8List key) {
    if (key.length != 32) throw ArgumentError.value(key.length, "key", "must be 32 bytes");

    File(path).parent.createSync(recursive: true);
    final db = sqlite3.open(path);

    try {
      final cipher = db.select("PRAGMA cipher_version");
      if (cipher.isEmpty || (cipher.first.values.first as String? ?? "").isEmpty) {
        throw const StoreError(StoreFailure.noCipher);
      }

      // SQLCipher prints every failed page decryption to stderr; a wrong key is answered as a
      // StoreError, and the log would only repeat it where no one reads it.
      db.execute("PRAGMA cipher_log_level = NONE");

      // A raw key (`x'…'`) skips SQLCipher's own PBKDF2: it's already a random 256-bit key.
      final hex = key.map((b) => b.toRadixString(16).padLeft(2, "0")).join();
      db.execute("PRAGMA key = \"x'$hex'\"");

      try {
        db.select("SELECT count(*) FROM sqlite_master");
      } on SqliteException {
        throw const StoreError(StoreFailure.wrongKey);
      }

      db.execute("PRAGMA journal_mode = WAL");
      // A power cut must not lose a sale that was answered as saved (plan §8.4).
      db.execute("PRAGMA synchronous = FULL");
      db.execute("PRAGMA foreign_keys = ON");
      db.execute("PRAGMA busy_timeout = 5000");
    } catch (_) {
      db.close();
      rethrow;
    }

    return Store._(path, db);
  }

  final String path;
  final Database _db;
  bool _writing = false;

  /// Reads outside a transaction see the last committed state.
  Database get db => _db;

  /// The schema version (`PRAGMA user_version`), written by the migrations.
  int get version => _db.select("PRAGMA user_version").first.values.first as int;

  /// Runs [body] as one transaction. It commits if [body] returns and rolls back if it throws.
  ///
  /// A write called from inside another one **joins** it: one transaction, committed or rolled
  /// back as a whole. That is how an op's change and its `commandId` answer commit together
  /// (the RPC layer wraps the domain's own write). The body is synchronous, so nothing else can
  /// run in between.
  T write<T>(T Function(Database db) body) {
    if (_writing) return body(_db);

    _writing = true;
    _db.execute("BEGIN IMMEDIATE");

    try {
      final result = body(_db);
      _db.execute("COMMIT");

      return result;
    } catch (_) {
      _db.execute("ROLLBACK");
      rethrow;
    } finally {
      _writing = false;
    }
  }

  /// Folds the WAL into the main file, so the file alone is the whole database.
  void checkpoint() => _db.execute("PRAGMA wal_checkpoint(TRUNCATE)");

  void close() => _db.close();
}
