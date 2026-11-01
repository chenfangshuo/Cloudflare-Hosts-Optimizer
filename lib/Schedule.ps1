#Requires -Version 7.0
<#
    计划任务：把「每 1–2 周重跑一次」变成任务计划程序里的一条每日间隔任务。

    约定：
      * 用 -Daily -DaysInterval 而不是 -Weekly：后者只能表达 7 的倍数。
      * 任务以当前用户身份 Interactive 运行；AutoApply 需要 Highest，注册时必须是管理员。
      * 显式设置电池/补跑/超时策略——New-ScheduledTaskSettingsSet 的默认值会让笔记本
        用电池时不跑、休眠错过就不补。
      * 覆盖已有任务需要 -TaskForce；不复用全局 -Force（那个是回滚/TUN 的语义）。
      * 只透传扫描类参数；-Force / -DropUnreachable / -Prune 永远不进任务。
#>

$script:DefaultTaskNames = @('Cloudflare-Hosts-Optimizer DryRun', 'Cloudflare-Hosts-Optimizer AutoApply')

# 允许从 -InstallTask 透传到任务命令行的参数。故意不包含 -Force/-DropUnreachable/-Prune。
$script:TaskPassThroughParams = @(
    'NoCfst', 'ExperimentalRanges', 'NoColoCache', 'ColoCachePath', 'ColoCacheMaxAgeDays',
    'TopN', 'CandidatesPerDomain', 'BackfillCandidates', 'MaxDomainProbes', 'VerifyTimeoutSec',
    'MinImprovementPct', 'MinImprovementMs', 'DomainsFile', 'CfstPath', 'SpeedTestUrl', 'ProbeUrl',
    'ScanSamples', 'MaxCandidates', 'ThroughputCandidates', 'ThroughputSamples', 'ThroughputBytes',
    'RefineTop', 'VerifyDelayMs', 'CheckResolved'
)

function Get-OptimizerPwshPath {
    [CmdletBinding()]
    param()
    # [Environment]::ProcessPath 从 .NET 6 才有；PowerShell 7.0 上访问会抛错。
    $p = ''
    try { $p = [Environment]::ProcessPath } catch { $p = '' }
    if ($p -and (Test-Path -LiteralPath $p) -and ([IO.Path]::GetFileName($p) -match '^pwsh(-preview)?\.exe$')) {
        return $p
    }
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $candidates = @()
    try { $candidates += Join-Path $PSHOME 'pwsh.exe' } catch { }
    if ($env:ProgramFiles) {
        $candidates += Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        $candidates += Join-Path $env:ProgramFiles 'PowerShell\7-preview\pwsh.exe'
    }
    if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe' }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw '找不到 pwsh.exe。请用 PowerShell 7 运行本脚本。'
}

function Test-OptimizerTaskName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskName)
    if ([string]::IsNullOrWhiteSpace($TaskName)) { return '任务名不能为空。' }
    if ($TaskName.Length -gt 200) { return '任务名太长（最多 200 个字符）。' }
    # 反斜杠会创建任务文件夹，其余是任务计划程序的保留字符
    if ($TaskName -match '[\\/:*?"<>|]') { return '任务名不能包含这些字符：\ / : * ? " < > |' }
    return ''
}

# 纯函数：把参数整理成一条可以交给 Register-ScheduledTask 的任务描述。
function New-OptimizerTaskSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [ValidateSet('DryRun', 'AutoApply')][string]$Mode = 'DryRun',
        [ValidateRange(1, 30)][int]$IntervalDays = 14,
        [string]$At,
        [string]$PwshPath,
        [string]$ReportPath,
        [string]$TaskName,
        [hashtable]$ExtraParameters = @{}
    )

    if (-not $At) { $At = if ($Mode -eq 'AutoApply') { '04:00' } else { '10:00' } }
    $time = [datetime]::ParseExact($At, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)

    if (-not $TaskName) { $TaskName = "Cloudflare-Hosts-Optimizer $Mode" }
    $nameError = Test-OptimizerTaskName -TaskName $TaskName
    if ($nameError) { throw $nameError }

    $script = Join-Path $Root 'Cloudflare-Hosts-Optimizer.ps1'
    if (-not (Test-Path -LiteralPath $script)) { throw "找不到脚本：$script" }
    if (-not $PwshPath) { $PwshPath = Get-OptimizerPwshPath }
    if ($PwshPath -match '"') { throw 'pwsh 路径不能包含双引号。' }
    if (-not $ReportPath) { $ReportPath = Join-Path $Root 'last-report.txt' }
    foreach ($p in @($script, $ReportPath)) {
        if ($p -match '"') { throw "路径不能包含双引号：$p" }
    }

    $argList = [System.Collections.Generic.List[string]]::new()
    foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script))) { $argList.Add($a) }
    if ($Mode -eq 'DryRun') { $argList.Add('-DryRun') }
    $argList.Add('-ReportPath')
    $argList.Add(('"{0}"' -f $ReportPath))

    foreach ($k in @($ExtraParameters.Keys | Sort-Object)) {
        $v = $ExtraParameters[$k]
        if ($null -eq $v) { continue }
        if ($v -is [System.Management.Automation.SwitchParameter]) {
            if ($v.IsPresent) { $argList.Add("-$k") }
            continue
        }
        if ($v -is [bool]) {
            if ($v) { $argList.Add("-$k") }
            continue
        }
        if ($v -is [array]) {
            throw "参数 -$k 是数组，不能写进计划任务；请改用 -DomainsFile。"
        }
        $text = [string]$v
        if ($text -match '"') { throw "参数 -$k 的值不能包含双引号。" }
        $argList.Add("-$k")
        $argList.Add(('"{0}"' -f $text))
    }

    return [pscustomobject]@{
        TaskName         = $TaskName
        Mode             = $Mode
        IntervalDays     = $IntervalDays
        At               = $time.ToString('HH:mm')
        PwshPath         = $PwshPath
        ScriptPath       = $script
        ReportPath       = $ReportPath
        WorkingDirectory = $Root
        Execute          = $PwshPath
        Arguments        = ($argList -join ' ')
        RequiresAdmin    = ($Mode -eq 'AutoApply')
    }
}

function Install-OptimizerTask {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Spec,
        [switch]$TaskForce
    )
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw '当前系统缺少 ScheduledTasks 模块，无法注册计划任务。'
    }
    $existing = @(Get-ScheduledTask -TaskName $Spec.TaskName -TaskPath '\' -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0 -and -not $TaskForce) {
        throw "任务已存在：$($Spec.TaskName)。确认要覆盖时加 -TaskForce。"
    }

    $action = New-ScheduledTaskAction -Execute $Spec.Execute -Argument $Spec.Arguments -WorkingDirectory $Spec.WorkingDirectory
    $start = [datetime]::Today.Add([TimeSpan]::Parse($Spec.At))
    if ($start -le (Get-Date)) { $start = $start.AddDays(1) }
    $trigger = New-ScheduledTaskTrigger -Daily -DaysInterval $Spec.IntervalDays -At $start

    # 默认设置会禁用电池启动、休眠错过不补跑；这里显式改掉
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive -RunLevel $(if ($Spec.Mode -eq 'AutoApply') { 'Highest' } else { 'Limited' })

    $register = @{
        TaskName    = $Spec.TaskName
        TaskPath    = '\'
        Action      = $action
        Trigger     = $trigger
        Settings    = $settings
        Principal   = $principal
        Description = "Cloudflare-Hosts-Optimizer 每 $($Spec.IntervalDays) 天自动运行（$($Spec.Mode)）"
    }
    if ($TaskForce) { $register['Force'] = $true }

    if ($PSCmdlet.ShouldProcess($Spec.TaskName, '注册计划任务')) {
        Register-ScheduledTask @register | Out-Null
    }
    return $Spec
}

# 返回每一项 { TaskName; Removed; Detail }；不存在视为成功。
function Uninstall-OptimizerTask {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$TaskName)
    if (-not $TaskName -or @($TaskName).Count -eq 0) { $TaskName = $script:DefaultTaskNames }
    if (-not (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw '当前系统缺少 ScheduledTasks 模块，无法删除计划任务。'
    }
    $rows = foreach ($n in @($TaskName)) {
        $exists = @(Get-ScheduledTask -TaskName $n -TaskPath '\' -ErrorAction SilentlyContinue).Count -gt 0
        if (-not $exists) {
            [pscustomobject]@{ TaskName = $n; Removed = $true; Detail = '不存在（无需删除）' }
            continue
        }
        $removed = $false
        $detail = ''
        if ($PSCmdlet.ShouldProcess($n, '删除计划任务')) {
            try {
                Unregister-ScheduledTask -TaskName $n -TaskPath '\' -Confirm:$false -ErrorAction Stop
                $removed = $true
                $detail = '已删除'
            } catch {
                $detail = $_.Exception.Message
            }
        } else {
            $removed = $true
            $detail = '将删除（-WhatIf）'
        }
        [pscustomobject]@{ TaskName = $n; Removed = $removed; Detail = $detail }
    }
    return @($rows)
}
