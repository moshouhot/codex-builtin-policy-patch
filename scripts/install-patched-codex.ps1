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
    [string]$Source = '',
    [string]$Version = '0.160.0',
    [switch]$Rollback,
    [switch]$Verify
)

# Resolve the build root inside the body: parameter defaults are evaluated before
# the environment is available in some hosts, which made Join-Path fail on null.
if (-not $env:BUILD_ROOT) { $env:BUILD_ROOT = 'E:\codex-build' }
if (-not $Source) { $Source = Join-Path $env:BUILD_ROOT 'target\release\codex.exe' }

$ErrorActionPreference = 'Stop'
$Root = Join-Path $env:LOCALAPPDATA 'CodexLocalPatch'
$BinDir = Join-Path $Root "bin\$Version"
$Target = Join-Path $BinDir 'codex.exe'

# Desktop resolves these helper executables from the SAME directory as codex.exe
# (hardcoded list in app.asar). Installing only codex.exe makes Desktop fail with
# "system cannot find codex-code-mode-host.exe" and no tool can run.
$SiblingExes = @(
    'codex-code-mode-host.exe'
    'codex-windows-sandbox-setup.exe'
    'codex-command-runner.exe'
)

function Get-BundledCliDir {
    $pkg = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
    if (-not $pkg) { return $null }
    $candidates = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin') -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'codex.exe') }
    if ($candidates) { return $candidates | Select-Object -First 1 } else { return $null }
}

function Get-BundledCli {
    $dir = Get-BundledCliDir
    if (-not $dir) { return $null }
    return Join-Path $dir.FullName 'codex.exe'
}

function Install-SiblingExes {
    # Copy the helper executables that Desktop expects next to codex.exe.
    $srcDir = Get-BundledCliDir
    if (-not $srcDir) {
        Write-Host '      [WARN] bundled CLI dir not found; cannot copy helper executables.'
        Write-Host '             Desktop needs them next to codex.exe or tools will not run.'
        return
    }
    foreach ($name in $SiblingExes) {
        $from = Join-Path $srcDir.FullName $name
        $to = Join-Path $BinDir $name
        if (Test-Path -LiteralPath $from) {
            Copy-Item -LiteralPath $from -Destination $to -Force
            Write-Host ("      {0} ({1:N0} bytes)" -f $name, (Get-Item -LiteralPath $to).Length)
        } else {
            Write-Host "      [WARN] missing in bundled dir: $name"
        }
    }
}

function Test-SiblingExes {
    $missing = @()
    foreach ($name in $SiblingExes) {
        if (-not (Test-Path -LiteralPath (Join-Path $BinDir $name))) { $missing += $name }
    }
    return $missing
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
    $missing = Test-SiblingExes
    if ($missing.Count -gt 0) {
        Write-Host "RESULT: override active BUT helpers missing: $($missing -join ', ')"
        Write-Host '        Desktop cannot run tools in this state. Re-run the installer without -Verify to copy them.'
        return
    }
    Write-Host 'RESULT: override active, helper executables present.'
    Write-Host '        Run scripts\probe_policy.py to confirm policy behaviour.'
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

    Write-Host '[3/4] Installing helper executables next to codex.exe...'
    Install-SiblingExes

    Write-Host '[4/4] Pointing CODEX_CLI_PATH at the patched binary...'
    [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH', $Target, 'User')
    Write-Host "      CODEX_CLI_PATH = $Target"

    $missing = Test-SiblingExes
    if ($missing.Count -gt 0) {
        Write-Host "      [WARN] missing helpers: $($missing -join ', ')"
        Write-Host '             Desktop will fail to run tools. Re-run after Codex re-extracts its bundled CLI.'
    } else {
        Write-Host '      all helper executables present'
    }

    Write-Host '[verify]'
    $ver = & $Target --version
    Write-Host "      $ver"
Write-Host ''
Write-Host 'Done. Fully quit Codex Desktop (tray -> Quit) and start it again.'
Write-Host "Roll back any time with:  powershell -File $PSCommandPath -Rollback"
