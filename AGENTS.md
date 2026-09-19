# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.

## Build environment sharp edges (this workstation)

- SwiftPM dependency fetch dies with `Failed to find credentials for 'https://github.com' in keychain: status -128` because the login keychain holds an inaccessible `github.com` internet password. Always pass `--disable-keychain` to `swift build` / `swift test` (SwiftPM still downloads public artifacts anonymously).
- `swift test` cannot run locally: CLT 15.1 ships no macOS XCTest (`xcrun --sdk macosx --find XCTest` fails, no Xcode installed). Local gate is `swift build --disable-keychain` plus the binary's render/smoke flags; the full `swift test --package-path darwin` suite is the PR CI's job (`.github/workflows/macos.yml`).
- Local toolchain 5.9.2 + `-Xswiftc -warnings-as-errors` fails on a pre-existing actor-isolation conversion at `YConnectStore.swift` (`models.map(Self.clientModelOption)`); CI's newer Xcode toolchains accept it. Don't "fix" that line just to satisfy a local strict build.

When updating this file, preserve this bar for all agents and keep entries concise.
