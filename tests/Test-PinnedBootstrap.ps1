[CmdletBinding()]
param(
    [string]$ExistingKitRoot = 'D:\Downloads\Jonny-Laptop-Continuity-2026-08-30'
)

$ErrorActionPreference = 'Stop'
$url = 'https://raw.githubusercontent.com/JonAWDav/jonny-workstation-bootstrap/6faafdabc3c2eac24095610ac7e066f2d5ab9a72/bootstrap.ps1'
$expectedHash = 'C481ABEB26550F3DA6EEEB1E2B4F5858E29CF7B346E5B255ABB1E3803656F91E'
$downloadPath = 'D:\Downloads\Jonny-Workstation-Bootstrap-pinned-test.ps1'

Invoke-WebRequest -Uri $url -OutFile $downloadPath -UseBasicParsing
$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadPath).Hash
if ($actualHash -ne $expectedHash) { throw 'Pinned bootstrap SHA256 check failed.' }

$arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $downloadPath + '" -UseExistingKitRoot "' + $ExistingKitRoot + '" -AuditOnly -NoLaunch'
$process = Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "Spawned bootstrap audit failed with exit code $($process.ExitCode)." }

[pscustomobject]@{
    Pass = $true
    Commit = '6faafdabc3c2eac24095610ac7e066f2d5ab9a72'
    SHA256 = $actualHash
    SpawnExitCode = $process.ExitCode
}
