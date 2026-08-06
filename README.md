# Spotion

Codex CLI / Claude Code sessions, right inside native macOS Spotlight (`⌘ + Space`):

- **Search & Open** — search past sessions by title, project name, or directory; press Enter to resume the session in a terminal with the correct working directory, or hand it off to the agent's desktop app (Claude / ChatGPT-Codex) via `claude://resume` / `codex://threads` deep links. Pick the target per agent in Settings → General → 打开方式 (CLI remains the default for both).
  Claude desktop semantics: `claude://resume` *imports* the CLI transcript into a desktop-managed session with the app's own (initially generic) title — the sidebar shows it next to the original CLI entry, same content. The import also rewrites the local transcript in place (thinking blocks and title records stripped) — Spotion carries the previously indexed title forward when that happens, so the Spotlight row keeps its name. Both are Claude.app behaviors, outside Spotion's control. Codex opens the thread in place with no such side effects.
- **Quick Create** — run the "New Codex Session" / "New Claude Session" actions inside Spotlight, type the prompt inline, and press Enter to launch a new session in a terminal (macOS 26 Spotlight Actions).
- **Always fresh** — a menu-bar app watches `~/.codex` and `~/.claude` for session changes and keeps the Spotlight index in sync.

No Raycast / Alfred required — the entry point is 100% native.

## Install

1. Download `Spotion-X.Y.Z.zip` from the [latest release](https://github.com/Iris-Ares/Spotion/releases/latest), unzip it.
2. **Drag `Spotion.app` into `/Applications` before the first launch.** (Launching from the
   Downloads folder triggers App Translocation, which also breaks in-app updating.)
3. First launch is blocked by Gatekeeper — builds are not yet Developer-ID signed or
   notarized (no paid Apple Developer membership). Open **System Settings → Privacy &
   Security**, scroll to the *"Spotion.app" was blocked* notice, click **Open Anyway** and
   confirm. On macOS 26 the old right-click → Open shortcut no longer bypasses this.
   Terminal alternative:

   ```bash
   xattr -d com.apple.quarantine /Applications/Spotion.app
   ```

4. Cautious? Each release ships a `SHA256SUMS.txt` — verify with
   `shasum -a 256 -c SHA256SUMS.txt` next to the downloaded ZIP.

This friction is **first install only**: in-app updates installed by Sparkle are not
quarantined and won't re-trigger Gatekeeper. One known limitation of ad-hoc signing: macOS
may re-ask for the Terminal automation permission after an update, because it can't link
the new build to the previous grant.

## Updates

Spotion checks GitHub Releases for updates once a day (toggle in Settings → General →
软件更新) without interrupting you — a new version shows up as a row in the menu-bar
dropdown with a one-click install (download / verify / relaunch handled by
[Sparkle](https://sparkle-project.org), updates EdDSA-signed). Manual check: menu bar →
*Check for Updates…*. Release process and rollback: [docs/RELEASING.md](docs/RELEASING.md).

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 26+ (build commands pin `DEVELOPER_DIR`, no `xcode-select` switch required)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`; the `.xcodeproj` is generated from `project.yml` and not checked in)

## Build & install

```bash
make build      # Debug build
make test       # unit tests
make install    # Release build, install to /Applications, then launch
```

**Always verify Spotlight behavior against the `/Applications/Spotion.app` copy** — duplicate
copies in DerivedData confuse LaunchServices / App Intents registration. Run
`make reset-registration` if registration misbehaves.

## Troubleshooting

- Sessions don't appear in Spotlight: first run the self-check in the app's Settings → Index
  (a CSUserQuery straight against the index). Hits > 0 mean our index is fine and the problem
  is on the Spotlight UI side — check the Spotion toggle in System Settings → Spotlight, or give
  the system indexer a moment; 0 hits mean the donation never landed — press Reindex.
- Session data sources: `~/.codex/sessions/**/rollout-*.jsonl` (titles in
  `~/.codex/session_index.jsonl`) and `~/.claude/projects/<escaped-cwd>/<uuid>.jsonl`.
  Reads are bounded (head/tail windows) — large files are never read whole.
