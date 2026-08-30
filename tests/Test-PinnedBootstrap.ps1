[CmdletBinding()]
param(
    [string]$ExistingKitRoot = 'D:\Downloads\Jonny-Laptop-Continuity-2026-08-30',
    [string]$BootstrapPath
)

$ErrorActionPreference = 'Stop'
$url = 'https://raw.githubusercontent.com/JonAWDav/jonny-workstation-bootstrap/2ecbc6d5a20adbbd9bda6be37a5a9b34fdb0ff3a/bootstrap.ps1'
$expectedHash = '404AD13735F8ACAD63C8FAB69581BDA30B9AD25DDD4E45DA3D86EAB4B18472C6'
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
    Commit = '2ecbc6d5a20adbbd9bda6be37a5a9b34fdb0ff3a'
    SHA256 = $actualHash
    SpawnExitCode = $process.ExitCode
}
