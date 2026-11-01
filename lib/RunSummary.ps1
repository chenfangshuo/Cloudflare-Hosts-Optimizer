#Requires -Version 7.0
<#
    运行摘要 last-run.json 的读写与展示。

    边界：
      * 只用于菜单展示，绝不参与回滚授权或完整性校验。
      * 直接写 JSON；写入失败时返回 $false，不影响主流程和退出码。
        并发时可能丢失整个摘要，下一次有提交的运行会重新生成。
      * lastRun 取 finishedAt 较新者。
      * 提交记录按规范化后的目标路径分别保存（commits），临时 hosts 的提交
        不会覆盖系统 hosts 的“最近提交”。
      * 提交时间用事务内记录的 committedAt，而不是整次运行的 finishedAt；
        旧记录不能覆盖新提交。
      * 只有实际发生替换（Changed=true 且成功）才更新提交记录。
#>

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

# PowerShell 7.5+ 的 ConvertFrom-Json 会把 ISO 时间直接反序列化成 DateTime。
# 再用 [string] 转一次会丢毫秒/时区（变成“2026/11/1 17:00:00”这类本地化文本），
# 同秒内的提交会因此排错顺序，缓存也会按错误时区算寿命。这里接受对象：
# DateTime/DateTimeOffset 原样使用，只有字符串才按 RoundtripKind 解析。
function ConvertTo-SummaryDate {
    param($Value, [switch]$AsUtc)
    if ($null -eq $Value -or $Value -eq '') { return $null }
    if ($Value -is [datetime]) {
        $t = $Value
    } elseif ($Value -is [datetimeoffset]) {
        $t = $Value.UtcDateTime
    } else {
        try {
            $t = [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind)
        } catch { return $null }
    }
    if (-not $AsUtc) { return $t }
    return ConvertTo-UtcTime -Time $t
}

# 内部比较统一 UTC；Unspecified（旧格式没有偏移）按本地时间解释。
function ConvertTo-UtcTime {
    param([datetime]$Time)
    if ($Time.Kind -eq [DateTimeKind]::Utc) { return $Time }
    if ($Time.Kind -eq [DateTimeKind]::Local) { return $Time.ToUniversalTime() }
    return [datetime]::SpecifyKind($Time, [DateTimeKind]::Local).ToUniversalTime()
}

function Format-SummaryLocalTime {
    param($Value)
    $t = ConvertTo-SummaryDate -Value $Value
    if (-not $t) { return '' }
    if ($t.Kind -eq [DateTimeKind]::Utc) { $t = $t.ToLocalTime() }
    return $t.ToString('yyyy-MM-dd HH:mm')
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

    try {
        $existing = Read-RunSummary -Path $Path
        $commits = [ordered]@{}
        if ($existing) {
            if ($existing.commits -is [System.Collections.IDictionary]) {
                foreach ($k in $existing.commits.Keys) { $commits[[string]$k] = $existing.commits[$k] }
            } elseif ($existing.commits) {
                foreach ($prop in $existing.commits.PSObject.Properties) { $commits[$prop.Name] = $prop.Value }
            }
        }
        $record = [ordered]@{ lastRun = $Run; commits = $commits }
        if ($existing -and $existing.lastRun) {
            $oldFinished = ConvertTo-SummaryDate -Value $existing.lastRun.finishedAt -AsUtc
            $newFinished = ConvertTo-SummaryDate -Value $Run.finishedAt -AsUtc
            if ($oldFinished -and $newFinished -and $oldFinished -gt $newFinished) {
                $record.lastRun = $existing.lastRun
            }
        }

        if ($Committed) {
            # 提交时间取事务锁内记录的 committedAt；缺失时才退回 finishedAt
            $newAt = ConvertTo-SummaryDate -Value $Run.committedAt
            if (-not $newAt) { $newAt = ConvertTo-SummaryDate -Value $Run.finishedAt }
            $key = ConvertTo-SummaryPathKey -Path ([string]$Run.hostsPath)
            if ($key -and $newAt) {
                $oldAt = $null
                $old = $commits[$key]
                if ($old) { $oldAt = ConvertTo-SummaryDate -Value $old.at -AsUtc }
                $newUtc = ConvertTo-SummaryDate -Value $newAt -AsUtc
                if (-not $oldAt -or $newUtc -ge $oldAt) {
                    $commits[$key] = [pscustomobject]@{
                        runId     = $Run.runId
                        mode      = if ($CommitMode) { $CommitMode } else { $Run.mode }
                        hostsPath = $Run.hostsPath
                        at        = $newAt.ToString('o')
                    }
                }
            }
        }

        ($record | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding utf8
        return $true
    } catch {
        return $false
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
        $time = Format-SummaryLocalTime -Value $r.finishedAt
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
    }
    if ($commit) {
        $mode = if ($commit.mode -eq 'rollback') { '回滚' } else { '写入' }
        $time = Format-SummaryLocalTime -Value $commit.at
        $lastCommitText = "最近提交：$mode · $time"
    }

    return [pscustomobject]@{ LastRun = $lastRunText; LastCommit = $lastCommitText }
}
