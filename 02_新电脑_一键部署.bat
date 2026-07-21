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
$CodexHome = Split-Path -Parent ([IO.Path]::GetFullPath($BatPath))
$TargetUserProfile = Split-Path -Parent $CodexHome
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ExtractRoot = Join-Path $env:TEMP "codex-win-restore-$([Guid]::NewGuid().ToString('N'))"
$BackupRoot = Join-Path $TargetUserProfile ".codex-backup-before-migration-$Stamp"

function Write-Utf8NoBom {
    param([string]$Path, [string[]]$Lines)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $utf8)
}

function Wait-CodexClosed {
    if ($env:CODEX_MIGRATION_SKIP_RUNNING_CHECK -eq "1") { return }
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^codex($|-)' })
    if ($running.Count -gt 0) {
        Write-Host "检测到 Codex 正在运行。请完全退出 Codex 后回到本窗口。" -ForegroundColor Yellow
        [void](Read-Host "关闭完成后按 Enter 继续；直接关闭本窗口可取消")
        $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^codex($|-)' })
        if ($running.Count -gt 0) { throw "Codex 仍在运行。为避免数据库损坏，已停止部署。" }
    }
}

function Expand-ZipSafely {
    param([string]$Zip, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $destFull = ([IO.Path]::GetFullPath($Destination)).TrimEnd('\') + '\'
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($entry in $archive.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName.Replace('/','\')))
            if (-not $target.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) {
                throw "压缩包包含越界路径，拒绝解压：$($entry.FullName)"
            }
            if ([string]::IsNullOrEmpty($entry.Name)) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
                continue
            }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            $input = $entry.Open()
            try {
                $output = [IO.File]::Create($target)
                try { $input.CopyTo($output) } finally { $output.Dispose() }
            } finally { $input.Dispose() }
        }
    } finally { $archive.Dispose() }
}

function Verify-PackageHashes {
    $hashFile = Join-Path $ExtractRoot "SHA256SUMS.txt"
    if (-not (Test-Path -LiteralPath $hashFile -PathType Leaf)) { throw "压缩包缺少 SHA256SUMS.txt。" }
    $checked = 0
    foreach ($line in [IO.File]::ReadLines($hashFile)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})\s{2}(.+)$') { throw "无法识别的校验行：$line" }
        $expected = $Matches[1].ToLowerInvariant()
        $relative = $Matches[2].Replace('/','\')
        $path = Join-Path $ExtractRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "压缩包缺少清单文件：$relative" }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "文件校验失败：$relative" }
        $checked++
    }
    Write-Host "校验通过：$checked 个文件。"
}

function Copy-BackupFiltered {
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
    Get-ChildItem -LiteralPath $CodexHome -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $relative = $_.FullName.Substring($CodexHome.Length).TrimStart('\','/')
        $parts = @($relative -split '[\\/]')
        $top = if ($parts.Count) { $parts[0] } else { "" }
        if ($top -in @(".tmp","tmp","cache","browser","computer-use","node_repl","process_manager")) { return }
        if (-not $_.PSIsContainer -and ($_.Name -like "Codex-Windows-Migration-*.zip" -or ($_.Name -like "*.bat" -and $parts.Count -eq 1))) { return }
        $target = Join-Path $BackupRoot $relative
        if ($_.PSIsContainer) {
            New-Item -ItemType Directory -Force -Path $target | Out-Null
        } else {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        }
    }
}

function Merge-RegularPayloadFiles {
    param([string]$PayloadCodex)
    $protected = @(
        "auth.json", "auth.json.bak", ".cockpit_codex_auth.json", ".cockpit_codex_auth.json.bak",
        "config.toml", "config.toml.bak", "config.toml.bak.bak", "installation_id",
        "models_cache.json", "chrome-native-hosts-v2.json", "session_index.jsonl"
    )
    Get-ChildItem -LiteralPath $PayloadCodex -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $relative = $_.FullName.Substring($PayloadCodex.Length).TrimStart('\','/')
        $parts = @($relative -split '[\\/]')
        if (-not $_.PSIsContainer) {
            if ($parts.Count -eq 1 -and $protected -contains $_.Name) { return }
            if ($parts.Count -eq 1 -and $_.Name -like ".codex-global-state.json*") { return }
            if ($_.Name -like "state_*.sqlite" -or $_.Name -like "memories_*.sqlite" -or $_.Name -like "goals_*.sqlite") { return }
            if ($_.Name -like "*.sqlite-shm" -or $_.Name -like "*.sqlite-wal") { return }
        }
        $target = Join-Path $CodexHome $relative
        if ($_.PSIsContainer) {
            New-Item -ItemType Directory -Force -Path $target | Out-Null
        } else {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        }
    }
}

function Merge-SessionIndex {
    param([string]$SourceIndex)
    $targetIndex = Join-Path $CodexHome "session_index.jsonl"
    $byId = @{}
    foreach ($path in @($targetIndex, $SourceIndex)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        foreach ($line in [IO.File]::ReadLines($path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $row = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($row.id) { $byId[[string]$row.id] = $row }
        }
    }
    $lines = @($byId.Values | Sort-Object -Property updated_at -Descending | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 })
    Write-Utf8NoBom -Path $targetIndex -Lines $lines
}

function Find-Python {
    foreach ($candidate in @(
        [pscustomobject]@{ Command="python"; Args=@() },
        [pscustomobject]@{ Command="py"; Args=@("-3") }
    )) {
        $found = Get-Command $candidate.Command -ErrorAction SilentlyContinue
        if (-not $found) { continue }
        try {
            & $found.Source @($candidate.Args) -c "import sqlite3, json" 2>$null
            if ($LASTEXITCODE -eq 0) { return [pscustomobject]@{ Command=$found.Source; Args=$candidate.Args } }
        } catch {}
    }
    $bundled = Get-ChildItem -LiteralPath (Join-Path $TargetUserProfile ".cache\codex-runtimes") -Filter "python.exe" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bundled) { return [pscustomobject]@{ Command=$bundled.FullName; Args=@() } }
    return $null
}

function Invoke-MetadataAndSqliteMigration {
    param([string]$PayloadCodex, [pscustomobject]$Manifest, [pscustomobject]$Python)
    $pyFile = Join-Path $ExtractRoot "migrate_codex_state.py"
    $reportFile = Join-Path $CodexHome "codex-windows-migration-report.json"
    $pyCode = @'
import json
import os
import re
import shutil
import sqlite3
import sys
from pathlib import Path

payload = Path(sys.argv[1])
target = Path(sys.argv[2])
old_user = sys.argv[3]
new_user = sys.argv[4]
old_codex = sys.argv[5]
report_path = Path(sys.argv[6])

def replace_ci(text, old, new):
    if text is None or not old:
        return text
    s = str(text)
    pos = s.lower().find(str(old).lower())
    while pos >= 0:
        s = s[:pos] + str(new) + s[pos + len(str(old)):]
        pos = s.lower().find(str(old).lower(), pos + len(str(new)))
    return s

def remap(value):
    if value is None:
        return value
    s = str(value)
    pairs = [
        (old_codex, str(target)),
        (old_codex.replace('\\', '/'), str(target).replace('\\', '/')),
        (old_user, new_user),
        (old_user.replace('\\', '/'), new_user.replace('\\', '/')),
    ]
    for old, new in pairs:
        s = replace_ci(s, old, new)
    return s

session_files = []
for folder in (target / 'sessions', target / 'archived_sessions'):
    if folder.exists():
        session_files.extend(folder.rglob('*.jsonl'))

session_by_id = {}
uuid_re = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', re.I)
for path in session_files:
    match = uuid_re.search(path.name)
    if match:
        session_by_id[match.group(0).lower()] = path

rewritten_files = 0
rewritten_records = 0
for path in session_files:
    changed_file = False
    output = []
    with path.open('r', encoding='utf-8', errors='strict') as handle:
        for raw in handle:
            line = raw.rstrip('\r\n')
            ending = '\n' if raw.endswith(('\n', '\r')) else ''
            try:
                row = json.loads(line)
            except Exception:
                output.append(raw)
                continue
            if row.get('type') not in ('session_meta', 'turn_context'):
                output.append(raw)
                continue
            payload_obj = row.get('payload') if isinstance(row.get('payload'), dict) else None
            changed = False
            if payload_obj is not None and isinstance(payload_obj.get('cwd'), str):
                new_value = remap(payload_obj['cwd'])
                if new_value != payload_obj['cwd']:
                    payload_obj['cwd'] = new_value
                    changed = True
            if payload_obj is not None and isinstance(payload_obj.get('workspace_roots'), list):
                roots = [remap(x) if isinstance(x, str) else x for x in payload_obj['workspace_roots']]
                if roots != payload_obj['workspace_roots']:
                    payload_obj['workspace_roots'] = roots
                    changed = True
            if changed:
                output.append(json.dumps(row, ensure_ascii=False, separators=(',', ':')) + ending)
                changed_file = True
                rewritten_records += 1
            else:
                output.append(raw)
    if changed_file:
        path.write_text(''.join(output), encoding='utf-8', newline='')
        rewritten_files += 1

def newest_db(root, pattern):
    files = list(root.glob(pattern))
    return max(files, key=lambda p: p.stat().st_mtime) if files else None

source_state = newest_db(payload, 'state_*.sqlite')
target_state = newest_db(target, 'state_*.sqlite')
threads_imported = 0
state_integrity = 'not_available'

if source_state:
    src_check = sqlite3.connect(f'file:{source_state.as_posix()}?mode=ro', uri=True)
    state_integrity = src_check.execute('pragma integrity_check').fetchone()[0]
    src_check.close()
    if state_integrity != 'ok':
        raise RuntimeError(f'source state database integrity check failed: {state_integrity}')
    if target_state is None:
        target_state = target / source_state.name
        shutil.copy2(source_state, target_state)

    src = sqlite3.connect(f'file:{source_state.as_posix()}?mode=ro', uri=True)
    src.row_factory = sqlite3.Row
    dst = sqlite3.connect(str(target_state))
    dst.row_factory = sqlite3.Row
    src_has_threads = src.execute("select 1 from sqlite_master where type='table' and name='threads'").fetchone()
    dst_has_threads = dst.execute("select 1 from sqlite_master where type='table' and name='threads'").fetchone()
    if src_has_threads and dst_has_threads:
        src_cols = [r[1] for r in src.execute('pragma table_info(threads)').fetchall()]
        dst_info = dst.execute('pragma table_info(threads)').fetchall()
        dst_cols = [r[1] for r in dst_info]
        common = [c for c in dst_cols if c in src_cols]
        q = lambda name: '"' + name.replace('"', '""') + '"'
        defaults = {
            'rollout_path':'', 'created_at':0, 'updated_at':0, 'source':'vscode',
            'model_provider':'openai', 'cwd':'', 'title':'', 'sandbox_policy':'{}',
            'approval_mode':'on-request', 'tokens_used':0, 'has_user_event':0,
            'archived':0, 'cli_version':'', 'first_user_message':'', 'memory_mode':'enabled',
            'preview':'', 'history_mode':'full'
        }
        for source_row in src.execute('select * from threads'):
            data = dict(source_row)
            tid = str(data.get('id') or '')
            if not tid:
                continue
            for key in ('cwd', 'agent_path'):
                if isinstance(data.get(key), str):
                    data[key] = remap(data[key])
            session_path = session_by_id.get(tid.lower())
            if session_path:
                data['rollout_path'] = str(session_path)
            elif isinstance(data.get('rollout_path'), str):
                data['rollout_path'] = remap(data['rollout_path'])
            existing = dst.execute('select 1 from threads where id=?', (tid,)).fetchone()
            if existing:
                update_cols = [c for c in common if c != 'id' and data.get(c) is not None]
                if update_cols:
                    sql = 'update threads set ' + ','.join(q(c) + '=?' for c in update_cols) + ' where id=?'
                    dst.execute(sql, [data[c] for c in update_cols] + [tid])
            else:
                values = {}
                for info in dst_info:
                    name, col_type, not_null, default_value, primary_key = info[1], info[2] or '', info[3], info[4], info[5]
                    if name in data and data[name] is not None:
                        values[name] = data[name]
                    elif name == 'id':
                        values[name] = tid
                    elif not_null and default_value is None:
                        values[name] = defaults.get(name, 0 if any(x in col_type.upper() for x in ('INT','REAL','NUM')) else '')
                cols = list(values)
                sql = 'insert into threads (' + ','.join(q(c) for c in cols) + ') values (' + ','.join('?' for _ in cols) + ')'
                dst.execute(sql, [values[c] for c in cols])
            threads_imported += 1
        dst.commit()
    dst_integrity = dst.execute('pragma integrity_check').fetchone()[0]
    if dst_integrity != 'ok':
        raise RuntimeError(f'target state database integrity check failed: {dst_integrity}')
    src.close()
    dst.close()

source_global = payload / '.codex-global-state.json'
target_global = target / '.codex-global-state.json'
if target_global.exists():
    try:
        target_data = json.loads(target_global.read_text(encoding='utf-8', errors='strict'))
    except Exception:
        target_data = {}
else:
    target_data = {}
if source_global.exists():
    try:
        source_data = json.loads(source_global.read_text(encoding='utf-8', errors='strict'))
    except Exception:
        source_data = {}
else:
    source_data = {}

for key in ('electron-saved-workspace-roots', 'project-order', 'active-workspace-roots'):
    current = target_data.get(key) if isinstance(target_data.get(key), list) else []
    incoming = source_data.get(key) if isinstance(source_data.get(key), list) else []
    for value in incoming:
        mapped = remap(value) if isinstance(value, str) else value
        if mapped not in current:
            current.append(mapped)
    target_data[key] = current

for key in ('thread-workspace-root-hints', 'thread-projectless-output-directories'):
    current = target_data.get(key) if isinstance(target_data.get(key), dict) else {}
    incoming = source_data.get(key) if isinstance(source_data.get(key), dict) else {}
    for tid, value in incoming.items():
        current[str(tid)] = remap(value) if isinstance(value, str) else value
    target_data[key] = current

current_projectless = target_data.get('projectless-thread-ids') if isinstance(target_data.get('projectless-thread-ids'), list) else []
for tid in source_data.get('projectless-thread-ids', []) if isinstance(source_data.get('projectless-thread-ids'), list) else []:
    if tid not in current_projectless:
        current_projectless.append(tid)
target_data['projectless-thread-ids'] = current_projectless

target_global.write_text(json.dumps(target_data, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')

report = {
    'session_files_seen': len(session_files),
    'session_files_metadata_rewritten': rewritten_files,
    'session_records_rewritten': rewritten_records,
    'threads_imported_or_updated': threads_imported,
    'state_integrity': state_integrity,
    'target_state_db': str(target_state) if target_state else '',
}
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps(report, ensure_ascii=False))
'@
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($pyFile, $pyCode, $utf8)
    & $Python.Command @($Python.Args) $pyFile $PayloadCodex $CodexHome ([string]$Manifest.source_user_profile) $TargetUserProfile ([string]$Manifest.source_codex_home) $reportFile
    if ($LASTEXITCODE -ne 0) { throw "SQLite/路径迁移失败。目标数据已经备份到：$BackupRoot" }
}

function Restore-AuxiliaryDatabases {
    param([string]$PayloadCodex)
    foreach ($pattern in @("memories_*.sqlite", "goals_*.sqlite")) {
        Get-ChildItem -LiteralPath $PayloadCodex -File -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $CodexHome $_.Name) -Force
        }
    }
}

function Restore-ProjectShellsAndOpen {
    $global = Join-Path $CodexHome ".codex-global-state.json"
    if (-not (Test-Path -LiteralPath $global -PathType Leaf)) { return }
    try { $state = Get-Content -LiteralPath $global -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($key in @('electron-saved-workspace-roots', 'project-order', 'active-workspace-roots')) {
        foreach ($value in @($state.$key)) {
            if ($value -and [IO.Path]::IsPathRooted([string]$value) -and -not $roots.Contains([string]$value)) {
                $roots.Add([string]$value)
            }
        }
    }
    if ($state.'thread-workspace-root-hints') {
        foreach ($property in $state.'thread-workspace-root-hints'.PSObject.Properties) {
            $value = [string]$property.Value
            if ($value -and [IO.Path]::IsPathRooted($value) -and -not $roots.Contains($value)) {
                $roots.Add($value)
            }
        }
    }
    if ($roots.Count -eq 0) { return }

    $created = 0
    $available = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            try {
                New-Item -ItemType Directory -Force -Path $root | Out-Null
                $created++
                Write-Host "已创建项目壳目录：$root"
            } catch {
                Write-Warning "无法创建项目壳目录：$root；$($_.Exception.Message)"
                continue
            }
        }
        $available.Add($root)
    }
    Write-Host "项目路径恢复：可用 $($available.Count) 个，新建空目录 $created 个。"

    if ($env:CODEX_MIGRATION_SKIP_APP_OPEN -eq "1") { return }
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $cmd) { return }
    foreach ($root in $available) {
        try {
            Write-Host "向 Codex 注册项目路径：$root"
            & $cmd.Source app $root
        } catch {
            Write-Warning "项目注册失败，可稍后在 Codex 中手动打开：$root"
        }
    }
}

try {
    if ((Split-Path -Leaf $CodexHome) -ne ".codex") {
        throw "请把本 BAT 和迁移 ZIP 放到新电脑的 .codex 目录内再双击。当前目录：$CodexHome"
    }
    $zip = Get-ChildItem -LiteralPath $CodexHome -File -Filter "Codex-Windows-Migration-*.zip" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $zip) { throw "当前 .codex 目录没有找到 Codex-Windows-Migration-*.zip。" }

    Wait-CodexClosed
    Write-Host "使用迁移包：$($zip.FullName)"
    Expand-ZipSafely -Zip $zip.FullName -Destination $ExtractRoot
    Verify-PackageHashes

    $manifestPath = Join-Path $ExtractRoot "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "压缩包缺少 manifest.json。" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.package_type -ne "codex-windows-to-windows" -or [int]$manifest.schema_version -ne 1) {
        throw "不支持的迁移包类型或版本。"
    }
    $payloadCodex = Join-Path $ExtractRoot "payload\.codex"
    if (-not (Test-Path -LiteralPath $payloadCodex -PathType Container)) { throw "迁移包缺少 payload\.codex。" }

    $python = Find-Python
    if (-not $python) {
        throw "没有找到可用的 Python 3。部署需要 Python 自带的 sqlite3 来安全合并 state_*.sqlite；请安装 Python 3 后重试。"
    }

    Write-Host "正在备份新电脑当前 .codex……"
    Copy-BackupFiltered
    Write-Host "备份位置：$BackupRoot"

    Write-Host "正在合并会话、Skills、Plugins 和其他用户数据……"
    Merge-RegularPayloadFiles -PayloadCodex $payloadCodex
    Merge-SessionIndex -SourceIndex (Join-Path $payloadCodex "session_index.jsonl")
    Restore-AuxiliaryDatabases -PayloadCodex $payloadCodex
    Invoke-MetadataAndSqliteMigration -PayloadCodex $payloadCodex -Manifest $manifest -Python $python

    $sourceSessionCount = @(
        Get-ChildItem -LiteralPath (Join-Path $payloadCodex "sessions") -File -Filter "*.jsonl" -Recurse -ErrorAction SilentlyContinue
    ).Count
    $targetSessionCount = @(
        Get-ChildItem -LiteralPath (Join-Path $CodexHome "sessions") -File -Filter "*.jsonl" -Recurse -ErrorAction SilentlyContinue
    ).Count
    $report = Get-Content -LiteralPath (Join-Path $CodexHome "codex-windows-migration-report.json") -Raw -Encoding UTF8 | ConvertFrom-Json

    Write-Host ""
    Write-Host "部署完成。" -ForegroundColor Green
    Write-Host "目标备份：$BackupRoot"
    Write-Host "迁移包会话：$sourceSessionCount；目标现有会话：$targetSessionCount"
    Write-Host "SQLite 导入/更新线程：$($report.threads_imported_or_updated)"
    Write-Host "修正元数据的会话文件：$($report.session_files_metadata_rewritten)"
    Write-Host "数据库完整性：$($report.state_integrity)"
    Write-Host "登录信息和新电脑 config.toml 均已保留。"
    Write-Host "项目路径不存在时，脚本会创建空项目壳并注册，使旧对话重新按原项目归组。" -ForegroundColor Yellow
    Write-Host "注意：空项目壳不含源码；需要代码时仍要把原项目文件复制进去。" -ForegroundColor Yellow

    Restore-ProjectShellsAndOpen
} catch {
    Write-Host ""
    Write-Host "部署失败：$($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path -LiteralPath $BackupRoot) { Write-Host "部署前备份仍在：$BackupRoot" -ForegroundColor Yellow }
    exit 1
} finally {
    if (Test-Path -LiteralPath $ExtractRoot) { Remove-Item -LiteralPath $ExtractRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

exit 0
