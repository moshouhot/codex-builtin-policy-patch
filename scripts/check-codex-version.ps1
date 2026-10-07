<#
.SYNOPSIS
  Report whether the local Codex CLI patch is still active, current, or stale
  after a Codex Desktop / Store upgrade.

.DESCRIPTION
  Compares three things:
    1. The version the CODEX_CLI_PATH override points at (the patched build).
    2. The version of the CLI bundled inside the currently installed Desktop
       package (extracted to %LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\codex.exe).
    3. The Desktop app version.

  A Desktop upgrade extracts a NEW bundled CLI while CODEX_CLI_PATH keeps
  pointing at the OLD patched build. That state is "stale": the patch is still
  applied, but you are running a mismatched CLI. This script detects it.

  The bundled CLI lives under WindowsApps and cannot be executed, so its version
  is read by scanning the binary for its version string (via ripgrep when
  available, otherwise a chunked .NET scan).

.PARAMETER Json
  Emit machine-readable JSON instead of the human report.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-codex-version.ps1

.EXIT CODES
  0 = healthy (patched and current, or intentionally not patched)
  1 = action needed (stale override, or broken override path)
#>
[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = 'Stop'

function Get-FileVersionString {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Patterns)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    # Fast path: ripgrep (0.2s for a 320MB binary).
    $rg = @(
        (Join-Path $env:USERPROFILE '.pi\agent\bin\rg.exe'),
        (Join-Path $env:USERPROFILE '.codex\vendor_imports\rg.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $rg) {
        $cmd = Get-Command rg -ErrorAction SilentlyContinue
        if ($cmd) { $rg = $cmd.Source }
    }
    if ($rg) {
        foreach ($p in $Patterns) {
            $out = & $rg -a -o --no-filename $p $Path 2>$null | Select-Object -First 1
            if ($out -and $out -match '((?:\d+\.\d+\.\d+)(?:-[0-9A-Za-z]+(?:\.\d+)*)?)') { return $Matches[1] }
        }
    }

    # Fallback: chunked scan, tolerant of the needle spanning a chunk boundary.
    $needles = $Patterns | ForEach-Object { [Text.Encoding]::ASCII.GetBytes($_) }
    $maxNeedle = ($needles | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    $chunk = 8MB
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $buf = New-Object byte[] ($chunk + $maxNeedle)
        $carry = 0
        while (($read = $fs.Read($buf, $carry, $chunk)) -gt 0) {
            $len = $carry + $read
            $text = [Text.Encoding]::ASCII.GetString($buf, 0, $len)
            foreach ($p in $Patterns) {
                $m = [regex]::Match($text, [regex]::Escape($p) + '((?:\d+\.\d+\.\d+)(?:-[0-9A-Za-z]+(?:\.\d+)*)?)')
                if ($m.Success) { return $m.Groups[1].Value }
            }
            $carry = [Math]::Min($maxNeedle - 1, $len)
            [Array]::Copy($buf, $len - $carry, $buf, 0, $carry)
        }
    } finally { $fs.Dispose() }
    return $null
}

# --- gather -----------------------------------------------------------------
$override = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')
if (-not $override) { $override = $env:CODEX_CLI_PATH }
$overrideExists = $override -and (Test-Path -LiteralPath $override -PathType Leaf)

$overrideVersion = $null
if ($overrideExists) {
    try { $overrideVersion = (& $override --version) -replace '^codex-cli\s+', '' } catch { }
    if (-not $overrideVersion) {
        $overrideVersion = Get-FileVersionString -Path $override -Patterns @('codex-doctor/', 'codex-cli ')
    }
}

$binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
$bundled = $null
if (Test-Path -LiteralPath $binRoot) {
    $bundled = Get-ChildItem -LiteralPath $binRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'codex.exe' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } -Descending |
        Select-Object -First 1
}
$bundledVersion = if ($bundled) {
    Get-FileVersionString -Path $bundled -Patterns @('codex-doctor/', 'codex-cli ')
} else { $null }

$pkg = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
$desktopVersion = if ($pkg) { $pkg.Version.ToString() } else { $null }

$running = @(Get-CimInstance Win32_Process -Filter "Name='codex.exe'" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty ExecutablePath -Unique)
$runningViaOverride = $overrideExists -and ($running | Where-Object { $_ -and $_.Equals($override, 'OrdinalIgnoreCase') })

# --- verdict ----------------------------------------------------------------
if (-not $override) {
    $state = 'PATCH_INACTIVE'
    $exit = 0
} elseif (-not $overrideExists) {
    $state = 'PATCH_BROKEN'
    $exit = 1
} elseif ($bundledVersion -and $overrideVersion -and ($bundledVersion -ne $overrideVersion)) {
    $state = 'PATCH_STALE'
    $exit = 1
} elseif ($bundledVersion -and $overrideVersion) {
    $state = 'PATCHED_AND_CURRENT'
    $exit = 0
} else {
    $state = 'PATCHED_VERSION_UNKNOWN'
    $exit = 0
}

if ($Json) {
    [pscustomobject]@{
        state                = $state
        overridePath         = $override
        overrideExists       = [bool]$overrideExists
        overrideVersion      = $overrideVersion
        bundledCliPath       = $bundled
        bundledVersion       = $bundledVersion
        desktopVersion       = $desktopVersion
        runningCliPaths      = $running
        runningViaOverride   = [bool]$runningViaOverride
    } | ConvertTo-Json -Depth 4
    exit $exit
}

# --- report -----------------------------------------------------------------
Write-Host ''
Write-Host '  Codex CLI 补丁状态检查' -ForegroundColor Cyan
Write-Host ('  ' + ('-' * 58))
Write-Host ("  Desktop 版本            : {0}" -f $(if ($desktopVersion) { $desktopVersion } else { '(未知)' }))
Write-Host ("  自带 CLI 版本           : {0}" -f $(if ($bundledVersion) { $bundledVersion } else { '(未找到 / 无法读取)' }))
Write-Host ("  CODEX_CLI_PATH 版本     : {0}" -f $(if ($overrideVersion) { $overrideVersion } else { '(未设置)' }))
Write-Host ("  CODEX_CLI_PATH 路径     : {0}" -f $(if ($override) { $override } else { '(未设置)' }))
if ($running.Count -gt 0) {
    Write-Host ("  正在运行的 codex.exe    : {0} 个进程" -f $running.Count)
    Write-Host ("  是否经由覆盖路径启动    : {0}" -f $(if ($runningViaOverride) { '是' } else { '否（可能仍是升级前的旧进程）' }))
}
Write-Host ''

switch ($state) {
    'PATCHED_AND_CURRENT' {
        Write-Host '  结论：补丁生效，且版本与 Desktop 自带的 CLI 一致。' -ForegroundColor Green
        Write-Host '        无需任何操作。'
    }
    'PATCHED_VERSION_UNKNOWN' {
        Write-Host '  结论：覆盖已设置，但无法读取某一侧版本，无法比对。' -ForegroundColor Yellow
        Write-Host '        可直接用 scripts\probe_policy.py 实测策略行为。'
    }
    'PATCH_INACTIVE' {
        Write-Host '  结论：未启用补丁，当前使用官方自带 CLI。' -ForegroundColor Gray
        Write-Host '        如需启用：scripts\install-patched-codex.ps1'
    }
    'PATCH_BROKEN' {
        Write-Host '  结论：CODEX_CLI_PATH 指向的文件不存在。' -ForegroundColor Red
        Write-Host '        请重新构建后安装，或先回退到官方 CLI：'
        Write-Host '        scripts\install-patched-codex.ps1 -Rollback'
    }
    'PATCH_STALE' {
        Write-Host ('  结论：需要重新打补丁。') -ForegroundColor Yellow
        Write-Host ("        覆盖指向 {0}，但 Desktop 自带的是 {1}。" -f $overrideVersion, $bundledVersion)
        Write-Host '        Desktop 升级后自带 CLI 已换新，而 CODEX_CLI_PATH 仍指向旧版补丁。'
        Write-Host '        补丁没丢，但正在跑一个版本不匹配的 CLI。处理方式二选一：'
        Write-Host ''
        Write-Host '        A) 立刻回退到官方 CLI（安全，先恢复可用）：'
        Write-Host '           scripts\install-patched-codex.ps1 -Rollback'
        Write-Host ''
        Write-Host '        B) 重新构建并安装补丁（约 25 分钟）：'
        Write-Host '           scripts\build-patched-codex.cmd'
        Write-Host '           scripts\install-patched-codex.ps1 -Version <新版号>'
        Write-Host ''
        Write-Host '        提示：重新构建前先确认上游是否改动了补丁涉及的两个函数；'
        Write-Host '        若已改动，git apply 会直接报错，需要人工核对后再打。'
    }
}
Write-Host ''
exit $exit
