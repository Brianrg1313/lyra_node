import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'envelope.dart';
import 'recovery.dart';
import 'secrets.dart';
import 'vault.dart';

/// How the key that wraps the DEK (the KEK) is obtained when the engine starts (plan §6.2).
enum UnlockMode {
  /// A random KEK kept in the OS vault. The engine starts on its own; the default.
  unattended,

  /// Argon2id of the owner's passphrase. The engine starts locked until the app on the master
  /// sends it; a stolen disk with a broken OS vault still doesn't open.
  passphrase,
}

/// Why the keys can't be loaded. [KeyringFailure.missing] is "not set up"; the rest are "set
/// up, but not with what was given".
enum KeyringFailure {
  missing,

  /// Unattended mode and the vault no longer holds the KEK (another OS user, a reinstalled OS,
  /// a restored disk). Only the recovery key opens the data now.
  vaultSecretMissing,

  wrongPassphrase,
  wrongRecoveryKey,

  /// Passphrase mode and none was given.
  passphraseRequired,

  /// The keyring file was altered or isn't one.
  corrupt,
}

final class KeyringError implements Exception {
  const KeyringError(this.failure);

  final KeyringFailure failure;

  @override
  String toString() => "KeyringError(${failure.name})";
}

/// The unlocked keys, in memory only. Every key the engine uses is derived from the DEK for
/// one purpose ([derive]); the DEK itself never leaves this object.
final class Keyring {
  Keyring._(this.instanceId, this._dek);

  final String instanceId;
  final Uint8List _dek;
  bool _disposed = false;

  /// The SQLCipher raw key of the database.
  Future<Uint8List> databaseKey() => derive("lyra/db/v1");

  Future<Uint8List> derive(String purpose) {
    if (_disposed) throw StateError("The keyring was closed");

    return subkey(_dek, purpose);
  }

  void dispose() {
    wipe(_dek);
    _disposed = true;
  }
}

/// `keyring.json`: the DEK wrapped twice, once by the KEK of the chosen [UnlockMode] and once
/// by the recovery key. It holds no usable secret by itself, so it travels in backups as is.
///
/// ```json
/// {"format": 1, "instanceId": "…", "mode": "passphrase",
///  "kdf": {"m": 65536, "t": 3, "p": 1, "salt": "<b64>"},   // passphrase mode only
///  "dek": "<b64 envelope>", "recovery": "<b64 envelope>"}
/// ```
final class KeyringStore {
  KeyringStore(this.path, this.vault);

  final String path;
  final KeyVault vault;

  static const _format = 1;
  static const _dekContext = "lyra/dek/kek";
  static const _recoveryContext = "lyra/dek/recovery";

  File get _file => File(path);

  bool get exists => _file.existsSync();

  static String kekName(String instanceId) => "kek.$instanceId";

  /// The mode the keyring was written with, or null when there is none.
  UnlockMode? get mode {
    if (!exists) return null;

    return UnlockMode.values.byName(_read()["mode"] as String);
  }

  String get instanceId => _read()["instanceId"] as String;

  /// Makes a new DEK and recovery key. [passphrase] chooses passphrase mode; without it the KEK
  /// goes to the vault. The recovery key is answered once, here, and never stored.
  Future<({Keyring keyring, RecoveryKey recovery})> create({
    required String instanceId,
    String? passphrase,
    Argon2Params params = Argon2Params.standard,
  }) async {
    if (exists) throw StateError("A keyring already exists at $path");

    final dek = randomBytes(32);
    final recovery = RecoveryKey.generate();

    await _write(
      instanceId: instanceId,
      dek: dek,
      recoveryWrap: await Envelope.seal(
        await _recoveryKek(recovery),
        dek,
        context: _recoveryContext,
      ),
      passphrase: passphrase,
      params: params,
    );

    return (keyring: Keyring._(instanceId, dek), recovery: recovery);
  }

  /// Loads the DEK the usual way: from the vault, or from [passphrase] in passphrase mode.
  Future<Keyring> unlock({String? passphrase}) async {
    if (!exists) throw const KeyringError(KeyringFailure.missing);

    final json = _read();
    final id = json["instanceId"] as String;
    final Uint8List kek;

    if (UnlockMode.values.byName(json["mode"] as String) == UnlockMode.passphrase) {
      if (passphrase == null) throw const KeyringError(KeyringFailure.passphraseRequired);

      final kdf = json["kdf"] as Map<String, Object?>;
      kek = await argon2id(passphrase, base64.decode(kdf["salt"] as String), Argon2Params.fromJson(kdf));
    } else {
      kek = await vault.read(kekName(id)) ??
        (throw const KeyringError(KeyringFailure.vaultSecretMissing));
    }

    try {
      return Keyring._(
        id,
        await Envelope.open(kek, base64.decode(json["dek"] as String), context: _dekContext),
      );
    } on EnvelopeError {
      throw KeyringError(
        passphrase == null ? KeyringFailure.corrupt : KeyringFailure.wrongPassphrase,
      );
    } finally {
      wipe(kek);
    }
  }

  /// Opens the DEK with the recovery key and wraps it again under a new KEK: the vault of this
  /// machine, or [passphrase]. That is how a forgotten passphrase, a lost vault or a new
  /// computer gets the data back (plan §6.2, §10.3). The recovery key stays the same.
  Future<Keyring> recover(RecoveryKey key, {String? passphrase, Argon2Params params = Argon2Params.standard}) async {
    if (!exists) throw const KeyringError(KeyringFailure.missing);

    final json = _read();
    final id = json["instanceId"] as String;
    final recoveryWrap = base64.decode(json["recovery"] as String);
    final Uint8List dek;

    try {
      dek = await Envelope.open(await _recoveryKek(key), recoveryWrap, context: _recoveryContext);
    } on EnvelopeError {
      throw const KeyringError(KeyringFailure.wrongRecoveryKey);
    }

    await _write(
      instanceId: id,
      dek: dek,
      recoveryWrap: recoveryWrap,
      passphrase: passphrase,
      params: params,
    );

    return Keyring._(id, dek);
  }

  /// Wraps the DEK of an unlocked [keyring] under a new KEK (plan §6.2 "re-wrap": cheap, the
  /// data isn't touched). Switches between unattended and passphrase mode too.
  Future<void> rewrap(Keyring keyring, {String? passphrase, Argon2Params params = Argon2Params.standard}) async {
    await _write(
      instanceId: keyring.instanceId,
      dek: keyring._dek,
      recoveryWrap: base64.decode(_read()["recovery"] as String),
      passphrase: passphrase,
      params: params,
    );
  }

  Future<void> _write({
    required String instanceId,
    required Uint8List dek,
    required List<int> recoveryWrap,
    required String? passphrase,
    required Argon2Params params,
  }) async {
    final salt = randomBytes(16);
    final kek = passphrase == null ? randomBytes(32) : await argon2id(passphrase, salt, params);

    final json = {
      "format": _format,
      "instanceId": instanceId,
      "mode": (passphrase == null ? UnlockMode.unattended : UnlockMode.passphrase).name,
      if (passphrase != null) "kdf": {...params.toJson(), "salt": base64.encode(salt)},
      "dek": base64.encode(await Envelope.seal(kek, dek, context: _dekContext)),
      "recovery": base64.encode(recoveryWrap),
    };

    // The vault is written first: a crash between the two leaves an unused vault secret, never
    // a keyring whose KEK is nowhere.
    if (passphrase == null) {
      await vault.write(kekName(instanceId), kek);
    } else {
      await vault.delete(kekName(instanceId));
    }
    wipe(kek);

    final temporary = File("$path.tmp");
    temporary.parent.createSync(recursive: true);
    temporary.writeAsStringSync(jsonEncode(json), flush: true);
    temporary.renameSync(path);
  }

  Map<String, Object?> _read() {
    try {
      final json = jsonDecode(_file.readAsStringSync());

      if (json is! Map<String, Object?> || json["format"] != _format) {
        throw const KeyringError(KeyringFailure.corrupt);
      }

      return json;
    } on FormatException {
      throw const KeyringError(KeyringFailure.corrupt);
    }
  }

  /// The recovery key already carries 256 random bits, so it needs no Argon2 stretching.
  static Future<Uint8List> _recoveryKek(RecoveryKey key) => subkey(key.entropy, "lyra/recovery/v1");
}
