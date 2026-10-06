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

# App build
xcodebuild -project Garage.xcodeproj -scheme Garage -destination 'generic/platform=iOS Simulator' build

# List schemes / resolved packages (also a quick sanity check that the project file opens)
xcodebuild -project Garage.xcodeproj -list
```

There are no shared schemes checked in; Xcode auto-generates one per target (`Garage`) and one per local package product (`GarageCore`).

## Architecture

- **`Packages/GarageCore`** — local SwiftPM package holding the model/domain layer (`Vehicle`, sample data). Platform-independent (iOS 18 / macOS 15), so its logic is testable with plain `swift test`. Types consumed by the app must be `public`.
- **`Garage/`** — the SwiftUI iOS app target. It's a *synchronized folder*: every file inside is automatically a member of the `Garage` target, so adding a Swift file needs no project-file edit. The app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and Swift 6 strict concurrency; the package does not set default MainActor isolation.

Put non-UI logic in `GarageCore` and keep the app target thin.

## Project file (`Garage.xcodeproj/project.xcproj`)

This is the new Xcode 27 JSON-based project format (JSON with trailing commas), not a `project.pbxproj`. There is no public documentation; **read `docs/xcproj-notes.md` before editing it** (notes are in Russian). Key points:

- After any manual edit, canonicalize with `$DEVELOPER_DIR/usr/bin/xcprojformatter --update Garage.xcodeproj` (not on `PATH`). It only validates schema — verify semantics with `xcodebuild -list` and a build.
- Linking a local package needs both a top-level `packages` entry (`"kind": "local"`, path relative to the directory containing the `.xcodeproj`) and a target `package-product-members` entry with `"build-phase": { "build-phase": "frameworks" }`.
- `package-product-members[].package` matches the package's **directory name**, not `name:` in `Package.swift`.

## Rules

- `GarageCore` must build on Linux: Foundation is allowed; UIKit, SwiftUI, AppKit, Combine and other Apple-only frameworks are not.
- Never create or edit `project.pbxproj`; this project uses `project.xcproj` only.

## Definition of done

1. `swift test --package-path Packages/GarageCore` passes.
2. The app builds with the `xcodebuild … build` command above.
3. If `project.xcproj` changed: `xcprojformatter --update` was run and `git diff` of it is minimal.
