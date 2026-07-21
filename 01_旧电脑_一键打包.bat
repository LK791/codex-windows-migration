@echo off
setlocal
chcp 65001 >nul
set "CODEX_MIGRATION_SELF=%~f0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$r=[IO.File]::ReadAllText($env:CODEX_MIGRATION_SELF,[Text.Encoding]::UTF8); $m=('### POWER'+'SHELL_PAYLOAD ###'); $i=$r.IndexOf($m); if($i -lt 0){throw 'PowerShell payload marker missing.'}; Invoke-Expression $r.Substring($i+$m.Length)"
set "CODEX_MIGRATION_EXIT=%ERRORLEVEL%"
echo.
if not "%CODEX_MIGRATION_NO_PAUSE%"=="1" pause
exit /b %CODEX_MIGRATION_EXIT%

### POWERSHELL_PAYLOAD ###
$BatPath = $env:CODEX_MIGRATION_SELF

$ErrorActionPreference = "Stop"
$SchemaVersion = 1
$CodexHome = Split-Path -Parent ([IO.Path]::GetFullPath($BatPath))
$SourceUserProfile = Split-Path -Parent $CodexHome
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ZipPath = Join-Path $CodexHome "Codex-Windows-Migration-$Stamp.zip"
$Stage = Join-Path $env:TEMP "codex-win-pack-$([Guid]::NewGuid().ToString('N'))"
$PayloadCodex = Join-Path $Stage "payload\.codex"

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Wait-CodexClosed {
    if ($env:CODEX_MIGRATION_SKIP_RUNNING_CHECK -eq "1") { return }
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^codex($|-)' })
    if ($running.Count -gt 0) {
        Write-Host "检测到 Codex 正在运行。请完全退出 Codex 后回到本窗口。" -ForegroundColor Yellow
        [void](Read-Host "关闭完成后按 Enter 继续；直接关闭本窗口可取消")
        $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^codex($|-)' })
        if ($running.Count -gt 0) { throw "Codex 仍在运行。为避免 SQLite/WAL 不一致，已停止打包。" }
    }
}

function Should-SkipRelativePath {
    param([string]$RelativePath, [IO.FileSystemInfo]$Item)
    $parts = @($RelativePath -split '[\\/]')
    $top = if ($parts.Count -gt 0) { $parts[0] } else { "" }
    $skipTop = @(
        ".sandbox", ".sandbox-bin", ".sandbox-secrets", ".tmp", "tmp", "cache",
        "browser", "computer-use", "node_repl", "process_manager", "vendor_imports",
        "backups"
    )
    if ($skipTop -contains $top) { return $true }
    if ($top -like "backup-*") { return $true }
    if ($Item.PSIsContainer) { return $false }

    $name = $Item.Name
    $skipFiles = @(
        "auth.json", "auth.json.bak", ".cockpit_codex_auth.json", ".cockpit_codex_auth.json.bak",
        "config.toml", "config.toml.bak", "config.toml.bak.bak", "installation_id",
        "models_cache.json", "chrome-native-hosts-v2.json"
    )
    if ($skipFiles -contains $name) { return $true }
    if ($name -like "logs_*.sqlite*") { return $true }
    if ($name -like "*.sqlite-shm" -or $name -like "*.sqlite-wal") { return $true }
    if ($name -like "Codex-Windows-Migration-*.zip") { return $true }
    if ($name -like "*.bat" -and $parts.Count -eq 1) { return $true }
    return $false
}

function Copy-CodexFiltered {
    New-Item -ItemType Directory -Force -Path $PayloadCodex | Out-Null
    Get-ChildItem -LiteralPath $CodexHome -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $relative = $_.FullName.Substring($CodexHome.Length).TrimStart('\','/')
        if (Should-SkipRelativePath -RelativePath $relative -Item $_) { return }
        $target = Join-Path $PayloadCodex $relative
        if ($_.PSIsContainer) {
            New-Item -ItemType Directory -Force -Path $target | Out-Null
        } else {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        }
    }
}

function Count-Files {
    param([string]$Path, [string]$Filter = "*")
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -Filter $Filter -ErrorAction SilentlyContinue).Count
}

function Ensure-SessionIndex {
    $indexPath = Join-Path $PayloadCodex "session_index.jsonl"
    $byId = @{}
    if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
        foreach ($line in [IO.File]::ReadLines($indexPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $row = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($row.id) { $byId[[string]$row.id] = $row }
        }
    }
    $sessions = Join-Path $PayloadCodex "sessions"
    if (Test-Path -LiteralPath $sessions -PathType Container) {
        Get-ChildItem -LiteralPath $sessions -File -Filter "*.jsonl" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $id = ""
            $name = ""
            foreach ($line in [IO.File]::ReadLines($_.FullName)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $record = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                if ($record.type -eq "session_meta" -and $record.payload) {
                    $id = [string]$(if ($record.payload.id) { $record.payload.id } else { $record.payload.session_id })
                    $name = [string]$(if ($record.payload.thread_name) { $record.payload.thread_name } elseif ($record.payload.title) { $record.payload.title } else { "" })
                    break
                }
            }
            if (-not $id -and $_.BaseName -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { $id = $Matches[1] }
            if ($id -and -not $byId.ContainsKey($id)) {
                $byId[$id] = [pscustomobject]@{
                    id = $id
                    thread_name = $(if ($name) { $name } else { $id })
                    updated_at = $_.LastWriteTimeUtc.ToString("o")
                }
            }
        }
    }
    $lines = @($byId.Values | Sort-Object -Property updated_at -Descending | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 })
    Write-Utf8NoBom -Path $indexPath -Text (($lines -join "`n") + "`n")
}

function New-Zip {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($ZipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        Get-ChildItem -LiteralPath $Stage -File -Recurse -Force | ForEach-Object {
            $relative = $_.FullName.Substring($Stage.Length + 1).Replace('\','/')
            $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset](Get-Date "2020-01-01T00:00:00Z")
            $input = [IO.File]::OpenRead($_.FullName)
            try {
                $output = $entry.Open()
                try { $input.CopyTo($output) } finally { $output.Dispose() }
            } finally { $input.Dispose() }
        }
    } finally { $archive.Dispose() }
}

try {
    if ((Split-Path -Leaf $CodexHome) -ne ".codex") {
        throw "请把本 BAT 放到需要迁移的 .codex 目录内再双击。当前目录：$CodexHome"
    }
    if (-not (Test-Path -LiteralPath $CodexHome -PathType Container)) { throw ".codex 目录不存在：$CodexHome" }
    if (-not (Test-Path -LiteralPath (Join-Path $CodexHome "sessions")) -and
        -not (Get-ChildItem -LiteralPath $CodexHome -Filter "state_*.sqlite" -File -ErrorAction SilentlyContinue)) {
        throw "这个目录不像有效的 Codex 用户数据目录：$CodexHome"
    }

    Wait-CodexClosed
    New-Item -ItemType Directory -Force -Path $PayloadCodex | Out-Null
    Write-Host "正在筛选并复制 Codex 数据……"
    Copy-CodexFiltered
    Ensure-SessionIndex

    $manifest = [ordered]@{
        schema_version = $SchemaVersion
        package_type = "codex-windows-to-windows"
        created_at = (Get-Date).ToString("o")
        source_user_profile = $SourceUserProfile
        source_codex_home = $CodexHome
        source_computer = $env:COMPUTERNAME
        counts = [ordered]@{
            sessions = Count-Files (Join-Path $PayloadCodex "sessions") "*.jsonl"
            archived_sessions = Count-Files (Join-Path $PayloadCodex "archived_sessions") "*.jsonl"
            state_databases = Count-Files $PayloadCodex "state_*.sqlite"
            memory_databases = Count-Files $PayloadCodex "memories_*.sqlite"
            goal_databases = Count-Files $PayloadCodex "goals_*.sqlite"
            skills = Count-Files (Join-Path $PayloadCodex "skills") "SKILL.md"
        }
        excluded = @(
            "auth/login files", "config.toml", "installation identity", "logs",
            "runtime caches", "browser/computer-use state", "SQLite WAL/SHM", "external project folders"
        )
    }
    Write-Utf8NoBom -Path (Join-Path $Stage "manifest.json") -Text (($manifest | ConvertTo-Json -Depth 8) + "`n")

    $notes = @"
Codex Windows -> Windows migration package

This package contains filtered data from:
$CodexHome

It intentionally excludes login credentials, config.toml, installation identity,
runtime caches, logs, SQLite WAL/SHM files, and project folders outside .codex.

On the target computer:
1. Install Codex and sign in once.
2. Close Codex completely.
3. Put this ZIP and 02_新电脑_一键部署.bat in the target user's .codex directory.
4. Double-click the deploy BAT.
"@
    Write-Utf8NoBom -Path (Join-Path $Stage "RESTORE-NOTES.txt") -Text $notes

    $deployBat = Join-Path $CodexHome "02_新电脑_一键部署.bat"
    if (Test-Path -LiteralPath $deployBat -PathType Leaf) {
        Copy-Item -LiteralPath $deployBat -Destination (Join-Path $Stage "02_新电脑_一键部署.bat") -Force
    }

    $hashLines = Get-ChildItem -LiteralPath $Stage -File -Recurse -Force | ForEach-Object {
        $relative = $_.FullName.Substring($Stage.Length + 1).Replace('\','/')
        "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower())  $relative"
    }
    Write-Utf8NoBom -Path (Join-Path $Stage "SHA256SUMS.txt") -Text (($hashLines -join "`n") + "`n")

    New-Zip
    $sizeMb = [Math]::Round((Get-Item -LiteralPath $ZipPath).Length / 1MB, 2)
    Write-Host "" 
    Write-Host "打包完成：$ZipPath" -ForegroundColor Green
    Write-Host "压缩包大小：$sizeMb MB"
    Write-Host "会话数：$($manifest.counts.sessions)，归档会话：$($manifest.counts.archived_sessions)"
    Write-Host "注意：项目源码不在 .codex 内，本压缩包不会自动包含外部项目目录。" -ForegroundColor Yellow
} catch {
    Write-Host "" 
    Write-Host "打包失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue }
}

exit 0
