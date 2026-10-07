# Robo Tribute

A MongoDB client in memory of Robo 3T.

A native macOS (Apple Silicon) re-implementation of the classic **Robo 3T 1.4** GUI: same layout, icons, dialogs and
shortcuts, built on a current MongoDB driver so it works with MongoDB 3.6 to 8.x. Robo 3T is no longer maintained, its
legacy shell fails against newer servers and there is no arm64 build. This project keeps the UI and replaces the
internals.

## Run it

Requirements: macOS 14+ on Apple Silicon, Xcode, CMake and Ninja (`brew install cmake ninja`).

```sh
./scripts/build-app.sh          # builds dependencies on first run, then build/Robo Tribute.app
open "build/Robo Tribute.app"
```

Copy the app to `/Applications` to keep it.

## Use it

- **Connect:** File → Connect... (⌘N), then Create. Enter host and port, or paste a `mongodb://` / `mongodb+srv://` URI via
  "From URI". Use Test to check the connection before saving.
- **Remote servers** need TLS with a valid certificate or an SSH tunnel; the app refuses unencrypted connections to
  anything other than `localhost`.
- **Query:** double-click a collection to open a shell tab with `find({})`. Run with F5 or ⌘↩; the shell accepts both the legacy shell API
  (`insert`, `update`, `count`, `use db`, `show collections`) and the current one (`insertOne`, `updateMany`, ...).
- **Results** show as tree, table or text. Right-click a document to edit, insert, delete or copy it.
- On first launch, connections from an installed Robo 3T are imported. Passwords are not; enter them once and they are
  stored in the macOS Keychain.

## Develop

```sh
./scripts/build-deps.sh   # static OpenSSL + MongoDB C driver into .deps/ (once, or after a version bump)
xcrun swift run           # debug build, runs without packaging
xcrun swift test
```

- Sources: `Sources/RoboTribute` (AppKit UI, Mongo connection, JavaScriptCore shell in `Resources/shell.js`).
- App icon: `packaging/AppIcon.icon`, compiled by `actool` in `build-app.sh`.
- `build-app.sh` signs with the first Apple Development / Developer ID identity in your keychain, so Keychain access
  survives rebuilds; override with `CODESIGN_IDENTITY`.
- `ROBO_TRIBUTE_SETTINGS_DIR` points the app at a separate settings directory, to keep dev and real connections apart.
- Secrets never go into the repo: passwords live in the Keychain, and `.env*`, keys, certificates and settings files
  are gitignored.

Integration tests skip unless their local server is configured; never point them at a shared database:

| Tests | Needs |
| --- | --- |
| `ShellTests`, `SnapshotTests` | a `mongod` on `ROBO3T_TEST_PORT` (default 27999), seeded with `scripts/seed-test-db.sh` |
| `TLSTests` | a `mongod --tlsMode requireTLS --auth`; `ROBO3T_TLS_PORT`, `ROBO3T_TLS_CA`, `ROBO3T_TLS_CLIENT_PEM`, `ROBO3T_TLS_USER`, `ROBO3T_TLS_PASSWORD` |
| `SSHTunnelTests` | a local `sshd`; `ROBO3T_SSH_PORT`, `ROBO3T_SSH_KEY`, `ROBO3T_SSH_PASSPHRASE` |

## Security

- TLS 1.2/1.3 with certificate, hostname and OCSP checks. Disabling verification only works against loopback.
- Passwords and passphrases are stored only in the Keychain; `settings.json` (mode 0600) holds no secrets.
- SSH uses the system OpenSSH client; a server's host key is pinned on first connect and a changed key is rejected.
- Dependency tarballs are checked against pinned SHA-256 hashes in `scripts/build-deps.sh`.

## Thank you, Robo 3T

This app only exists because of [Robo 3T](https://github.com/Studio3T/robomongo), formerly Robomongo. Its design,
dialogs, icons and document formatting are the work of its authors; this project re-implements them and claims none of
it as its own. Thanks to [@schetnikovich](https://github.com/schetnikovich), [@simsekgokhan](https://github.com/simsekgokhan),
[@stennie](https://github.com/stennie), [all other contributors](https://github.com/Studio3T/robomongo/graphs/contributors)
and 3T Software Labs for keeping it open source. For a supported commercial MongoDB IDE, see
[Studio 3T](https://studio3t.com).

## License

GPLv3, like Robo 3T. See `THIRD_PARTY_NOTICES.md` for third-party material. "Robo 3T" is a trademark of 3T Software
Labs; this project is not affiliated with them.
