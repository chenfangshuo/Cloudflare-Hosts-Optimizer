#Requires -Version 7.0
<#
    运行摘要 last-run.json 的读写与展示。

    边界：
      * 只用于菜单展示，绝不参与回滚授权或完整性校验。
      * 并发写入用独立短时命名互斥锁 + 唯一临时文件 + 原子替换；
        拿不到锁或写入失败时返回 $false，不影响主流程和退出码。
      * lastRun 取 finishedAt 较新者。
      * 提交记录按规范化后的目标路径分别保存（commits），临时 hosts 的提交
        不会覆盖系统 hosts 的“最近提交”。
      * 提交时间用事务内记录的 committedAt，而不是整次运行的 finishedAt；
        旧记录不能覆盖新提交。
      * 只有实际发生替换（Changed=true 且成功）才更新提交记录。
#>

$script:RunSummaryMutexName = 'Global\Cloudflare-Hosts-Optimizer-Summary'

# 提交记录按目标路径分组：同一个目标只保留最新一次提交。
function ConvertTo-SummaryHostsPath {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Path = '')
    if (-not $Path) { return '' }
    try { return [IO.Path]::GetFullPath($Path) } catch { return '' }
}

function ConvertTo-SummaryPathKey {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Path = '')
    $full = ConvertTo-SummaryHostsPath -Path $Path
    if (-not $full) { return '' }
    return $full.ToLowerInvariant()
}

function New-RunSummaryRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$HostsPath,
        [Parameter(Mandatory)][datetime]$StartedAt,
        [Parameter(Mandatory)][datetime]$FinishedAt,
        [int]$ExitCode = 0,
        [bool]$Changed = $false,
        [int]$Updated = 0,
        [int]$Kept = 0,
        [int]$Unverified = 0,
        [AllowEmptyString()][string]$RunId = '',
        # 实际完成 hosts 替换的时间（在事务锁内记录），不是整次运行的结束时间
        [System.Nullable[datetime]]$CommittedAt = $null
    )
    [pscustomobject]@{
        runId       = $RunId
        mode        = $Mode
        hostsPath   = ConvertTo-SummaryHostsPath -Path $HostsPath
        startedAt   = $StartedAt.ToString('o')
        finishedAt  = $FinishedAt.ToString('o')
        # PowerShell 会把 Nullable[datetime] 拆成 datetime，直接用即可
        committedAt = if ($CommittedAt) { ([datetime]$CommittedAt).ToString('o') } else { '' }
        exitCode    = $ExitCode
        changed     = $Changed
        counts      = [pscustomobject]@{ updated = $Updated; kept = $Kept; unverified = $Unverified }
    }
}

function Read-RunSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function ConvertTo-SummaryDate {
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return $null }
    try { return [datetime]::Parse($Text) } catch { return $null }
}

function Write-RunSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Run,
        [bool]$Committed = $false,
        [AllowEmptyString()][string]$CommitMode = ''
    )
    $dir = Split-Path -Parent $Path
    if (-not $dir) { $dir = '.' }
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    } catch { return $false }

    $mutex = [Threading.Mutex]::new($false, $script:RunSummaryMutexName)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(2000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { return $false }

        $existing = Read-RunSummary -Path $Path
        $commits = [ordered]@{}
        if ($existing) {
            if ($existing.commits -is [System.Collections.IDictionary]) {
                foreach ($k in $existing.commits.Keys) { $commits[[string]$k] = $existing.commits[$k] }
            } elseif ($existing.commits) {
                foreach ($prop in $existing.commits.PSObject.Properties) { $commits[$prop.Name] = $prop.Value }
            } elseif ($existing.lastCommit) {
                # 旧格式没有按目标分组；缺少有效目标时不能默认当成系统 hosts
                $legacyKey = ConvertTo-SummaryPathKey -Path ([string]$existing.lastCommit.hostsPath)
                if ($legacyKey) { $commits[$legacyKey] = $existing.lastCommit }
            }
        }
        $record = [ordered]@{ lastRun = $Run; commits = $commits }
        if ($existing) {
            $oldFinished = ConvertTo-SummaryDate -Text ([string]$existing.lastRun.finishedAt)
            $newFinished = ConvertTo-SummaryDate -Text ([string]$Run.finishedAt)
            if ($oldFinished -and $newFinished -and $oldFinished -gt $newFinished) {
                $record.lastRun = $existing.lastRun
            }
        }

        if ($Committed) {
            # 提交时间取事务锁内记录的 committedAt；缺失时才退回 finishedAt
            $newAt = ConvertTo-SummaryDate -Text ([string]$Run.committedAt)
            if (-not $newAt) { $newAt = ConvertTo-SummaryDate -Text ([string]$Run.finishedAt) }
            $key = ConvertTo-SummaryPathKey -Path ([string]$Run.hostsPath)
            if ($key -and $newAt) {
                $oldAt = $null
                $old = $commits[$key]
                if ($old) { $oldAt = ConvertTo-SummaryDate -Text ([string]$old.at) }
                if (-not $oldAt -or $newAt -ge $oldAt) {
                    $commits[$key] = [pscustomobject]@{
                        runId     = $Run.runId
                        mode      = if ($CommitMode) { $CommitMode } else { $Run.mode }
                        hostsPath = $Run.hostsPath
                        at        = $newAt.ToString('o')
                    }
                }
            }
        }

        $temp = "$Path." + [guid]::NewGuid().ToString('N') + '.tmp'
        try {
            ($record | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $temp -Encoding utf8
            if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
            else { Move-Item -LiteralPath $temp -Destination $Path -Force }
            return $true
        } finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        return $false
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# 菜单状态栏用的两行文字。摘要缺失时只退回“上次报告时间”，不推断提交时间。
function Format-RunSummaryLine {
    [CmdletBinding()]
    param(
        $Summary,
        [AllowEmptyString()][string]$SystemHostsPath = '',
        [AllowEmptyString()][string]$ReportPath = ''
    )
    $modeLabel = @{ write = '写入'; dryrun = 'DryRun'; plan = 'Plan'; rollback = '回滚' }
    $lastRunText = ''
    $lastCommitText = ''

    if ($Summary -and $Summary.lastRun) {
        $r = $Summary.lastRun
        $mode = if ($modeLabel.ContainsKey([string]$r.mode)) { $modeLabel[[string]$r.mode] } else { [string]$r.mode }
        $time = ''
        $t = ConvertTo-SummaryDate -Text ([string]$r.finishedAt)
        if ($t) { $time = $t.ToString('yyyy-MM-dd HH:mm') }
        $sandbox = ''
        if ($SystemHostsPath -and $r.hostsPath) {
            try {
                if ([IO.Path]::GetFullPath([string]$r.hostsPath) -ine [IO.Path]::GetFullPath($SystemHostsPath)) {
                    $sandbox = '（临时 hosts）'
                }
            } catch { }
        }
        $lastRunText = "上次运行：$time · $mode · 退出码 $($r.exitCode)$sandbox"
    } elseif ($ReportPath -and (Test-Path -LiteralPath $ReportPath)) {
        $time = (Get-Item -LiteralPath $ReportPath).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        $lastRunText = "上次报告：$time"
    }

    # 只显示系统 hosts 自己的提交；临时 hosts 的提交单独存放，不会覆盖也不会冒充系统记录
    $commit = $null
    $systemKey = ConvertTo-SummaryPathKey -Path $SystemHostsPath
    if ($Summary -and $systemKey) {
        if ($Summary.commits -is [System.Collections.IDictionary]) {
            if ($Summary.commits.Contains($systemKey)) { $commit = $Summary.commits[$systemKey] }
        } elseif ($Summary.commits) {
            $prop = $Summary.commits.PSObject.Properties[$systemKey]
            if ($prop) { $commit = $prop.Value }
        }
        if (-not $commit -and $Summary.lastCommit) {
            # 兼容旧格式：目标必须确实等于系统 hosts
            if ((ConvertTo-SummaryPathKey -Path ([string]$Summary.lastCommit.hostsPath)) -eq $systemKey) {
                $commit = $Summary.lastCommit
            }
        }
    }
    if ($commit) {
        $mode = if ($commit.mode -eq 'rollback') { '回滚' } else { '写入' }
        $time = ''
        $t = ConvertTo-SummaryDate -Text ([string]$commit.at)
        if ($t) { $time = $t.ToString('yyyy-MM-dd HH:mm') }
        $lastCommitText = "最近提交：$mode · $time"
    }

    return [pscustomobject]@{ LastRun = $lastRunText; LastCommit = $lastCommitText }
}
