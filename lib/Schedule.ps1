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

# 按 Windows 命令行（CommandLineToArgvW）规则给一个参数加引号：
# 只有含空白或引号时才加；引号前的反斜杠翻倍；引号内末尾的反斜杠也要翻倍。
# 计划任务的 Arguments 是一整条字符串，手写 '{0}' 会在 D:\cfst\ 这类路径上
# 把闭合引号转义掉，任务运行时拿到错误路径。
function ConvertTo-NativeArgument {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }

    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('"')
    $i = 0
    while ($i -lt $Value.Length) {
        $backslashes = 0
        while ($i -lt $Value.Length -and $Value[$i] -eq [char]'\') {
            $backslashes++
            $i++
        }
        if ($i -eq $Value.Length) {
            # 末尾反斜杠：后面跟着闭合引号，必须翻倍
            [void]$sb.Append([char]'\', $backslashes * 2)
        } elseif ($Value[$i] -eq [char]'"') {
            [void]$sb.Append([char]'\', $backslashes * 2 + 1)
            [void]$sb.Append([char]'"')
            $i++
        } else {
            [void]$sb.Append([char]'\', $backslashes)
            [void]$sb.Append($Value[$i])
            $i++
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
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
    foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass')) { $argList.Add($a) }
    $argList.Add('-File')
    $argList.Add((ConvertTo-NativeArgument -Value $script))
    if ($Mode -eq 'DryRun') { $argList.Add('-DryRun') }
    $argList.Add('-ReportPath')
    $argList.Add((ConvertTo-NativeArgument -Value $ReportPath))

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
        $argList.Add("-$k")
        $argList.Add((ConvertTo-NativeArgument -Value $text))
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

# 判断 pwsh 这次到底用什么入口。只接受本工具实际生成的宿主前缀形状：
#   [-NoProfile|-NoLogo|-NonInteractive|-ExecutionPolicy <值>|-WindowStyle <值>]... -File <脚本>
# 锚定失败（-Command/-EncodedCommand、隐式 .ps1、未知开关）一律判为“不是本工具”，
# 不会把后面别的工具的 -File 当成宿主入口。目标 token 必须有结束边界，
# 避免 "x.ps1".other.ps1 这种 native argv 拼接被截断误认。
function Get-PwshEntryTarget {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Arguments)
    $pattern = '^\s*(?:(?:-NoProfile|-NoLogo|-NonInteractive)\s+|' +
        '-(?:ExecutionPolicy|WindowStyle)\s+(?:"[^"]*"|\S+)\s+)*' +
        '-(?:File|F)\s+(?:"([^"]+)"|([^"\s]+))(?=\s|$)'
    $m = [regex]::Match($Arguments, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return [pscustomobject]@{ Mode = 'Unknown'; Target = '' } }
    $target = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
    return [pscustomobject]@{ Mode = 'File'; Target = $target }
}

# 判断一个已存在的任务是不是本工具注册的：动作必须是 pwsh + 本脚本。
# 只按名字删太危险——同名任务可能属于别的工具，而 Get/Unregister-ScheduledTask
# 的 -TaskName 支持通配符，'*' 会波及根目录下的所有任务。
function Test-OptimizerTaskOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$ScriptPath
    )
    $actions = @($Task.Actions)
    if ($actions.Count -eq 0) { return $false }
    $scriptName = [IO.Path]::GetFileName($ScriptPath)
    $expectedName = if ($scriptName) { $scriptName } else { 'Cloudflare-Hosts-Optimizer.ps1' }
    foreach ($a in $actions) {
        $exe = ([string]$a.Execute).Trim('"')
        $argText = [string]$a.Arguments
        if (-not $exe -or $exe -notmatch '(?i)(^|\\)pwsh(-preview)?\.exe$') { return $false }
        if (-not $argText) { return $false }
        # 只认宿主实际选择的 -File 入口；-Command/-EncodedCommand 一律不算（内容里的 -File 不是入口）
        $entry = Get-PwshEntryTarget -Arguments $argText
        if ($entry.Mode -ne 'File' -or -not $entry.Target) { return $false }
        # 只比文件名：仓库整体搬目录后，旧任务仍然应该删得掉
        if ([IO.Path]::GetFileName($entry.Target) -ne $expectedName) { return $false }
    }
    return $true
}

# 删除单个任务对象。单独一层是为了让测试能替换掉原生命令：
# Unregister-ScheduledTask 的 -InputObject 参数类型是 CimInstance[]，
# 伪造对象在 Pester 的 mock 代理里会在绑定阶段就失败。
function Remove-OptimizerTask {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Task)
    if ($PSCmdlet.ShouldProcess($Task.TaskName, '删除计划任务')) {
        Unregister-ScheduledTask -InputObject $Task -Confirm:$false -ErrorAction Stop
    }
}

# 返回每一项 { TaskName; Removed; Detail }；不存在视为成功。
function Uninstall-OptimizerTask {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$TaskName,
        [string]$ScriptPath
    )
    if (-not $TaskName -or @($TaskName).Count -eq 0) { $TaskName = $script:DefaultTaskNames }
    if (-not (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw '当前系统缺少 ScheduledTasks 模块，无法删除计划任务。'
    }
    if (-not $ScriptPath) {
        $root = if ($script:RepoRoot) { $script:RepoRoot } else { Split-Path -Parent $PSScriptRoot }
        $ScriptPath = Join-Path $root 'Cloudflare-Hosts-Optimizer.ps1'
    }

    # 先校验全部名字，再开始删除：不能删掉第一个之后才发现第二个非法
    foreach ($n in @($TaskName)) {
        $nameError = Test-OptimizerTaskName -TaskName $n
        if ($nameError) { throw "任务名无效「$n」：$nameError" }
    }

    $rows = foreach ($n in @($TaskName)) {
        # 不用 -TaskName $n 直接查询/删除：原生命令会按通配符解释。
        $matches = @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue |
                Where-Object { $_.TaskName -eq $n })
        if ($matches.Count -eq 0) {
            [pscustomobject]@{ TaskName = $n; Removed = $true; Detail = '不存在（无需删除）' }
            continue
        }
        $ours = @($matches | Where-Object { Test-OptimizerTaskOwnership -Task $_ -ScriptPath $ScriptPath })
        if ($ours.Count -eq 0) {
            [pscustomobject]@{
                TaskName = $n; Removed = $false
                Detail = '同名任务不是本工具注册的（动作里没有本脚本），已跳过'
            }
            continue
        }
        $removed = $false
        $detail = ''
        try {
            Remove-OptimizerTask -Task $ours[0]
            $removed = $true
            $detail = if ($WhatIfPreference) { '将删除（-WhatIf）' } else { '已删除' }
        } catch {
            $detail = $_.Exception.Message
        }
        [pscustomobject]@{ TaskName = $n; Removed = $removed; Detail = $detail }
    }
    return @($rows)
}
