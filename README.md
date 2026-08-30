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
$u='https://raw.githubusercontent.com/JonAWDav/jonny-workstation-bootstrap/2ecbc6d5a20adbbd9bda6be37a5a9b34fdb0ff3a/bootstrap.ps1';$p='D:\Downloads\Jonny-Workstation-Bootstrap.ps1';if(-not(Test-Path -LiteralPath 'D:\')){throw 'This workstation requires a D drive.'};New-Item -ItemType Directory -Force -Path 'D:\Downloads'|Out-Null;Invoke-WebRequest -Uri $u -OutFile $p -UseBasicParsing;$env:PSModulePath=(Join-Path $PSHOME 'Modules')+';'+$env:PSModulePath;Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop;if((Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash -ne '404AD13735F8ACAD63C8FAB69581BDA30B9AD25DDD4E45DA3D86EAB4B18472C6'){throw 'Bootstrap SHA256 check failed.'};Start-Process powershell.exe -ArgumentList ('-NoExit -NoProfile -ExecutionPolicy Bypass -File "'+$p+'"')
```

The command opens a separate setup window so Codex can close safely when the restore reaches the local-history step. Rerun the same line if a download or login is interrupted.
