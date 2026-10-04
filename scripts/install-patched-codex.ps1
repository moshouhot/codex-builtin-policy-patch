<#
.SYNOPSIS
  Install or roll back the locally-patched Codex CLI (built-in dangerous-command
  policy disabled) for Codex Desktop / Codex CLI on Windows.

.DESCRIPTION
  Codex resolves its CLI binary through the CODEX_CLI_PATH environment variable.
  When that path points OUTSIDE `\Program Files\WindowsApps\`, the launcher uses
  it verbatim (source = "env-override") and does NOT verify or overwrite it.

  This script points CODEX_CLI_PATH at a locally built codex.exe and keeps the
  Store package untouched, so the change survives Store upgrades and is fully
  reversible with -Rollback.

  The shipped binary directory is versioned by the Codex CLI version it replaces
  (e.g. ...\CodexLocalPatch\bin\0.160.0\codex.exe).

.PARAMETER Source
  Path to the patched codex.exe to install. Defaults to the build output.

.PARAMETER Version
  Version label for the destination directory. Defaults to 0.160.0.

.PARAMETER Rollback
  Remove CODEX_CLI_PATH and restore the original bundled CLI.

.PARAMETER Verify
  Probe the installed binary and report whether the patch is active.
#>
[CmdletBinding()]
param(
    [string]$Source = (Join-Path $env:BUILD_ROOT 'target\release\codex.exe'),
    [string]$Version = '0.160.0',
    [switch]$Rollback,
    [switch]$Verify
)

# Allow a per-user build root without editing this script.
if (-not $env:BUILD_ROOT) { $env:BUILD_ROOT = 'E:\codex-build' }
if ($PSBoundParameters.ContainsKey('Source')) {
    $Source = $PSBoundParameters['Source']
} else {
    $Source = Join-Path $env:BUILD_ROOT 'target\release\codex.exe'
}

$ErrorActionPreference = 'Stop'
$Root = Join-Path $env:LOCALAPPDATA 'CodexLocalPatch'
$BinDir = Join-Path $Root "bin\$Version"
$Target = Join-Path $BinDir 'codex.exe'

function Get-BundledCli {
    $pkg = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
    if (-not $pkg) { return $null }
    $candidates = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin') -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { Join-Path $_.FullName 'codex.exe' } |
        Where-Object { Test-Path -LiteralPath $_ }
    return $candidates | Select-Object -First 1
}

if ($Rollback) {
    Write-Host '[1/3] Removing CODEX_CLI_PATH...'
    [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH', $null, 'User')
    Remove-Item Env:\CODEX_CLI_PATH -ErrorAction SilentlyContinue

    Write-Host '[2/3] Reporting bundled CLI that will be used again...'
    $bundled = Get-BundledCli
    if ($bundled) { Write-Host "      $bundled" } else { Write-Host '      (bundled CLI not located; Desktop will re-extract it)' }

    Write-Host '[3/3] Done. Restart Codex Desktop to take effect.'
    Write-Host "      Patched binaries were left in place at $BinDir (delete the folder to reclaim ~320 MB)."
    return
}

if ($Verify) {
    $current = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')
    Write-Host "CODEX_CLI_PATH = $current"
    if (-not $current) { Write-Host 'RESULT: patch NOT active (no override set)'; return }
    if (-not (Test-Path -LiteralPath $current)) { Write-Host 'RESULT: override points at a missing file'; return }
    $ver = & $current --version
    Write-Host "binary reports: $ver"
    Write-Host 'RESULT: override active. Run scripts\probe_policy.py to confirm policy behaviour.'
    return
}

Write-Host "[1/4] Checking source binary..."
if (-not (Test-Path -LiteralPath $Source)) {
    throw "Patched binary not found at '$Source'. Build it first (scripts\build-patched-codex.cmd)."
}
$srcSize = (Get-Item -LiteralPath $Source).Length
Write-Host ("      {0} ({1:N0} bytes)" -f $Source, $srcSize)

Write-Host "[2/4] Installing to $Target ..."
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
Copy-Item -LiteralPath $Source -Destination $Target -Force
Write-Host ("      {0:N0} bytes written" -f (Get-Item -LiteralPath $Target).Length)

Write-Host "[3/4] Pointing CODEX_CLI_PATH at the patched binary..."
[Environment]::SetEnvironmentVariable('CODEX_CLI_PATH', $Target, 'User')
Write-Host "      CODEX_CLI_PATH = $Target"

Write-Host "[4/4] Verifying..."
$ver = & $Target --version
Write-Host "      $ver"
Write-Host ''
Write-Host 'Done. Fully quit Codex Desktop (tray -> Quit) and start it again.'
Write-Host "Roll back any time with:  powershell -File $PSCommandPath -Rollback"
