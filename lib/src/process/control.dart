import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:lyra_protocol/lyra_protocol.dart' show canonicalJson;
import '../crypto/secrets.dart';
import 'paths.dart';

/// What the running engine is doing, as it writes it in `engine.state.json`.
enum EnginePhase {
  starting,

  /// Passphrase mode, waiting for the passphrase (plan §6.2).
  locked,

  ready,
  stopping,
}

/// `engine.state.json`: the running engine's pid, phase and versions, signed with the control
/// key (HMAC-SHA256 over the canonical JSON of every other field).
///
/// The signature is how `lyra_node status`, run by the app, tells **our** engine from any other
/// process holding the lock or writing the file (plan §3, "on attach, the app checks that the
/// running process is our engine"): only a process with the control key from the OS vault can
/// write a valid one.
final class EngineStatusFile {
  const EngineStatusFile({
    required this.pid,
    required this.instanceId,
    required this.version,
    required this.protocol,
    required this.phase,
    required this.startedAt,
    this.port,
  });

  final int pid;
  final String instanceId;
  final String version;
  final int protocol;
  final EnginePhase phase;
  final DateTime startedAt;

  /// The LAN port, once the network layer listens (phase 3).
  final int? port;

  Map<String, Object?> toJson() => {
    "pid": pid,
    "instanceId": instanceId,
    "version": version,
    "protocol": protocol,
    "phase": phase.name,
    "startedAt": startedAt.toUtc().toIso8601String(),
    "port": port,
  };

  EngineStatusFile copyWith({EnginePhase? phase, int? port}) => EngineStatusFile(
    pid: pid,
    instanceId: instanceId,
    version: version,
    protocol: protocol,
    phase: phase ?? this.phase,
    startedAt: startedAt,
    port: port ?? this.port,
  );

  /// Writes it signed with [controlKey], atomically (a reader never sees half a file).
  void write(String path, List<int> controlKey) {
    final json = toJson();
    final temporary = File("$path.tmp");

    temporary.writeAsStringSync(jsonEncode({...json, "proof": _mac(controlKey, canonicalJson(json))}), flush: true);
    temporary.renameSync(path);
  }

  /// Reads the file at [path]. Null when it isn't there, isn't whole, or isn't signed with
  /// [controlKey].
  static EngineStatusFile? read(String path, List<int> controlKey) {
    final Map<String, Object?> json;

    try {
      json = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    } on Object {
      return null;
    }

    final proof = json.remove("proof");
    if (proof is! String || !constantTimeEquals(utf8.encode(proof), utf8.encode(_mac(controlKey, canonicalJson(json))))) {
      return null;
    }

    try {
      return EngineStatusFile(
        pid: json["pid"] as int,
        instanceId: json["instanceId"] as String,
        version: json["version"] as String,
        protocol: json["protocol"] as int,
        phase: EnginePhase.values.byName(json["phase"] as String),
        startedAt: DateTime.parse(json["startedAt"] as String),
        port: json["port"] as int?,
      );
    } on Object {
      return null;
    }
  }
}

/// The app → engine control path of phase 2: signed request files in the data folder.
///
/// It needs no network, so it works before the LAN layer exists and while the engine is
/// locked. A request is honoured only when its HMAC is made with the control key (only the
/// engine binary, as the same OS user, reads it from the vault) and it is younger than
/// [maxAge], so a request copied from earlier can't stop the engine again.
final class ControlChannel {
  ControlChannel(this.paths, this._controlKey);

  static const maxAge = Duration(minutes: 2);
  static const _stop = "stop";

  final NodePaths paths;
  final Uint8List _controlKey;
  final Set<String> _seen = {};

  /// Asks the running engine to stop.
  void requestStop({DateTime? now}) {
    final nonce = base64Url.encode(randomBytes(12));
    final at = (now ?? DateTime.now()).toUtc().toIso8601String();
    final temporary = File(p.join(paths.control, "pending-$nonce.json"));

    // Written under another name and renamed, so the engine never reads half a request.
    Directory(paths.control).createSync(recursive: true);
    temporary.writeAsStringSync(jsonEncode({
      "nonce": nonce,
      "at": at,
      "mac": _mac(_controlKey, "$_stop|$nonce|$at"),
    }), flush: true);
    temporary.renameSync(p.join(paths.control, "$_stop-$nonce.json"));
  }

  /// Engine side: answers true once a valid stop request is in the folder. Every request file
  /// is removed once read, valid or not.
  bool takeStopRequest({DateTime? now}) {
    final folder = Directory(paths.control);
    if (!folder.existsSync()) return false;

    var stop = false;

    for (final file in folder.listSync().whereType<File>()) {
      if (!p.basename(file.path).startsWith("$_stop-")) continue;

      try {
        final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        final nonce = json["nonce"] as String;
        final at = DateTime.parse(json["at"] as String);
        final age = (now ?? DateTime.now()).toUtc().difference(at);
        final expected = _mac(_controlKey, "$_stop|$nonce|${json["at"]}");

        if (constantTimeEquals(utf8.encode(json["mac"] as String), utf8.encode(expected)) &&
            !age.isNegative && age < maxAge && _seen.add(nonce)) {
          stop = true;
        }
      } on Object {
        // Not a request of ours: dropped below like any other.
      }

      try {
        file.deleteSync();
      } on FileSystemException {
        // Held open by an antivirus scan or the like: tried again on the next poll, and the
        // nonce already seen keeps it from counting twice.
      }
    }

    return stop;
  }
}

String _mac(List<int> key, String message) =>
  Hmac(sha256, key).convert(utf8.encode(message)).toString();
