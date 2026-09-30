import 'dart:io';

import 'package:path/path.dart' as p;

/// The engine's data folder and what lives in it. Only the signed-in OS user can read it (it's
/// under their profile), and everything sensitive in it is encrypted anyway (plan §6.1).
final class NodePaths {
  const NodePaths(this.root);

  /// Where a master keeps its data when the app doesn't say otherwise:
  /// `%LOCALAPPDATA%\Lyra\node`, `~/Library/Application Support/Lyra/node`, or
  /// `$XDG_DATA_HOME/lyra/node` (`~/.local/share/lyra/node`).
  factory NodePaths.platform() {
    final env = Platform.environment;

    if (Platform.isWindows) {
      return NodePaths(p.join(env["LOCALAPPDATA"] ?? env["APPDATA"]!, "Lyra", "node"));
    }

    final home = env["HOME"]!;

    if (Platform.isMacOS) {
      return NodePaths(p.join(home, "Library", "Application Support", "Lyra", "node"));
    }

    final data = env["XDG_DATA_HOME"];
    return NodePaths(p.join(data == null || data.isEmpty ? p.join(home, ".local", "share") : data, "lyra", "node"));
  }

  final String root;

  String get database => p.join(root, "lyra.db");

  String get keyring => p.join(root, "keyring.json");

  /// Held exclusively by the running engine: one engine per data folder (plan §3).
  String get lock => p.join(root, "engine.lock");

  /// What the running engine says about itself (`EngineStatusFile`).
  String get state => p.join(root, "engine.state.json");

  /// Signed stop requests from `lyra_node stop` (`ControlChannel`).
  String get control => p.join(root, "control");

  String get logs => p.join(root, "logs");

  String get backups => p.join(root, "backups");
}
