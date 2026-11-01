#Requires -Version 7.0
<#
    运行摘要 last-run.json 的读写与展示。

    边界：
      * 只用于菜单展示，绝不参与回滚授权或完整性校验。
      * 并发写入用独立短时命名互斥锁 + 唯一临时文件 + 原子替换；
        拿不到锁或写入失败时返回 $false，不影响主流程和退出码。
      * lastRun 取 finishedAt 较新者；lastCommit 取 at 较新者，旧记录不能覆盖新提交。
      * 只有实际发生替换（Changed=true 且成功）才更新 lastCommit。
#>

$script:RunSummaryMutexName = 'Global\Cloudflare-Hosts-Optimizer-Summary'

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
        [AllowEmptyString()][string]$RunId = ''
    )
    [pscustomobject]@{
        runId      = $RunId
        mode       = $Mode
        hostsPath  = $HostsPath
        startedAt  = $StartedAt.ToString('o')
        finishedAt = $FinishedAt.ToString('o')
        exitCode   = $ExitCode
        changed    = $Changed
        counts     = [pscustomobject]@{ updated = $Updated; kept = $Kept; unverified = $Unverified }
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
        $record = [ordered]@{ lastRun = $Run; lastCommit = $null }
        if ($existing) {
            if ($existing.lastCommit) { $record.lastCommit = $existing.lastCommit }
            $oldFinished = ConvertTo-SummaryDate -Text ([string]$existing.lastRun.finishedAt)
            $newFinished = ConvertTo-SummaryDate -Text ([string]$Run.finishedAt)
            if ($oldFinished -and $newFinished -and $oldFinished -gt $newFinished) {
                $record.lastRun = $existing.lastRun
            }
        }

        if ($Committed) {
            $newAt = ConvertTo-SummaryDate -Text ([string]$Run.finishedAt)
            $oldAt = $null
            if ($record.lastCommit) { $oldAt = ConvertTo-SummaryDate -Text ([string]$record.lastCommit.at) }
            if ($newAt -and (-not $oldAt -or $newAt -ge $oldAt)) {
                $record.lastCommit = [pscustomobject]@{
                    runId     = $Run.runId
                    mode      = if ($CommitMode) { $CommitMode } else { $Run.mode }
                    hostsPath = $Run.hostsPath
                    at        = $Run.finishedAt
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

    if ($Summary -and $Summary.lastCommit) {
        $c = $Summary.lastCommit
        $sameTarget = $true
        if ($SystemHostsPath -and $c.hostsPath) {
            try {
                if ([IO.Path]::GetFullPath([string]$c.hostsPath) -ine [IO.Path]::GetFullPath($SystemHostsPath)) { $sameTarget = $false }
            } catch { }
        }
        if ($sameTarget) {
            $mode = if ($c.mode -eq 'rollback') { '回滚' } else { '写入' }
            $time = ''
            $t = ConvertTo-SummaryDate -Text ([string]$c.at)
            if ($t) { $time = $t.ToString('yyyy-MM-dd HH:mm') }
            $lastCommitText = "最近提交：$mode · $time"
        }
    }

    return [pscustomobject]@{ LastRun = $lastRunText; LastCommit = $lastCommitText }
}
