# Security Policy

## Supported versions

Spotion has no stable release yet; security fixes land on `main`. Once GitHub Releases are published ([#5](https://github.com/Iris-Ares/Spotion/issues/5)), the latest release will be the supported version.

## Reporting a vulnerability

Please **do not** report security vulnerabilities through public GitHub issues.

Instead, use [GitHub's private vulnerability reporting](https://github.com/Iris-Ares/Spotion/security/advisories/new): *Security → Report a vulnerability* on the repository. You'll get an acknowledgment within a few days; this is a spare-time project, so please allow up to 14 days for an initial assessment. Coordinated disclosure is appreciated — give us a reasonable window to ship a fix before publishing details.

## Scope notes

Things that are useful to know when assessing Spotion:

- Spotion reads local files under `~/.codex` and `~/.claude` and donates session titles, first-prompt snippets, and working-directory paths to the **local** CoreSpotlight index. Nothing is sent off-device; Spotion makes no network requests.
- Session **content** beyond the indexed metadata is never parsed or stored.
- Resuming a session executes the `codex` / `claude` CLI in a terminal with shell-quoted arguments (`Spotion/Launch/ShellQuoting.swift`). Quoting bugs that could smuggle shell metacharacters through session IDs, paths, or prompts are in scope and taken seriously.
- Desktop-app launches hand a `codex://` / `claude://` URL to whatever app is registered for the scheme; session IDs are validated as canonical UUIDs before being embedded.
