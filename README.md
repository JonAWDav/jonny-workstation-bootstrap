# Jonny workstation bootstrap

This public repository contains only the safe bootstrap entrypoint. It has no private conversation history, credentials, tokens, or project data.

The script authenticates Jonny through GitHub CLI, downloads the private workstation release, verifies all SHA256 hashes, restores the local Codex and Claude Code context, installs Jonny HQ, and runs the laptop verifier.

The private payload remains in `JonAWDav/jonny-workstation-payload` and requires the `JonAWDav` GitHub account.

## Safety

- Credentials are never included in the release.
- The script asks for fresh owner logins.
- Obsidian must be fully synced and outside OneDrive.
- The project workspace must be available at `D:\OneDrive\Desktop\Claude Code`.
- Desktop scheduled tasks stay disabled on the laptop.
- The same command can be rerun after an interrupted download.

The final pinned one-line command is added after the first immutable release commit is published.
