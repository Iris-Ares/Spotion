# Contributing to Spotion

Thanks for your interest in improving Spotion! This document covers everything you need to get from `git clone` to a merged pull request.

## Before you start

- For bug fixes and small improvements, just open a PR.
- For new features or behavior changes, please [open an issue](https://github.com/Iris-Ares/Spotion/issues/new/choose) first so we can agree on the direction before you invest time.
- By contributing, you agree that your contributions are licensed under the [MIT license](LICENSE), and you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Development setup

You need:

- macOS 26 (Tahoe) or later
- Xcode 26+ installed at `/Applications/Xcode.app` (the Makefile pins `DEVELOPER_DIR`, so `xcode-select` switching is not required)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

```bash
git clone https://github.com/Iris-Ares/Spotion.git
cd Spotion
make build   # Debug build (runs `make gen` implicitly)
make test    # unit tests
make run     # build & launch the Debug app
```

The `Spotion.xcodeproj` is **generated** from `project.yml` and is not checked in. Never edit the project file directly — change `project.yml` and re-run `make gen`. You can also open the generated project in Xcode and work from there.

### Testing Spotlight behavior

Spotlight and App Intents registration are picky about duplicate app copies:

- Always verify Spotlight behavior against the `/Applications/Spotion.app` copy (`make install`), not the DerivedData build — duplicates confuse LaunchServices.
- If actions or search results seem wedged after repeated rebuilds, run `make reset-registration`.
- The *Settings → Index* tab has a self-check that queries the CoreSpotlight index directly — use it to distinguish "the donation never landed" from "the Spotlight UI isn't showing it".

## Project layout

| Directory | Contents |
|---|---|
| `Spotion/Models/` | `SessionRecord`, settings, scan cache, agent kinds |
| `Spotion/Scanning/` | Codex/Claude scanners, bounded JSONL reader, `SessionStore` |
| `Spotion/Spotlight/` | CoreSpotlight indexer, App Entities and entity queries |
| `Spotion/Intents/` | App Intents (open session, new session, reindex) |
| `Spotion/Launch/` | Terminal/desktop-app launchers, binary resolver, shell quoting |
| `Spotion/Watching/` | FSEvents wrapper |
| `Spotion/UI/` | Menu bar, Settings, first-run window |
| `SpotionTests/` | Host-less unit tests for `Models/` + `Scanning/` |

## Style

- Swift 6 with **strict concurrency** (`SWIFT_STRICT_CONCURRENCY: complete`) — new code must compile without concurrency warnings. Prefer actors/`Sendable` designs over `nonisolated(unsafe)`; when an escape hatch is genuinely needed, justify it in a comment.
- Comments explain **constraints and non-obvious "why"**, not "what" — see the existing scanners for the house style. If a behavior exists because of an external quirk (an Apple API bug, an agent's file-format detail), document that quirk where the code handles it.
- Session-file parsing must stay **defensive and bounded**: both agents' formats are officially internal and version-unstable. Never read a transcript whole; follow the head/tail window patterns in `JSONLReader`.
- User-facing error messages should tell the user what to do next (see `TerminalLauncher` / `NativeAppLauncher` for examples).

## Tests

`SpotionTests` compiles the AppKit-free core sources directly (no app host), so tests run fast and headless:

- Scanner/parser changes need accompanying tests — fixtures are built in code (see `TestSupport.swift`).
- Pure logic (models, scanning, store) is the tested surface; UI and Spotlight donation are verified manually for now.
- Run `make test` before opening a PR.

## Pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org/) for commit messages and PR titles (`feat: …`, `fix: …`, `docs: …`, `chore: …`) — the existing history follows this.
- Keep PRs focused; unrelated cleanups belong in separate PRs.
- Describe **what** changed and **why**, note anything you tested manually (especially Spotlight-facing behavior), and link the issue it addresses.
- Update documentation (README, this file, `CHANGELOG.md` under *Unreleased*) when behavior changes.

## Localization

Parts of the UI are currently Chinese, parts English. If you'd like to help move Spotion to proper localization (String Catalogs), that contribution is very welcome — please open an issue to coordinate first.
