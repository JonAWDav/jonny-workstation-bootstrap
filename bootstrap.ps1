[CmdletBinding()]
param(
    [string]$WorkspaceRoot = 'D:\OneDrive\Desktop\Claude Code',
    [string]$ObsidianVaultPath,
    [string]$PayloadRepo = 'JonAWDav/jonny-workstation-payload',
    [string]$ReleaseTag = 'desktop-2026-08-30',
    [string]$UseExistingKitRoot,
    [switch]$AuditOnly,
    [switch]$SkipAccountLogins,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$builtInModulePath = Join-Path $PSHOME 'Modules'
$modulePaths = @($env:PSModulePath -split ';' | Where-Object { $_ })
if ($modulePaths -notcontains $builtInModulePath) {
    $env:PSModulePath = (@($builtInModulePath) + $modulePaths) -join ';'
}
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
Import-Module Microsoft.PowerShell.Security -ErrorAction Stop

$expectedArchiveHash = 'DB6595FDFEE31410A2BF043C2288F250CA714ACBAA7D04C37421F1912BD48220'
$expectedPartManifestHash = 'AC6D490B8F7EA4BE2884514B2EB1D21F7DDAE1CB916B979642AADB2FE71406EE'
$expectedFinalManifestHash = '6147E5EDF472DD49BF592D151FCDBCAC457CDE40CAC4CE48DCCB2331E92C2B00'
$notionHandoffUrl = 'https://app.notion.com/p/3cc2e43077b6818db743cb9631d9d74c?pvs=204'
$kitFolderName = 'Jonny-Laptop-Continuity-2026-08-30'
$archiveName = 'Jonny-Laptop-Continuity-2026-08-30-FINAL.tar.gz'

$criticalHashes = [ordered]@{
    '02-Install-On-Laptop.ps1' = '16032D1E8058B814AED6CA6D17B0526ED9E43D043405E75326483544B71EF609'
    '03-Verify-Laptop.ps1' = 'CA6E378D27A94FB276346DCE572E4AB66BA5CFA668A7BAF17288A4646862C2DF'
    'installers\node-v24.13.1-x64.msi' = '03FE815E236AD8FB6FA4289921A746E1492571ACEE49105154F2CC0B07021515'
    'installers\Git-2.53.0.3-64-bit.exe' = 'BC88381E192BD5B17A131755D837828D8A570DA1EAD89CFCDE0D45AE38133C0B'
    'installers\Jonny-HQ-Setup-2.0.0.exe' = '18AB5341A7893BAD5E4223E6967C3E527AED6A66E3DB7E743AD6DEFE3749F4B6'
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = @($machinePath,$userPath) -join ';'
}

function Assert-FileHash {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Expected
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    if ($actual -ne $Expected.ToUpperInvariant()) {
        throw "SHA256 check failed for $Path. Expected $Expected. Got $actual."
    }
}

function Assert-KitCriticalFiles {
    param([Parameter(Mandatory)][string]$KitRoot)
    foreach ($entry in $criticalHashes.GetEnumerator()) {
        Assert-FileHash -Path (Join-Path $KitRoot $entry.Key) -Expected $entry.Value
    }
    foreach ($required in @(
        'README.md',
        'payload\desktop-export\codex\config.toml',
        'payload\desktop-export\workspace\AGENTS.md',
        'payload\desktop-export\private-history\codex\thread_history_1.sqlite',
        'reports\SHA256SUMS.txt',
        'reports\jonny-hq-build.json'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $KitRoot $required))) {
            throw "Continuity kit is incomplete. Missing: $required"
        }
    }
}

function Get-GitHubCliPath {
    Refresh-ProcessPath
    $command = Get-Command gh -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    Write-Step 'Installing GitHub CLI'
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'Windows Package Manager is missing. Install App Installer from Microsoft Store, then rerun the same bootstrap command.'
    }
    & $winget.Source install --id GitHub.cli --exact --source winget --accept-package-agreements --accept-source-agreements --silent | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI installation failed with exit code $LASTEXITCODE."
    }
    Refresh-ProcessPath
    $command = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $command) {
        $fallback = 'C:\Program Files\GitHub CLI\gh.exe'
        if (Test-Path -LiteralPath $fallback) { return $fallback }
        throw 'GitHub CLI installed but gh.exe is not available. Open a new PowerShell window and rerun the same command.'
    }
    return $command.Source
}

function Confirm-GitHubAccess {
    param([Parameter(Mandatory)][string]$GhPath)
    & $GhPath auth status --hostname github.com *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Step 'Sign into GitHub in the browser window'
        & $GhPath auth login --hostname github.com --git-protocol https --web
        if ($LASTEXITCODE -ne 0) { throw 'GitHub login did not complete.' }
    }
    $login = [string](& $GhPath api user --jq '.login')
    if ($LASTEXITCODE -ne 0 -or $login.Trim() -ine 'JonAWDav') {
        throw "GitHub is signed in as '$($login.Trim())'. Sign in as JonAWDav, then rerun the same bootstrap command."
    }
    $visibility = [string](& $GhPath repo view $PayloadRepo --json visibility --jq '.visibility')
    if ($LASTEXITCODE -ne 0 -or $visibility.Trim() -ne 'PRIVATE') {
        throw "The private payload repository is unavailable or not private: $PayloadRepo"
    }
}

function Get-ReleaseAssets {
    param(
        [Parameter(Mandatory)][string]$GhPath,
        [Parameter(Mandatory)][string]$PartsDirectory
    )
    New-Item -ItemType Directory -Force -Path $PartsDirectory | Out-Null

    $assetJson = & $GhPath release view $ReleaseTag --repo $PayloadRepo --json assets
    if ($LASTEXITCODE -ne 0) { throw 'The private workstation release could not be read.' }
    $assetNames = @((ConvertFrom-Json $assetJson).assets | ForEach-Object { $_.name })
    $expectedNames = @('PARTS-SHA256.txt','FINAL-SHA256.txt') + (1..10 | ForEach-Object { '{0}.part{1:D3}' -f $archiveName,$_ })
    $missing = @($expectedNames | Where-Object { $_ -notin $assetNames })
    if ($missing) { throw "Private release is incomplete: $($missing -join ', ')" }

    Write-Step 'Downloading the private workstation context'
    & $GhPath release download $ReleaseTag --repo $PayloadRepo --dir $PartsDirectory --skip-existing --pattern '*.part*' --pattern 'PARTS-SHA256.txt' --pattern 'FINAL-SHA256.txt' | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Private release download failed. Rerun the same bootstrap command to resume.' }

    $partManifest = Join-Path $PartsDirectory 'PARTS-SHA256.txt'
    $finalManifest = Join-Path $PartsDirectory 'FINAL-SHA256.txt'
    Assert-FileHash -Path $partManifest -Expected $expectedPartManifestHash
    Assert-FileHash -Path $finalManifest -Expected $expectedFinalManifestHash

    $entries = foreach ($line in Get-Content -LiteralPath $partManifest) {
        if ($line -notmatch '^([A-Fa-f0-9]{64})  (.+)$') { throw "Invalid part manifest line: $line" }
        [pscustomobject]@{ Hash=$Matches[1].ToUpperInvariant(); Name=$Matches[2] }
    }
    if (@($entries).Count -ne 10) { throw "Expected 10 archive parts. Manifest has $(@($entries).Count)." }

    foreach ($entry in $entries) {
        $partPath = Join-Path $PartsDirectory $entry.Name
        $valid = (Test-Path -LiteralPath $partPath) -and ((Get-FileHash -Algorithm SHA256 -LiteralPath $partPath).Hash -eq $entry.Hash)
        if (-not $valid) {
            if (Test-Path -LiteralPath $partPath) { Remove-Item -LiteralPath $partPath -Force }
            Write-Host "Repairing $($entry.Name)..."
            & $GhPath release download $ReleaseTag --repo $PayloadRepo --dir $PartsDirectory --clobber --pattern $entry.Name | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Could not redownload $($entry.Name)." }
            Assert-FileHash -Path $partPath -Expected $entry.Hash
        }
    }
    return @($entries)
}

function Join-ArchiveParts {
    param(
        [Parameter(Mandatory)][array]$Entries,
        [Parameter(Mandatory)][string]$PartsDirectory,
        [Parameter(Mandatory)][string]$OutputPath
    )
    if (Test-Path -LiteralPath $OutputPath) {
        $existingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutputPath).Hash
        if ($existingHash -eq $expectedArchiveHash) { return }
        Remove-Item -LiteralPath $OutputPath -Force
    }

    Write-Step 'Reassembling and verifying the 4.59 GB context archive'
    $destination = [IO.File]::Open($OutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $buffer = [byte[]]::new(4MB)
    try {
        foreach ($entry in $Entries) {
            Write-Host "Adding $($entry.Name)..."
            $source = [IO.File]::OpenRead((Join-Path $PartsDirectory $entry.Name))
            try {
                while (($read = $source.Read($buffer,0,$buffer.Length)) -gt 0) {
                    $destination.Write($buffer,0,$read)
                }
            } finally {
                $source.Dispose()
            }
        }
    } finally {
        $destination.Dispose()
    }
    Assert-FileHash -Path $OutputPath -Expected $expectedArchiveHash
}

function Expand-VerifiedKit {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$WorkRoot
    )
    $extractRoot = Join-Path $WorkRoot 'extracted'
    $kitRoot = Join-Path $extractRoot $kitFolderName
    if (Test-Path -LiteralPath (Join-Path $kitRoot 'README.md')) {
        Assert-KitCriticalFiles -KitRoot $kitRoot
        return $kitRoot
    }
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    Write-Step 'Extracting the verified workstation kit'
    & tar -xzf $ArchivePath -C $extractRoot
    if ($LASTEXITCODE -ne 0) { throw 'Archive extraction failed.' }
    Assert-KitCriticalFiles -KitRoot $kitRoot
    return $kitRoot
}

function Wait-ForWorkspace {
    param([Parameter(Mandatory)][string]$Path)
    while (-not ((Test-Path -LiteralPath $Path) -and (Test-Path -LiteralPath (Join-Path $Path 'AGENTS.md')))) {
        Write-Step 'OneDrive owner action required'
        Write-Host "The complete project workspace must finish syncing to: $Path" -ForegroundColor Yellow
        Write-Host 'Sign into OneDrive and make that folder available on this device.'
        $oneDrive = @(
            (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'),
            (Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe')
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
        if ($oneDrive) { Start-Process -FilePath $oneDrive | Out-Null }
        $answer = Read-Host 'Press Enter after OneDrive has created the exact folder, or type Q to stop safely'
        if ($answer -match '^[Qq]$') { throw 'Stopped before installation because the OneDrive workspace is not ready.' }
    }
}

function Get-ObsidianVaultCandidates {
    $results = [System.Collections.Generic.List[string]]::new()
    $configPath = Join-Path $env:APPDATA 'obsidian\obsidian.json'
    if (Test-Path -LiteralPath $configPath) {
        try {
            $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            if ($config.vaults) {
                foreach ($property in $config.vaults.PSObject.Properties) {
                    $candidate = [string]$property.Value.path
                    if ($candidate -and (Test-Path -LiteralPath $candidate)) { $results.Add($candidate) }
                }
            }
        } catch {
            Write-Warning 'Obsidian vault registry could not be parsed. A path can still be entered manually.'
        }
    }
    return @($results | Sort-Object -Unique)
}

function Resolve-ObsidianVault {
    param([string]$RequestedPath)
    $candidate = $RequestedPath
    if (-not $candidate) {
        $valid = @(Get-ObsidianVaultCandidates | Where-Object {
            (Test-Path -LiteralPath (Join-Path $_ 'Memory\NOW.md')) -and
            (Test-Path -LiteralPath (Join-Path $_ 'Memory\MASTER.md')) -and
            (Test-Path -LiteralPath (Join-Path $_ 'Memory\INDEX.md')) -and
            (Test-Path -LiteralPath (Join-Path $_ 'Memory\PROCEDURES.md'))
        })
        if ($valid.Count -eq 1) {
            $candidate = $valid[0]
        } elseif ($valid.Count -gt 1) {
            Write-Host 'Obsidian vault candidates:'
            for ($i=0; $i -lt $valid.Count; $i++) { Write-Host "[$($i+1)] $($valid[$i])" }
            $selection = [int](Read-Host 'Enter the number for the active synced vault')
            if ($selection -lt 1 -or $selection -gt $valid.Count) { throw 'Invalid Obsidian vault selection.' }
            $candidate = $valid[$selection-1]
        } else {
            $candidate = Read-Host 'Paste the exact local path of the active Obsidian Sync vault'
        }
    }
    if (-not (Test-Path -LiteralPath $candidate)) { throw "Obsidian vault does not exist: $candidate" }
    $resolved = (Resolve-Path -LiteralPath $candidate).Path.TrimEnd('\')
    if ($resolved -match '(?i)[\\/]OneDrive([\\/]|$)') {
        throw "The active Obsidian Sync vault is inside OneDrive: $resolved. Move or reconnect it outside OneDrive before rerunning."
    }
    foreach ($note in @('Memory\NOW.md','Memory\MASTER.md','Memory\INDEX.md','Memory\PROCEDURES.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $resolved $note))) { throw "Obsidian is missing $note at $resolved" }
    }
    $fileCount = @(Get-ChildItem -LiteralPath $resolved -Recurse -Force -File -ErrorAction SilentlyContinue).Count
    if ($fileCount -lt 4800) { throw "Obsidian vault looks incomplete: $fileCount files. Expected at least 4800." }
    return $resolved
}

function Wait-ForAgentAppsToClose {
    while ($true) {
        $blocking = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -in @('codex','codex-app-server','claude','Jonny HQ')
        })
        if (-not $blocking) { return }
        Write-Step 'Close Codex, Claude Code and Jonny HQ'
        Write-Host 'This setup window will stay open and continue automatically.' -ForegroundColor Yellow
        $blocking | Select-Object ProcessName,Id | Format-Table -AutoSize
        Read-Host 'Press Enter after those apps are closed' | Out-Null
    }
}

function Backup-AgentState {
    param([Parameter(Mandatory)][string]$BackupRoot)
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
    foreach ($name in @('.codex','.claude','.agents')) {
        $source = Join-Path ([Environment]::GetFolderPath('UserProfile')) $name
        if (-not (Test-Path -LiteralPath $source)) { continue }
        $destination = Join-Path $BackupRoot $name
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        & robocopy $source $destination /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /NFL /NDL /NP | Out-Null
        if ($LASTEXITCODE -gt 7) { throw "Backup failed for $source with robocopy exit code $LASTEXITCODE." }
    }
}

function Install-PinnedPrerequisites {
    param([Parameter(Mandatory)][string]$KitRoot)
    Refresh-ProcessPath
    $nodeVersion = if (Get-Command node -ErrorAction SilentlyContinue) { [string](& node --version 2>$null) } else { '' }
    $npmVersion = if (Get-Command npm -ErrorAction SilentlyContinue) { [string](& npm --version 2>$null) } else { '' }
    if ($nodeVersion -notmatch '^v24\.13\.1$' -or $npmVersion -notmatch '^11\.8\.0$') {
        Write-Step 'Installing pinned Node.js and npm'
        $nodeInstaller = Join-Path $KitRoot 'installers\node-v24.13.1-x64.msi'
        Assert-FileHash -Path $nodeInstaller -Expected $criticalHashes['installers\node-v24.13.1-x64.msi']
        if ((Get-AuthenticodeSignature -LiteralPath $nodeInstaller).Status -ne 'Valid') { throw 'Node.js installer signature is not valid.' }
        $process = Start-Process msiexec.exe -Verb RunAs -Wait -PassThru -ArgumentList @('/i',"`"$nodeInstaller`"",'/qn','/norestart')
        if ($process.ExitCode -notin @(0,3010)) { throw "Node.js installer failed with exit code $($process.ExitCode)." }
    }
    Refresh-ProcessPath
    $gitVersion = if (Get-Command git -ErrorAction SilentlyContinue) { [string](& git --version 2>$null) } else { '' }
    if ($gitVersion -notmatch '2\.53\.0\.windows\.3') {
        Write-Step 'Installing pinned Git for Windows'
        $gitInstaller = Join-Path $KitRoot 'installers\Git-2.53.0.3-64-bit.exe'
        Assert-FileHash -Path $gitInstaller -Expected $criticalHashes['installers\Git-2.53.0.3-64-bit.exe']
        if ((Get-AuthenticodeSignature -LiteralPath $gitInstaller).Status -ne 'Valid') { throw 'Git installer signature is not valid.' }
        $process = Start-Process $gitInstaller -Verb RunAs -Wait -PassThru -ArgumentList @('/VERYSILENT','/NORESTART','/NOCANCEL','/SP-')
        if ($process.ExitCode -ne 0) { throw "Git installer failed with exit code $($process.ExitCode)." }
    }
    Refresh-ProcessPath
}

function Update-LaptopPaths {
    $home = [Environment]::GetFolderPath('UserProfile')
    $configPath = Join-Path $home '.codex\config.toml'
    if (-not (Test-Path -LiteralPath $configPath)) { return }
    $text = Get-Content -LiteralPath $configPath -Raw
    $text = [regex]::Replace($text,'(?ms)^\[mcp_servers\.node_repl\.env\]\r?\n.*?(?=^\[|\z)','')
    $text = [regex]::Replace($text,'(?ms)^\[marketplaces\.openai-bundled\]\r?\n.*?(?=^\[|\z)','')
    $text = [regex]::Replace($text,'(?ms)^\[marketplaces\.openai-primary-runtime\]\r?\n.*?(?=^\[|\z)','')
    if ($home -ine 'C:\Users\Jonny') {
        $escapedHome = $home.Replace('\','\\')
        $text = $text.Replace('C:\Users\Jonny',$home).Replace('C:\\Users\\Jonny',$escapedHome).Replace('C:/Users/Jonny',($home -replace '\\','/'))
    }
    [IO.File]::WriteAllText($configPath,$text,[Text.UTF8Encoding]::new($false))
}

function Restore-NewLaptopSessions {
    param([Parameter(Mandatory)][string]$BackupRoot)
    $source = Join-Path $BackupRoot '.codex\sessions'
    $destination = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\sessions'
    if (Test-Path -LiteralPath $source) {
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        & robocopy $source $destination /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /NFL /NDL /NP | Out-Null
        if ($LASTEXITCODE -gt 7) { throw 'Could not merge the laptop Codex sessions back after restore.' }
    }
}

function Install-JonnyHQ {
    param([Parameter(Mandatory)][string]$KitRoot)
    $installer = Join-Path $KitRoot 'installers\Jonny-HQ-Setup-2.0.0.exe'
    Assert-FileHash -Path $installer -Expected $criticalHashes['installers\Jonny-HQ-Setup-2.0.0.exe']
    Write-Step 'Installing Jonny HQ'
    $process = Start-Process $installer -Wait -PassThru -ArgumentList '/S'
    if ($process.ExitCode -ne 0) { throw "Jonny HQ installer failed with exit code $($process.ExitCode)." }
    $installed = Join-Path $env:LOCALAPPDATA 'Programs\Jonny HQ\Jonny HQ.exe'
    if (-not (Test-Path -LiteralPath $installed)) { throw 'Jonny HQ did not appear in the expected per-user install path.' }
    Assert-FileHash -Path $installed -Expected 'CD3AC5EF39F4267377142726094DC474C8384F50E0721138EE593E4F089C34BC'
    return $installed
}

function Ensure-OwnerLogins {
    Refresh-ProcessPath
    & codex login status *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Step 'Sign into Codex'
        & codex login
        if ($LASTEXITCODE -ne 0) { throw 'Codex login did not complete.' }
    }
    & claude auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Step 'Sign into Claude Code'
        & claude auth login
        if ($LASTEXITCODE -ne 0) { throw 'Claude Code login did not complete.' }
    }
    & vercel whoami *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Step 'Sign into Vercel'
        & vercel login
        if ($LASTEXITCODE -ne 0) { throw 'Vercel login did not complete.' }
    }

    $stanley = [Environment]::GetEnvironmentVariable('STANLEY_MCP_TOKEN','User')
    if ([string]::IsNullOrWhiteSpace($stanley)) {
        Write-Step 'Optional secure Stanley token entry'
        Write-Host 'Paste the Stanley token now, or press Enter to leave it as the only pending connector.'
        $secure = Read-Host -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
            if (-not [string]::IsNullOrWhiteSpace($plain)) {
                [Environment]::SetEnvironmentVariable('STANLEY_MCP_TOKEN',$plain,'User')
                $env:STANLEY_MCP_TOKEN = $plain
            }
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
}

function Write-VerificationHandoff {
    param(
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string]$KitRoot,
        [Parameter(Mandatory)][string]$VaultPath
    )
    $promptPath = Join-Path $WorkRoot 'VERIFY-IN-CODEX.md'
    $content = @"
# Finish Jonny laptop verification

This workstation was restored from the private release `$PayloadRepo`, tag `$ReleaseTag`.

Work read-only until all checks are complete. Do not send messages, write CRM data, deploy, or enable scheduled tasks.

1. Read `$WorkspaceRoot\AGENTS.md`.
2. Read `$VaultPath\Memory\NOW.md`, `MASTER.md`, `INDEX.md`, and `PROCEDURES.md`.
3. Fetch the private Notion handoff page with the connected Notion app: $notionHandoffUrl
4. Confirm that the page title is `How to move Jonny's AI workstation to the laptop - 30 August 2026`.
5. Run `codex doctor --json` and inspect all non-terminal failures.
6. Run `$KitRoot\03-Verify-Laptop.ps1 -ObsidianVaultPath '$VaultPath'`.
7. Run one harmless Claude Code read-only test from `$WorkspaceRoot`. It must read AGENTS.md and return the workspace title without changing files.
8. Confirm Jonny HQ opens and both Codex and Claude terminals start.
9. Confirm all listed desktop automation tasks remain absent or disabled.
10. Give Jonny one pass or fail table. Fix safe local failures. Ask only for an owner login or secret when it is genuinely required.

Do not claim complete until the Notion fetch, Obsidian spine read, Codex health check, Claude check, and Jonny HQ check all pass.
"@
    [IO.File]::WriteAllText($promptPath,$content,[Text.UTF8Encoding]::new($false))
    return $promptPath
}

if (-not (Test-Path -LiteralPath 'D:\')) {
    throw 'The laptop has no D drive. This workstation requires D:\OneDrive\Desktop\Claude Code. Add or map the D drive, then rerun the same command.'
}

$workRoot = 'D:\Downloads\Jonny-Workstation-Bootstrap'
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
$logPath = Join-Path $workRoot ('bootstrap-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -LiteralPath $logPath -Force | Out-Null } catch { }

try {
    Write-Step 'Jonny workstation bootstrap started'
    Write-Host "Log: $logPath"
    Write-Host 'The process is resumable. If internet or login is interrupted, run the same command again.'

    if ($UseExistingKitRoot) {
        $kitRoot = (Resolve-Path -LiteralPath $UseExistingKitRoot).Path
        Assert-KitCriticalFiles -KitRoot $kitRoot
    } else {
        $ghPath = Get-GitHubCliPath
        Confirm-GitHubAccess -GhPath $ghPath
        $partsDirectory = Join-Path $workRoot 'parts'
        $entries = Get-ReleaseAssets -GhPath $ghPath -PartsDirectory $partsDirectory
        $archivePath = Join-Path $workRoot $archiveName
        Join-ArchiveParts -Entries $entries -PartsDirectory $partsDirectory -OutputPath $archivePath
        $kitRoot = Expand-VerifiedKit -ArchivePath $archivePath -WorkRoot $workRoot
    }

    Write-Host "Verified kit: $kitRoot" -ForegroundColor Green
    if ($AuditOnly) {
        Write-Host 'AUDIT PASSED. Bootstrap, payload and critical hashes are valid.' -ForegroundColor Green
        return
    }

    Wait-ForWorkspace -Path $WorkspaceRoot
    $vaultPath = Resolve-ObsidianVault -RequestedPath $ObsidianVaultPath
    Write-Step 'Confirm Obsidian Sync'
    Write-Host "Detected vault: $vaultPath"
    $syncAnswer = Read-Host 'Open Obsidian. When Sync shows green and fully synced, type GREEN'
    if ($syncAnswer -cne 'GREEN') { throw 'Stopped before installation because Obsidian green sync was not confirmed.' }

    Wait-ForAgentAppsToClose
    $backupRoot = Join-Path $workRoot ('backups\preinstall-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-Step 'Backing up the laptop agent state before restore'
    Backup-AgentState -BackupRoot $backupRoot
    Install-PinnedPrerequisites -KitRoot $kitRoot

    Write-Step 'Restoring Codex, Claude Code, skills, memories and private history'
    & (Join-Path $kitRoot '02-Install-On-Laptop.ps1') -WorkspaceRoot $WorkspaceRoot -ObsidianVaultPath $vaultPath -InstallPrivateHistory -SkipJonnyHQ
    if ($LASTEXITCODE -ne 0) { throw 'The context installer did not complete.' }
    Restore-NewLaptopSessions -BackupRoot $backupRoot
    Update-LaptopPaths
    Refresh-ProcessPath
    if (Get-Command codex -ErrorAction SilentlyContinue) {
        & codex migrate-rollouts --apply *> (Join-Path $workRoot 'codex-migrate-rollouts.log')
    }

    $jonnyHqPath = Install-JonnyHQ -KitRoot $kitRoot
    if (-not $SkipAccountLogins) { Ensure-OwnerLogins }

    Write-Step 'Hydrating Codex plugins and running verification'
    Refresh-ProcessPath
    & codex plugin marketplace upgrade *> (Join-Path $workRoot 'codex-plugin-upgrade.log')
    & codex plugin list *> (Join-Path $workRoot 'codex-plugin-list.log')
    & codex doctor --json *> (Join-Path $workRoot 'codex-doctor.json')
    & (Join-Path $kitRoot '03-Verify-Laptop.ps1') -ObsidianVaultPath $vaultPath *>&1 | Tee-Object -FilePath (Join-Path $workRoot 'laptop-verification.txt')
    $verificationExit = $LASTEXITCODE

    $promptPath = Write-VerificationHandoff -WorkRoot $workRoot -KitRoot $kitRoot -VaultPath $vaultPath
    $launcherPath = Join-Path $workRoot 'Start-Codex-Verification.ps1'
    $launcher = @"
Set-Location -LiteralPath '$($WorkspaceRoot.Replace("'","''"))'
codex "Read '$($promptPath.Replace("'","''"))' and complete every verification step."
"@
    [IO.File]::WriteAllText($launcherPath,$launcher,[Text.UTF8Encoding]::new($false))

    Write-Step 'Bootstrap installation finished'
    Write-Host "Verification report: $(Join-Path $workRoot 'laptop-verification.txt')"
    if ($verificationExit -eq 0) {
        Write-Host 'All deterministic checks passed.' -ForegroundColor Green
    } else {
        Write-Host 'One or more owner-login or live-app checks remain. Codex will finish them next.' -ForegroundColor Yellow
    }

    if (-not $NoLaunch) {
        Start-Process -FilePath $jonnyHqPath | Out-Null
        Start-Process powershell.exe -ArgumentList @('-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$launcherPath`"") | Out-Null
        Write-Host 'Jonny HQ and the final Codex verification session are opening now.' -ForegroundColor Green
    }
} finally {
    try { Stop-Transcript | Out-Null } catch { }
}
