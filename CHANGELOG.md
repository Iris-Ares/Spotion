# Changelog

All notable changes to Spotion are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Until the first tagged release, everything lives under *Unreleased*; once GitHub
Releases exist ([#5](https://github.com/Iris-Ares/Spotion/issues/5)), each release
will get a dated section here that doubles as its release notes.

## [Unreleased]

### Added

- Spotlight indexing of Codex CLI (`~/.codex`) and Claude Code (`~/.claude`)
  sessions as App Entities in a named CoreSpotlight index, searchable by title,
  first prompt, project, directory, and git branch
  ([#1](https://github.com/Iris-Ares/Spotion/pull/1)).
- Resume-in-terminal on <kbd>⏎</kbd>: `codex resume` / `claude --resume` in
  Terminal.app or Ghostty, `cd`-ed to the session's working directory
  ([#1](https://github.com/Iris-Ares/Spotion/pull/1)).
- Quick Create Spotlight actions (*New Codex Session* / *New Claude Session*)
  with inline prompt and project picker ([#1](https://github.com/Iris-Ares/Spotion/pull/1)).
- Menu-bar app with recent sessions, index statistics, rescan/rebuild actions,
  scan-report copy, first-run welcome window, and Settings (agent toggles,
  terminal choice, binary-path overrides, launch at login, index self-check)
  ([#1](https://github.com/Iris-Ares/Spotion/pull/1)).
- File watching of both agents' data directories with incremental index
  refreshes and an hourly reconcile ([#1](https://github.com/Iris-Ares/Spotion/pull/1)).
- Per-agent launch preference: open sessions in the terminal CLI or in the
  agent's desktop app via `codex://` / `claude://` deep links
  ([#6](https://github.com/Iris-Ares/Spotion/pull/6)).
- Liquid Glass app icon and matching menu-bar icon
  ([#7](https://github.com/Iris-Ares/Spotion/pull/7)).
- Homebrew install via `brew install --cask Iris-Ares/tap/spotion`, served from the
  [Iris-Ares/homebrew-tap](https://github.com/Iris-Ares/homebrew-tap) repository;
  the release workflow bumps the cask automatically on every tag
  ([#16](https://github.com/Iris-Ares/Spotion/pull/16)).
- Find a session by pasting its exact session ID into Spotlight; `codex:<id>` /
  `claude:<id>` narrow the match to one agent
  ([#52](https://github.com/Iris-Ares/Spotion/pull/52)).
- *Continue Latest Codex Session* / *Continue Latest Claude Session* Spotlight
  actions: resume the newest session of one agent, optionally scoped to a project,
  chosen from Spotion's own index rather than the CLI's implicit `--last`
  ([#50](https://github.com/Iris-Ares/Spotion/pull/50)).
- Codex sessions are now searchable by their git branch (parsed from the rollout's
  `session_meta.payload.git.branch`); the scan cache advances to v7 so existing
  sessions are reparsed once ([#17](https://github.com/Iris-Ares/Spotion/pull/17)).

### Fixed

- Spotlight results no longer show a blank placeholder: each session now
  carries its agent's desktop-app icon (resolved at runtime, falling back to
  Spotion's own icon), kept fresh when handler apps are installed, removed, or
  updated ([#10](https://github.com/Iris-Ares/Spotion/pull/10)).

[Unreleased]: https://github.com/Iris-Ares/Spotion/commits/main
