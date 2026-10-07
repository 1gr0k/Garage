# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Toolchain

Requires Xcode 27.2 (beta). `DEVELOPER_DIR` is already set via `.claude/settings.local.json` — do not export or prefix it; run `xcodebuild` / `swift` directly.

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer
```

Without it, `swift test` fails with `plugin for module 'TestingMacros' not found`.

## Commands

```sh
# Package tests (Swift Testing, not XCTest)
swift test --package-path Packages/GarageCore
swift test --package-path Packages/GarageCore --filter displayNameCombinesMakeAndModel   # single test
swift test --package-path Packages/GarageSync
swift test --package-path Packages/GarageAPI

# GarageStorage tests (iOS-only: no `swift test`; needs a simulator)
(cd Packages/GarageStorage && xcodebuild test -scheme GarageStorage -destination '<see CLAUDE.local.md>')

# App build
xcodebuild -project Garage.xcodeproj -scheme Garage -destination 'generic/platform=iOS Simulator' build

# List schemes / resolved packages (also a quick sanity check that the project file opens)
xcodebuild -project Garage.xcodeproj -list
```

There are no shared schemes checked in; Xcode auto-generates one per target (`Garage`) and one per local package product (`GarageCore`, `GarageStorage`, `GarageSync`, `GarageAPI`).

## Architecture

- **`Packages/GarageCore`** — local SwiftPM package holding the model/domain layer (`Vehicle`, sample data). Platform-independent (iOS 18 / macOS 15), so its logic is testable with plain `swift test`. Types consumed by the app must be `public`.
- **`Packages/GarageStorage`** — iOS-only local package with SwiftData persistence: `@Model` entities (`VehicleEntity`, `ServiceRecordEntity`, `PartEntity`) kept separate from the domain types, domain ↔ entity mapping (`toDomain()` / `update(from:)`), `GarageStore.makeContainer`, and `SampleSeeder`. Also the sync adapter: `SwiftDataSyncStore` (`SyncStore` + `ReceiptBlobStore` as a `ModelActor`), `SyncQueue` (puts local edits into the `PendingChangeEntity` queue in the same save as the data; `ServiceLog.add` / `VehicleLog.add` call it), `SyncSupport.prepare` (schema check + one-time bootstrap of existing data). Depends on `GarageCore`, `GarageSync` (and `GarageAPI`); direction is `GarageStorage → GarageSync → GarageAPI, GarageCore`. **Bump `GarageStore.schemaVersion` on every model change**: a mismatch resets the sync cursor and remembered versions so the next sync re-downloads everything. It can't build on macOS, so it is tested only via `xcodebuild test` on a simulator.
- **`Packages/GarageSync`** — local SwiftPM package for the sync layer: `SyncEngine` (push → pull, LWW conflict resolution), the `SyncStore` and `HTTPTransport` protocols (the latter with a URLSession implementation), DTO ↔ domain mapping. Platform-independent (iOS 18 / macOS 15, Linux), depends on `GarageCore` and `GarageAPI`, tested with plain `swift test`.
- **`Packages/GarageAPI`** — local SwiftPM package with the sync API contract: DTOs and the shared JSON config (`APICoding`). Platform-independent (iOS 18 / macOS 15), no dependencies (Foundation only); DTO ↔ domain mapping is the consumer's job. The contract is described in `docs/api.md`; its golden JSON examples (` ```json golden=<name> ` blocks) are read by the tests, tested with plain `swift test`.
- **`Garage/`** — the SwiftUI iOS app target. It's a *synchronized folder*: every file inside is automatically a member of the `Garage` target, so adding a Swift file needs no project-file edit. The app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and Swift 6 strict concurrency; the package does not set default MainActor isolation.

Put non-UI logic in `GarageCore` and keep the app target thin.

### Local server for end-to-end checks

```sh
TMP=<scratchpad>/e2e; mkdir -p $TMP; openssl rand -hex 16 > $TMP/secret
GARAGE_DB_PATH=$TMP/garage.sqlite GARAGE_SETUP_SECRET=$(cat $TMP/secret) \
  swift run --package-path Server GarageServer serve --hostname 127.0.0.1 --port 8080   # run in background
```

In the simulator app use `http://127.0.0.1:8080` (plain http is accepted for localhost only) and the secret from `$TMP/secret`. Uninstall the app first (`xcrun simctl uninstall <udid> <bundle id>`) for a fresh database. The setup secret is never stored by the app.

## Project file (`Garage.xcodeproj/project.xcproj`)

This is the new Xcode 27 JSON-based project format (JSON with trailing commas), not a `project.pbxproj`. There is no public documentation; **read `docs/xcproj-notes.md` before editing it** (notes are in Russian). Key points:

- After any manual edit, canonicalize with `$DEVELOPER_DIR/usr/bin/xcprojformatter --update Garage.xcodeproj` (not on `PATH`). It only validates schema — verify semantics with `xcodebuild -list` and a build.
- Linking a local package needs both a top-level `packages` entry (`"kind": "local"`, path relative to the directory containing the `.xcodeproj`) and a target `package-product-members` entry with `"build-phase": { "build-phase": "frameworks" }`.
- `package-product-members[].package` matches the package's **directory name**, not `name:` in `Package.swift`.

## Rules

- `GarageCore`, `GarageSync` and `GarageAPI` must build on Linux: Foundation is allowed; UIKit, SwiftUI, AppKit, Combine and other Apple-only frameworks are not.
- Golden JSON examples are edited only in `docs/api.md`; never copy them into tests.
- SwiftData only in `GarageStorage`.
- Never create or edit `project.pbxproj`; this project uses `project.xcproj` only.
- All new user-facing strings go into `Garage/Localizable.xcstrings` right away with a Russian translation (for counts, plural variations one/few/many/other). User data (e.g. `.other(text)`) must not reach the catalog: use `Text(verbatim:)` / `String`.
- macOS: do not use `sed -i` (BSD syntax differs) and do not shell out to python for edits — use the Edit tool. There is no `timeout` command on macOS (it fails with "command not found", so the command never runs): wait with a background run or Monitor instead. Debug files and scratch tests go only in the scratchpad directory, never in the repository (and remove any temporary test file you add).
- Code comments and `///` documentation are written in Russian. Identifiers (types, functions, variables, test functions), log messages and string-catalog keys stay in English. User-facing text goes through the catalog as before. Don't translate existing comments in files you aren't otherwise changing.
- Bash keeps the working directory between commands: create and edit files by paths from the repository root; use a subshell `(cd … && …)` for commands that must run elsewhere.
- Create and modify files only with the Write/Edit tools, never via shell redirection (`cat >`, heredoc, `tee`, `echo >`): hooks, /rewind and file permissions apply only to Write/Edit.

## Definition of done

1. `scripts/check.sh` passes. It runs the `linux` (package and Server tests), `ios` (GarageStorage tests on the simulator, app build) and `strings` (catalog fully translated) sections; `--only <section>` runs one. Destination comes from `$SIM_DESTINATION` or `CLAUDE.local.md`. New packages are added to the matching section of the script.
2. If `project.xcproj` changed: `xcprojformatter --update` was run and `git diff` of it is minimal.
