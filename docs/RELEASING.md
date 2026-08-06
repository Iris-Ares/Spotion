# Releasing Spotion

## Versioning

- SemVer. The git tag `vX.Y.Z` is the single source of truth for the shipped
  version: the release workflow stamps both `CFBundleShortVersionString` and
  `CFBundleVersion` from it (`xcodebuild MARKETING_VERSION=… CURRENT_PROJECT_VERSION=…`).
- `project.yml` carries a dev fallback (`0.1.0`) so local builds produce a
  valid bundle; dev copies are not update targets.
- No pre-release suffixes (`v0.3.0-beta.1`): Sparkle's version comparator
  ordering for suffixes is unvalidated here, and the workflow's tag regex
  rejects them on purpose.

## Cutting a release

1. `main` is green in CI.
2. ```bash
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```
3. The [Release workflow](../.github/workflows/release.yml) runs tests, builds
   Release with the stamped version, packages `Spotion-X.Y.Z.zip`, generates an
   EdDSA-signed `appcast.xml`, writes `SHA256SUMS.txt`, and publishes a GitHub
   Release (created as draft, published atomically once assets are up).
4. Post-publish checks:
   - `curl -sIL https://github.com/Iris-Ares/Spotion/releases/latest/download/appcast.xml`
     ends in HTTP 200 at this release's asset.
   - Download the ZIP next to `SHA256SUMS.txt` and `shasum -a 256 -c SHA256SUMS.txt`.
   - Editing the auto-generated release notes afterwards is safe — the in-app
     link points at the release page; notes are not baked into the appcast.

## Rollback / recovery

- **Bad release**: `gh release edit vX.Y.Z --prerelease` (or delete the
  release). `releases/latest/download/appcast.xml` immediately serves the
  previous release's feed again — nothing else to do.
- That only protects users who have **not** updated yet. **Sparkle never
  downgrades**; recovery for users already on the bad version is shipping a
  fixed `vX.Y.(Z+1)`.
- Tags are immutable (enforced by the `protect-release-tags` ruleset): never
  move or reuse one. Deleting a release does not delete its tag — by design.
- Workflow died mid-release: delete the leftover draft release if any, fix the
  problem, and re-run the job from the Actions UI (same tag) or push the next
  patch tag.

## EdDSA update-signing keys

- **Private key** lives in exactly two places: the release engineer's login
  Keychain (Sparkle item, account `spotion`) and the `SPARKLE_PRIVATE_KEY`
  GitHub Actions secret. **Public key** is `SUPublicEDKey` in
  `Spotion/Info.plist`.
- Local tooling (Sparkle 2.9.5 `bin/`): `generate_keys --account spotion -p`
  prints the public key; `generate_appcast --account spotion …` signs from the
  Keychain (used for local update-flow testing).
- **Rotation**: generate a new pair → ship one intermediate release *signed
  with the old key* whose Info.plist carries the *new* public key → replace
  the `SPARKLE_PRIVATE_KEY` secret → subsequent releases sign with the new
  key.
- **Compromise**: rotate immediately and accept that users on
  old-public-key builds must reinstall manually from GitHub; announce in
  release notes and the README.

## Adding Developer ID signing + notarization (once a membership exists)

1. Add secrets: `DEVID_CERT_P12_BASE64`, `DEVID_CERT_PASSWORD`,
   `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` (app-specific
   password — or an App Store Connect API key trio instead).
2. `project.yml`: `CODE_SIGN_IDENTITY: "Developer ID Application"`,
   `DEVELOPMENT_TEAM: <team id>`, `ENABLE_HARDENED_RUNTIME: "YES"`,
   `CODE_SIGN_ENTITLEMENTS: Spotion/Spotion.entitlements`.
3. New `Spotion/Spotion.entitlements` containing
   `com.apple.security.automation.apple-events` = `true` — without it the
   hardened runtime blocks `TerminalLauncher`'s AppleScript into Terminal.app.
4. `release.yml`: activate the commented insertion point — import the cert
   into a temporary keychain, build signed, `xcrun notarytool submit --wait`,
   then `xcrun stapler staple` the `.app` **before** the `ditto` ZIP step.
5. Keep EdDSA signing regardless — Sparkle best practice even for notarized
   apps.
6. Shrink the README install section (the Gatekeeper friction disappears).

## Repo protection

- [.github/rulesets/protect-main.json](../.github/rulesets/protect-main.json):
  changes to `main` require a PR with a green `build-test` check; force pushes
  and deletion blocked; 0 required approvals (solo maintainer — GitHub forbids
  self-approval).
- [.github/rulesets/protect-release-tags.json](../.github/rulesets/protect-release-tags.json):
  `v*` tags cannot be moved or deleted once pushed.
- Apply / re-apply either with:
  ```bash
  gh api -X POST repos/Iris-Ares/Spotion/rulesets --input .github/rulesets/protect-main.json
  ```
  (Editing rules in the GitHub UI works too — keep these files in sync; they
  are the reproducible source of truth.)
- Interplay with rollback: rollback happens at the *release* level
  (prerelease/delete); the tag itself stays, which is exactly what the tag
  ruleset enforces.

## Troubleshooting

- **Runner Xcode drift** — the `macos-26` image's default Xcode moves over
  time. If a build breaks on the runner but not locally, pin the job:
  `env: { DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer }`.
- **Upgrading Sparkle** — bump three pins together: `exactVersion` in
  `project.yml`, and `SPARKLE_VERSION` + `SPARKLE_SHA256` in
  `release.yml` (`shasum -a 256` the freshly downloaded tar.xz).
- **Local end-to-end update test** — Debug builds honor
  `defaults write com.ares.spotion feedURLOverride <url>` (see
  `UpdateManager.swift`). Build a higher-versioned ZIP
  (`make dist VERSION=9.9.9`), run `generate_appcast --account spotion
  --download-url-prefix http://localhost:8000/ -o dist/appcast.xml dist`,
  serve with `python3 -m http.server 8000 -d dist`, and relaunch the Debug
  app. Note: App Transport Security may block plain-HTTP localhost feeds; if
  the check errors immediately, test against a real HTTPS release asset URL
  instead.
- **"The update is improperly signed"** in the wild — the appcast/ZIP pair on
  that release is inconsistent. Re-sign (`sign_update`) and replace the
  release's `appcast.xml`, or cut a new patch release.
