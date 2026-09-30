import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../crypto/envelope.dart';
import '../failure.dart';
import '../identity/permissions.dart';
import '../ids.dart';
import '../storage/store.dart';

/// What an upload is for, and how big it may be (`protocol-v1.md` §6).
enum FilePurpose {
  logo(5 << 20, _images),
  productImage(10 << 20, _images),
  import(20 << 20, {"text/csv", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}),
  picture(5 << 20, _images);

  const FilePurpose(this.maxBytes, this.types);

  final int maxBytes;
  final Set<String> types;

  /// The `X-Lyra-Purpose` header value.
  String get header => switch (this) {
    productImage => "product_image",
    _ => name,
  };

  static FilePurpose? byHeader(String? value) {
    for (final purpose in values) {
      if (purpose.header == value) return purpose;
    }

    return null;
  }
}

const _images = {"image/png", "image/jpeg", "image/webp", "image/gif"};

/// A stored upload.
final class StoredFile {
  const StoredFile({required this.id, required this.contentType, required this.bytes});

  final String id;
  final String contentType;
  final Uint8List bytes;
}

/// Uploaded files (`protocol-v1.md` §6): each one sealed on disk (AES-256-GCM under a key the
/// keyring derives for files, the file id as context), its row in `files`.
///
/// A file nothing references within [orphanAge] is deleted ([sweep]). Until a domain op
/// references one (phase 4: logos, product images), only its uploader may read it back.
final class FileStore {
  FileStore(this._store, this._folder, this._key, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const orphanAge = Duration(hours: 1);

  final Store _store;
  final String _folder;
  final Uint8List _key;
  final DateTime Function() _now;

  /// Stores [bytes] after checking their real type ([sniff]) against [purpose]. Answers the id.
  Future<String> put(FilePurpose purpose, Uint8List bytes, {required String owner}) async {
    if (bytes.isEmpty || bytes.length > purpose.maxBytes) {
      throw EngineFailure("invalid_file", {"maxBytes": purpose.maxBytes});
    }

    final type = sniff(bytes);
    if (type == null || !purpose.types.contains(type)) throw const EngineFailure("invalid_file");

    final id = newId();
    final sealed = await Envelope.seal(_key, bytes, context: "lyra/file/$id");
    final file = File(p.join(_folder, id));

    Directory(_folder).createSync(recursive: true);
    file.writeAsBytesSync(sealed, flush: true);

    try {
      _store.write((db) => db.execute(
        "INSERT INTO files (id, purpose, content_type, size, owner, created) VALUES (?, ?, ?, ?, ?, ?)",
        [id, purpose.header, type, bytes.length, owner, _now().toUtc().toIso8601String()],
      ));
    } catch (_) {
      file.deleteSync();
      rethrow;
    }

    return id;
  }

  /// Reads [id] for [account] holding [grants]: the file's permission once a record references
  /// it, its uploader until then. Anything else is `not_found`, so ids can't be probed.
  Future<StoredFile> get(String id, {required String account, required Set<String> grants}) async {
    final rows = _store.db.select("SELECT * FROM files WHERE id = ?", [id]);
    if (rows.isEmpty) throw const EngineFailure("not_found");

    final row = rows.first;
    final permission = row["permission"] as String?;
    final allowed = permission == null ? row["owner"] == account : Permissions.allows(grants, permission);
    final file = File(p.join(_folder, id));

    if (!allowed || !file.existsSync()) throw const EngineFailure("not_found");

    return StoredFile(
      id: id,
      contentType: row["content_type"] as String,
      bytes: await Envelope.open(_key, file.readAsBytesSync(), context: "lyra/file/$id"),
    );
  }

  /// Deletes uploads nobody referenced within [orphanAge]. Answers how many.
  int sweep() {
    final cutoff = _now().toUtc().subtract(orphanAge).toIso8601String();
    final ids = [
      for (final row in _store.db.select("SELECT id FROM files WHERE referenced = 0 AND created < ?", [cutoff]))
        row["id"] as String,
    ];

    for (final id in ids) {
      _store.write((db) => db.execute("DELETE FROM files WHERE id = ?", [id]));

      final file = File(p.join(_folder, id));
      if (file.existsSync()) file.deleteSync();
    }

    return ids.length;
  }

  /// The type the bytes really are, from their first bytes, or null when it's none this
  /// master accepts. The `Content-Type` header is never trusted.
  static String? sniff(Uint8List bytes) {
    bool starts(List<int> magic, [int offset = 0]) {
      if (bytes.length < offset + magic.length) return false;
      for (var i = 0; i < magic.length; i++) {
        if (bytes[offset + i] != magic[i]) return false;
      }
      return true;
    }

    if (starts([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return "image/png";
    if (starts([0xff, 0xd8, 0xff])) return "image/jpeg";
    if (starts("GIF87a".codeUnits) || starts("GIF89a".codeUnits)) return "image/gif";
    if (starts("RIFF".codeUnits) && starts("WEBP".codeUnits, 8)) return "image/webp";
    // An .xlsx is a zip whose parts the import reads; anything else zipped fails there.
    if (starts([0x50, 0x4b, 0x03, 0x04])) return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    if (_isText(bytes)) return "text/csv";

    return null;
  }

  /// UTF-8 without NUL or other control bytes than tab and line breaks: what a CSV is.
  static bool _isText(Uint8List bytes) {
    for (final byte in bytes.take(64 * 1024)) {
      if (byte == 0 || (byte < 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d)) return false;
    }

    try {
      utf8.decode(bytes.sublist(0, bytes.length.clamp(0, 64 * 1024)));
    } on FormatException {
      // A cut in the middle of a character at the 64 KiB mark is fine.
      return bytes.length > 64 * 1024;
    }

    return true;
  }
}
