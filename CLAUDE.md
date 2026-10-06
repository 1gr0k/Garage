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

# GarageStorage tests (iOS-only: no `swift test`; needs a simulator)
(cd Packages/GarageStorage && xcodebuild test -scheme GarageStorage -destination '<see CLAUDE.local.md>')

# App build
xcodebuild -project Garage.xcodeproj -scheme Garage -destination 'generic/platform=iOS Simulator' build

# List schemes / resolved packages (also a quick sanity check that the project file opens)
xcodebuild -project Garage.xcodeproj -list
```

There are no shared schemes checked in; Xcode auto-generates one per target (`Garage`) and one per local package product (`GarageCore`).

## Architecture

- **`Packages/GarageCore`** — local SwiftPM package holding the model/domain layer (`Vehicle`, sample data). Platform-independent (iOS 18 / macOS 15), so its logic is testable with plain `swift test`. Types consumed by the app must be `public`.
- **`Packages/GarageStorage`** — iOS-only local package with SwiftData persistence: `@Model` entities (`VehicleEntity`, `ServiceRecordEntity`, `PartEntity`) kept separate from the domain types, domain ↔ entity mapping (`toDomain()` / `update(from:)`), `GarageStore.makeContainer`, and `SampleSeeder`. Depends on `GarageCore`. It can't build on macOS, so it is tested only via `xcodebuild test` on a simulator.
- **`Garage/`** — the SwiftUI iOS app target. It's a *synchronized folder*: every file inside is automatically a member of the `Garage` target, so adding a Swift file needs no project-file edit. The app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and Swift 6 strict concurrency; the package does not set default MainActor isolation.

Put non-UI logic in `GarageCore` and keep the app target thin.

## Project file (`Garage.xcodeproj/project.xcproj`)

This is the new Xcode 27 JSON-based project format (JSON with trailing commas), not a `project.pbxproj`. There is no public documentation; **read `docs/xcproj-notes.md` before editing it** (notes are in Russian). Key points:

- After any manual edit, canonicalize with `$DEVELOPER_DIR/usr/bin/xcprojformatter --update Garage.xcodeproj` (not on `PATH`). It only validates schema — verify semantics with `xcodebuild -list` and a build.
- Linking a local package needs both a top-level `packages` entry (`"kind": "local"`, path relative to the directory containing the `.xcodeproj`) and a target `package-product-members` entry with `"build-phase": { "build-phase": "frameworks" }`.
- `package-product-members[].package` matches the package's **directory name**, not `name:` in `Package.swift`.

## Rules

- `GarageCore` must build on Linux: Foundation is allowed; UIKit, SwiftUI, AppKit, Combine and other Apple-only frameworks are not.
- SwiftData only in `GarageStorage`.
- Never create or edit `project.pbxproj`; this project uses `project.xcproj` only.
- Edit files with the Edit tool or `python3`, not `sed -i`: macOS ships BSD sed, where `sed -i` needs a backup-suffix argument and `sed -i '1i …'` fails.
- All new user-facing strings go into `Garage/Localizable.xcstrings` right away with a Russian translation (for counts, plural variations one/few/many/other). User data (e.g. `.other(text)`) must not reach the catalog: use `Text(verbatim:)` / `String`.
- macOS: do not use `sed -i` (BSD syntax differs) and do not shell out to python for edits — use the Edit tool.

## Definition of done

1. `swift test --package-path Packages/GarageCore` passes.
2. `xcodebuild test` for GarageStorage passes (see Commands; destination from `CLAUDE.local.md`).
3. The app builds with the `xcodebuild … build` command above.
4. If `project.xcproj` changed: `xcprojformatter --update` was run and `git diff` of it is minimal.
5. The catalog is fully translated: this command prints nothing (it lists keys that are stale, lack `ru`, have a `ru` state other than `translated`, or have a `ru` plural missing one/few/many/other):
   ```sh
   jq -r '.strings | to_entries[]
     | select(.value.shouldTranslate != false)
     | .key as $k | .value as $v | $v.localizations.ru as $ru
     | select($v.extractionState == "stale"
         or $ru == null
         or ([$ru | .. | .state? // empty] | any(. != "translated"))
         or ($ru.variations.plural != null
             and ([$ru.variations.plural | has("one","few","many","other")] | all | not)))
     | $k' Garage/Localizable.xcstrings
   ```
