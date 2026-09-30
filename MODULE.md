# Module: lyra_node

**Path** `E:/andromeda/frontend/packages/lyra_node` (own git repo, pure Dart, no Flutter)
**Role** The engine that runs on the master (`lyra/app/docs/plan-offline-lan.md` §3, §8): one company, encrypted,
one writer. Phase 2 has storage, keys, oplog, identities, audit and the process lifecycle; the network is phase 3,
the domains phase 4. Rules come from `lyra/app/docs/offline/specs/*`, never from backend code (plan principle 1).
**Used by** `lyra/app` through the executable only (`LocalServerService`), never as a Dart import.

## Files

- `bin/lyra_node.dart` — the executable: `setup`, `run`, `status`, `stop`, `recover`, `version`; one JSON line out,
  secrets only on stdin. Table of commands in its `///`.
- `lib/lyra_node.dart` — barrel (for `bin/` and tests).
- `lib/src/engine.dart` — `Engine` (`setup`, `open`, `recover`, `close`, `controlKey`), `OwnerDraft`, `engineVersion`,
  `minAppVersion`.
- `lib/src/failure.dart` — `EngineFailure` (a rule's refusal: stable `code` + `data`, no message).
- `lib/src/ids.dart` — `newId()` (UUIDv7).
- `lib/src/canonical_json.dart` — `canonicalJson` (sorted keys; what gets hashed).
- `lib/src/crypto/secrets.dart` — `randomBytes`, `wipe`, `constantTimeEquals`, `Argon2Params`, `argon2id`, `subkey` (HKDF).
- `lib/src/crypto/envelope.dart` — `Envelope` (AES-256-GCM, version byte, context as AAD), `EnvelopeError`.
- `lib/src/crypto/keyring.dart` — `KeyringStore` (`keyring.json`: DEK wrapped by KEK and by the recovery key; `create`,
  `unlock`, `recover`, `rewrap`), `Keyring` (DEK in memory, `databaseKey`, `derive`), `UnlockMode`, `KeyringError`.
- `lib/src/crypto/recovery.dart` — `RecoveryKey` (256 bits as 24 BIP-39 words, checksum, 4-letter prefixes).
- `lib/src/crypto/wordlist.dart` — the BIP-39 English list.
- `lib/src/crypto/vault.dart` — `KeyVault` (`platform`), `WindowsVault` (DPAPI, FFI), `MacVault` (`security -i`),
  `LinuxVault` (`secret-tool`), `MemoryVault` (tests).
- `lib/src/storage/store.dart` — `Store` (SQLCipher open with a raw key, refuses a library without cipher; WAL,
  `synchronous=FULL`; `write` = one `BEGIN IMMEDIATE` transaction), `StoreError`.
- `lib/src/storage/migrations.dart` — `Migration`, `migrations`, `migrate` (pre-migration copy, one transaction per step),
  `DatabaseTooNew`.
- `lib/src/storage/migrations/m001_core.dart` — `meta`, `oplog`, `commands`, `audit`, `accounts`, `grants`.
- `lib/src/oplog/hlc.dart` — `Hlc` (packed, sortable), `HlcClock` (never backwards, `maxDrift`), `ClockDrift`.
- `lib/src/oplog/oplog.dart` — `Oplog` (`append` inside the write, `since`, `lastSeq`, `lastHlc`), `OplogEntry`.
- `lib/src/oplog/commands.dart` — `CommandLedger` (`commandId` idempotence, 30 days), `CommandReused`.
- `lib/src/audit/audit_log.dart` — `AuditLog` (hash-chained, `append`, `verify`, `list`), `AuditEntry`, `AuditKinds`.
- `lib/src/identity/passwords.dart` — `PasswordHasher` (Argon2id PHC strings, `needsRehash`).
- `lib/src/identity/accounts.dart` — `Accounts` (`createOwner`, `verifyPassword` with lockout), `Account`, `AccountStatus`.
- `lib/src/process/paths.dart` — `NodePaths` (data folder per OS and its files).
- `lib/src/process/lock.dart` — `InstanceLock` (exclusive OS lock, one engine per folder).
- `lib/src/process/control.dart` — `EngineStatusFile` (`engine.state.json`, HMAC-signed), `EnginePhase`, `ControlChannel`
  (signed stop requests in `control/`).
- `lib/src/process/runner.dart` — `NodeRunner` (lock → state → unlock → wait for stop), `ExitCodes`.
- `lib/src/process/status.dart` — `readStatus`, `stopEngine`, `NodeStatus` (the app's side, run through the CLI).
- `lib/src/process/engine_log.dart` — `EngineLog` (`logs/engine.log`, rotated; no secrets, no company data).
- `test/support.dart` — fast Argon2 params, temp data folders, `setUpMaster`.
- `test/support/launch_detached.dart` — plays the app: starts the engine detached and exits.
- `test/crypto_test.dart`, `keyring_test.dart`, `storage_test.dart`, `oplog_test.dart`, `engine_test.dart` — units.
- `test/process_test.dart` — the built executable with the real vault (Windows only, tag `process`).

## Invariants

- Nothing is ever written unencrypted: `Store.open` refuses a SQLite without SQLCipher (`hooks.user_defines` in
  `pubspec.yaml` picks it), and every secret at rest is wrapped (`Envelope`, DPAPI/Keychain/libsecret).
- Only `Keyring` holds the DEK; every key in use is `Keyring.derive(<purpose>)`. A new purpose string is a new key.
- A change, its oplog entry, its audit entry and its `commandId` answer are written in the **same** `Store.write`.
- Migrations are forward only: a released one is never edited.
- The engine never starts by itself (plan D4): nothing here installs a service, login item or scheduled task.
- The app ↔ engine control path of phase 2 is files in the data folder signed with the control key (vault); the
  signed state file is how the app knows the process is ours. Phase 3 adds the TLS channel.

## Commands

```
dart analyze                          # must report "No issues found!"
dart test                             # all (process tests build the executable first)
dart test -x process                  # without the slow process tests
dart build cli                        # build/cli/<os>_<arch>/bundle/{bin/lyra_node(.exe), lib/sqlcipher.*}
```
