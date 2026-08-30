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

## One command

Paste this entire line into PowerShell, or tell Codex to run it exactly with PowerShell:

```powershell
$u='https://raw.githubusercontent.com/JonAWDav/jonny-workstation-bootstrap/5ead9b442550e7fdcb1c87e6bb39ebc1b53d3b0f/bootstrap.ps1';$p='D:\Downloads\Jonny-Workstation-Bootstrap.ps1';if(-not(Test-Path -LiteralPath 'D:\')){throw 'This workstation requires a D drive.'};New-Item -ItemType Directory -Force -Path 'D:\Downloads'|Out-Null;Invoke-WebRequest -Uri $u -OutFile $p -UseBasicParsing;$a=[Security.Cryptography.SHA256]::Create();$s=[IO.File]::OpenRead($p);try{$h=[BitConverter]::ToString($a.ComputeHash($s)).Replace('-','')}finally{$s.Dispose();$a.Dispose()};if($h -ne '40E9AE061519DD370251941A469B5DE991721D3FF7C379DD425B7D46EED7C593'){throw 'Bootstrap SHA256 check failed.'};Start-Process powershell.exe -ArgumentList ('-NoExit -NoProfile -ExecutionPolicy Bypass -File "'+$p+'"')
```

The command opens a separate setup window so Codex can close safely when the restore reaches the local-history step. Rerun the same line if a download or login is interrupted.
