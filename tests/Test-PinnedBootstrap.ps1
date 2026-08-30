[CmdletBinding()]
param(
    [string]$ExistingKitRoot = 'D:\Downloads\Jonny-Laptop-Continuity-2026-08-30',
    [string]$BootstrapPath
)

$ErrorActionPreference = 'Stop'
$url = 'https://raw.githubusercontent.com/JonAWDav/jonny-workstation-bootstrap/5ead9b442550e7fdcb1c87e6bb39ebc1b53d3b0f/bootstrap.ps1'
$expectedHash = '40E9AE061519DD370251941A469B5DE991721D3FF7C379DD425B7D46EED7C593'
$downloadPath = 'D:\Downloads\Jonny-Workstation-Bootstrap-pinned-test.ps1'

if ($BootstrapPath) {
    $downloadPath = (Resolve-Path -LiteralPath $BootstrapPath).Path
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadPath).Hash
} else {
    Invoke-WebRequest -Uri $url -OutFile $downloadPath -UseBasicParsing
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadPath).Hash
    if ($actualHash -ne $expectedHash) { throw 'Pinned bootstrap SHA256 check failed.' }
}

$arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $downloadPath + '" -UseExistingKitRoot "' + $ExistingKitRoot + '" -AuditOnly -NoLaunch'
$stdoutPath = 'D:\Downloads\Jonny-Workstation-Bootstrap-pinned-test.stdout.txt'
$stderrPath = 'D:\Downloads\Jonny-Workstation-Bootstrap-pinned-test.stderr.txt'
$process = Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
if ($process.ExitCode -ne 0) {
    $errorText = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { 'No stderr was captured.' }
    throw "Spawned bootstrap audit failed with exit code $($process.ExitCode). $errorText"
}

[pscustomobject]@{
    Pass = $true
    Commit = '5ead9b442550e7fdcb1c87e6bb39ebc1b53d3b0f'
    SHA256 = $actualHash
    SpawnExitCode = $process.ExitCode
}
