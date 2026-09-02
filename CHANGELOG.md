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
- *Hide Session from Spotion* Spotlight action: drop one session from Spotlight,
  the menu bar, and suggestions without touching the Codex/Claude source; restore
  it from Settings → Index → Hidden sessions. Hide state lives in its own
  sidecar file (with a recovery copy) and fails closed if unreadable
  ([#26](https://github.com/Iris-Ares/Spotion/pull/26)).
- Settings → Index → *Spotlight history window* (All history / 7 / 30 / 90 days):
  keep only recently active sessions in Spotlight while every session stays in
  the scan cache and on disk; Settings shows the visible / total count
  ([#35](https://github.com/Iris-Ares/Spotion/pull/35)).
- Settings → Index → *Excluded projects*: keep every session under a chosen
  folder (and its descendants) out of Spotlight, the menu bar, and project
  suggestions without touching project files, transcripts, or macOS Spotlight
  Privacy; the rule list has a safety copy and fails closed if unreadable
  ([#27](https://github.com/Iris-Ares/Spotion/pull/27)).
- *Pin Spotion Session* / *Unpin Spotion Session* Spotlight actions: pinned
  sessions get a Pinned section in the menu bar, a higher Spotlight donation
  priority, and stay searchable regardless of the history window (hidden and
  excluded sessions still win). Pins live in their own sidecar file
  ([#22](https://github.com/Iris-Ares/Spotion/pull/22)).
- *Set Spotion Session Alias* / *Clear Spotion Session Alias* Spotlight actions:
  give any session a local display name (Spotlight title and menu bar) while the
  agent's own title stays searchable; aliases never touch transcripts and live
  in their own sidecar file ([#23](https://github.com/Iris-Ares/Spotion/pull/23)).
- Settings → Advanced → *Saved Quick Create projects*: an ordered list of folders
  (with a standard folder picker) that *New Codex/Claude Session* offers first,
  before recent-session projects — so a brand-new project is one keystroke away.
  Missing folders stay listed but are never suggested; excluded projects never
  appear ([#31](https://github.com/Iris-Ares/Spotion/pull/31)).
- Off-by-default *Search files touched* (Settings → Index): find a session by a
  file it read or edited. Only explicit paths from recognized Read/Write/Edit
  tool inputs inside the session's project are donated (newest 20, transient,
  never written to the scan cache); shell commands, patches, prose, and tool
  output are ignored. The scan cache advances to v8
  ([#38](https://github.com/Iris-Ares/Spotion/pull/38)).
- *Fork Agent Session* Spotlight action: branch a new interactive session off an
  indexed one (`codex fork <id>` / `claude --resume=<id> --fork-session`) in the
  configured terminal, leaving the source session untouched
  ([#49](https://github.com/Iris-Ares/Spotion/pull/49)).
- *Copy Session Resume Command* Spotlight action: put the exact `codex resume` /
  `claude --resume` command (POSIX-quoted, same construction as the launcher)
  on the clipboard without opening a terminal; nothing is written if the
  executable or required directory is missing. The binary resolver now also
  checks the process PATH before its login-shell fallback
  ([#30](https://github.com/Iris-Ares/Spotion/pull/30)).

### Fixed

- Spotlight results no longer show a blank placeholder: each session now
  carries its agent's desktop-app icon (resolved at runtime, falling back to
  Spotion's own icon), kept fresh when handler apps are installed, removed, or
  updated ([#10](https://github.com/Iris-Ares/Spotion/pull/10)).

[Unreleased]: https://github.com/Iris-Ares/Spotion/commits/main
