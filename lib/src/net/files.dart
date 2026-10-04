import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:lyra_protocol/lyra_protocol.dart' show FileSizes, Grant;
import 'package:path/path.dart' as p;

import '../crypto/envelope.dart';
import '../failure.dart';
import '../ids.dart';
import '../storage/store.dart';

/// What an upload is for, and how big it may be (`protocol-v1.md` §6).
enum FilePurpose {
  logo(5 << 20, _images),
  productImage(10 << 20, _images),
  import(20 << 20, {"text/csv", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}),
  picture(5 << 20, _images),

  /// A file the master writes for its asker (`export.accounting`, M-60): never uploaded, read
  /// back by its owner only, for [FileStore.orphanAge].
  export(0, {"application/zip", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"});

  const FilePurpose(this.maxBytes, this.types);

  final int maxBytes;
  final Set<String> types;

  /// Whether `PUT /f` takes it.
  bool get uploadable => this != export;

  /// The `X-Lyra-Purpose` header value.
  String get header => switch (this) {
    productImage => "product_image",
    _ => name,
  };

  static FilePurpose? byHeader(String? value) {
    for (final purpose in values) {
      if (purpose.uploadable && purpose.header == value) return purpose;
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
/// references one ([claim]: a logo, a product image), only its uploader may read it back.
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

    if (_images.contains(type)) {
      final small = await _shrink(bytes, type);
      if (small != null) {
        final name = "$id@$thumbnailWidth";
        File(p.join(_folder, name)).writeAsBytesSync(
          await Envelope.seal(_key, small.bytes, context: "lyra/file/$name"),
          flush: true,
        );
      }
    }

    try {
      _store.write((db) => db.execute(
        "INSERT INTO files (id, purpose, content_type, size, owner, created) VALUES (?, ?, ?, ?, ?, ?)",
        [id, purpose.header, type, bytes.length, owner, _now().toUtc().toIso8601String()],
      ));
    } catch (_) {
      file.deleteSync();
      _deleteThumbnail(id);
      rethrow;
    }

    return id;
  }

  /// Keeps [bytes] the master made itself for [owner] (an export): sealed like an upload, never
  /// referenced, so only [owner] reads it and the sweep deletes it after [orphanAge]. Answers the
  /// id.
  Future<String> keep(FilePurpose purpose, Uint8List bytes, {required String contentType, required String owner}) async {
    if (purpose.uploadable || !purpose.types.contains(contentType)) throw ArgumentError.value(purpose, "purpose");

    final id = newId();
    final file = File(p.join(_folder, id));

    Directory(_folder).createSync(recursive: true);
    file.writeAsBytesSync(await Envelope.seal(_key, bytes, context: "lyra/file/$id"), flush: true);

    try {
      _store.write((db) => db.execute(
        "INSERT INTO files (id, purpose, content_type, size, owner, created) VALUES (?, ?, ?, ?, ?, ?)",
        [id, purpose.header, contentType, bytes.length, owner, _now().toUtc().toIso8601String()],
      ));
    } catch (_) {
      file.deleteSync();
      rethrow;
    }

    return id;
  }

  /// A referenced file's readers besides its permission's, by purpose: a till draws the product
  /// pictures without seeing the inventory (`pos.md` POS-1). Read here and not stored, so the
  /// images claimed before the POS release are covered too.
  static final Map<String, String> _alsoReadBy = {FilePurpose.productImage.header: "pos"};

  /// Reads [id] for [account] holding [grant]: the file's permission once a record references
  /// it (none: every member), its uploader until then. Anything else is `not_found`, so ids can't
  /// be probed.
  ///
  /// [size] asks for the thumbnail (`protocol-v1.md` §6): an image's is [thumbnailWidth] wide;
  /// a file without one (small already, or not an image) answers the original.
  Future<StoredFile> get(String id, {required String account, required Grant grant, int? size}) async {
    final rows = _store.db.select("SELECT * FROM files WHERE id = ?", [id]);
    if (rows.isEmpty) throw const EngineFailure("not_found");

    final row = rows.first;
    final permission = row["permission"] as String?;
    final also = _alsoReadBy[row["purpose"]];
    final allowed = row["referenced"] == 0
      ? row["owner"] == account
      : permission == null || grant.can(permission) || also != null && grant.can(also);
    final file = File(p.join(_folder, id));
    // An export is valid for [orphanAge] (M-60), not until the next sweep happens to run.
    final expired = row["purpose"] == FilePurpose.export.header &&
      DateTime.parse(row["created"] as String).add(orphanAge).isBefore(_now());

    if (!allowed || expired || !file.existsSync()) throw const EngineFailure("not_found");

    final small = File(p.join(_folder, "$id@$thumbnailWidth"));
    if (size != null && size <= thumbnailWidth && small.existsSync()) {
      final bytes = await Envelope.open(_key, small.readAsBytesSync(), context: "lyra/file/$id@$thumbnailWidth");

      return StoredFile(id: id, contentType: sniff(bytes) ?? "image/png", bytes: bytes);
    }

    return StoredFile(
      id: id,
      contentType: row["content_type"] as String,
      bytes: await Envelope.open(_key, file.readAsBytesSync(), context: "lyra/file/$id"),
    );
  }

  /// A record takes [id] (a logo, a product image): from now on whoever holds [permission]
  /// (null: every member) reads it, and the sweep leaves it alone. Only its [uploader]'s fresh upload of [purpose]
  /// can be taken; anything else is `invalid_file`. Runs inside the op's write.
  void claim(String id, FilePurpose purpose, {required String? permission, required String uploader}) {
    final rows = _store.db.select("SELECT * FROM files WHERE id = ?", [id]);
    final row = rows.isEmpty ? null : rows.first;

    if (row == null || row["purpose"] != purpose.header || row["referenced"] != 0 || row["owner"] != uploader) {
      throw const EngineFailure("invalid_file");
    }

    _store.write((db) => db.execute("UPDATE files SET referenced = 1, permission = ? WHERE id = ?", [permission, id]));
  }

  /// The bytes of [uploader]'s fresh upload [id] of [purpose], for an op that reads a file once
  /// (an import, I-40) instead of keeping it. Anything else is `invalid_file`. [discard] it after.
  Future<Uint8List> once(String id, FilePurpose purpose, {required String uploader}) async {
    final rows = _store.db.select("SELECT * FROM files WHERE id = ?", [id]);
    final row = rows.isEmpty ? null : rows.first;
    final file = File(p.join(_folder, id));

    if (row == null || row["purpose"] != purpose.header || row["referenced"] != 0 || row["owner"] != uploader || !file.existsSync()) {
      throw const EngineFailure("invalid_file");
    }

    return Envelope.open(_key, file.readAsBytesSync(), context: "lyra/file/$id");
  }

  /// Deletes [id] now: a file read [once] is never served again.
  void discard(String id) {
    _store.write((db) => db.execute("DELETE FROM files WHERE id = ?", [id]));

    final file = File(p.join(_folder, id));
    if (file.existsSync()) file.deleteSync();
    _deleteThumbnail(id);
  }

  /// The record let [id] go (a replaced logo): it becomes an orphan again, counted from now, and
  /// the sweep deletes it.
  void release(String id) => _store.write((db) => db.execute(
    "UPDATE files SET referenced = 0, created = ? WHERE id = ?",
    [_now().toUtc().toIso8601String(), id],
  ));

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
      _deleteThumbnail(id);
    }

    return ids.length;
  }

  void _deleteThumbnail(String id) {
    final small = File(p.join(_folder, "$id@$thumbnailWidth"));
    if (small.existsSync()) small.deleteSync();
  }

  /// How wide a stored thumbnail is: what a product tile, a summary row or a logo draw.
  static const thumbnailWidth = FileSizes.thumbnail;

  /// [bytes] scaled down to [thumbnailWidth], or null when they are that small already or can't
  /// be decoded. A JPEG stays a JPEG; the rest become PNG, which keeps a logo's transparency.
  static ({Uint8List bytes})? thumbnail(Uint8List bytes, String type) {
    final img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } on Object {
      // Bytes that start like an image and aren't one: kept as uploaded, served without a thumbnail.
      return null;
    }
    if (decoded == null || decoded.width <= thumbnailWidth) return null;

    final small = img.copyResize(decoded, width: thumbnailWidth, interpolation: img.Interpolation.average);

    return (bytes: type == "image/jpeg" ? img.encodeJpg(small, quality: 85) : img.encodePng(small));
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

  /// What a CSV is (I-40): UTF-16 with its BOM, or 8-bit text (UTF-8, or Windows-1252 as Excel
  /// saves it) without NUL or other control bytes than tab and line breaks.
  static bool _isText(Uint8List bytes) {
    if (bytes.length >= 2 && (bytes[0] == 0xff && bytes[1] == 0xfe || bytes[0] == 0xfe && bytes[1] == 0xff)) return true;

    for (final byte in bytes.take(64 * 1024)) {
      if (byte == 0 || (byte < 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d)) return false;
    }

    return true;
  }
}

/// [FileStore.thumbnail] off the server's isolate: decoding a 10 MB photo would stall every
/// connection. Top level, so the closure carries only the bytes.
Future<({Uint8List bytes})?> _shrink(Uint8List bytes, String type) => Isolate.run(() => FileStore.thumbnail(bytes, type));
