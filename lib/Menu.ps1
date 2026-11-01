#Requires -Version 7.0
<#
    菜单的纯逻辑：动作定义、状态汇总、域名总览。
    Menu.ps1 只负责显示、读输入和调用子进程；这里不执行任何命令、不联网。
#>

function New-MenuSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Kind,
        [string[]]$Arguments = @(),
        [switch]$RequiresAdmin,
        [switch]$Confirm,
        [string]$InputKind = 'None',
        [string]$Target = '',
        [string]$Source = '',
        [string]$Method = ''
    )
    [pscustomobject]@{
        Key           = $Key
        Label         = $Label
        Kind          = $Kind
        Arguments     = @($Arguments)
        RequiresAdmin = [bool]$RequiresAdmin
        Confirm       = [bool]$Confirm
        InputKind     = $InputKind
        Target        = $Target
        Source        = $Source
        Method        = $Method
    }
}

function Get-MenuItems {
    [CmdletBinding()]
    param([ValidateSet('Main', 'Import', 'Cfst', 'Task')][string]$Menu = 'Main')

    switch ($Menu) {
        'Main' {
            return @(
                (New-MenuSpec '1' '导入 / 编辑域名' 'Submenu' -Target 'Import'),
                (New-MenuSpec '2' '查看域名（列表与已写入）' 'DomainOverview'),
                (New-MenuSpec '3' '下载 / 更新 CFST' 'Submenu' -Target 'Cfst'),
                (New-MenuSpec '4' '定时任务' 'Submenu' -Target 'Task'),
                (New-MenuSpec '5' '查看上次报告' 'ViewReport'),
                (New-MenuSpec '6' '打开 README' 'OpenReadme'),
                (New-MenuSpec '7' '环境自检 (Doctor)' 'Script' @('-Doctor')),
                (New-MenuSpec '8' '只看结果 (DryRun，不改 hosts)' 'Script' @('-DryRun')),
                (New-MenuSpec '9' '正式写入 hosts' 'Script' -RequiresAdmin -Confirm),
                (New-MenuSpec '10' '回滚到上次备份' 'Script' @('-Rollback') -RequiresAdmin -Confirm),
                (New-MenuSpec '0' '退出' 'Exit')
            )
        }
        'Import' {
            return @(
                (New-MenuSpec '1' 'PT-Depiler 备份文件' 'Import' -Source 'Depiler' -InputKind 'Path'),
                (New-MenuSpec '2' 'Windows 代理旁路列表' 'Import' -Source 'ProxyBypass'),
                (New-MenuSpec '3' '从文本文件提取域名' 'Import' -Source 'Text' -InputKind 'Path'),
                (New-MenuSpec '4' '从剪贴板提取域名' 'Import' -Source 'Clipboard'),
                (New-MenuSpec '5' '手动编辑 domains.txt（记事本）' 'EditDomains'),
                (New-MenuSpec '0' '返回' 'Back')
            )
        }
        'Cfst' {
            return @(
                (New-MenuSpec '1' '直连 GitHub 下载' 'InstallCfst' -Method 'Direct'),
                (New-MenuSpec '2' '通过系统代理下载' 'InstallCfst' -Method 'Proxy'),
                (New-MenuSpec '3' '打开蓝奏云下载页（手动下载）' 'OpenUrl' -Target 'https://xiu.lanzoub.com/b0742hkxe'),
                (New-MenuSpec '4' '从本地 zip 安装' 'InstallCfst' -Method 'File' -InputKind 'Path'),
                (New-MenuSpec '0' '返回' 'Back')
            )
        }
        'Task' {
            return @(
                (New-MenuSpec '1' '安装 DryRun 定时任务（不写 hosts）' 'Script' @('-InstallTask', '-TaskMode', 'DryRun')),
                (New-MenuSpec '2' '安装 AutoApply 定时任务（自动写入）' 'Script' @('-InstallTask', '-TaskMode', 'AutoApply') -RequiresAdmin -Confirm),
                (New-MenuSpec '3' '卸载定时任务' 'Script' @('-UninstallTask')),
                (New-MenuSpec '0' '返回' 'Back')
            )
        }
    }
}

function Get-MenuActionSpec {
    [CmdletBinding()]
    param(
        [ValidateSet('Main', 'Import', 'Cfst', 'Task')][string]$Menu = 'Main',
        [AllowEmptyString()][string]$Key = ''
    )
    $k = if ($Key) { $Key.Trim().ToLowerInvariant() } else { '' }
    if (-not $k) { return $null }
    return @(Get-MenuItems -Menu $Menu | Where-Object { $_.Key -eq $k })[0]
}

# 菜单初始焦点：
#   * 首次打开：没有域名停在“导入”，已有域名停在“DryRun”（不是正式写入）；
#   * 执行动作或从子菜单返回：停在“退出”，避免连续按 Enter 重复启动扫描。
function Get-MenuInitialIndex {
    [CmdletBinding()]
    param(
        [ValidateSet('Main', 'Import', 'Cfst', 'Task')][string]$Menu = 'Main',
        [int]$DomainCount = 0,
        [switch]$Returning
    )
    $items = @(Get-MenuItems -Menu $Menu)
    if ($Menu -eq 'Main') {
        $key = if ($Returning) { '0' } elseif ($DomainCount -gt 0) { '8' } else { '1' }
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ($items[$i].Key -eq $key) { return $i }
        }
    }
    return 0
}

# 计划任务状态/安装参数/UAC 结果的纯展示逻辑（Menu.ps1 调用，便于测试）
function Get-TaskStatusLines {
    [CmdletBinding()]
    param($Info)
    if (-not $Info -or -not $Info.Available) { return @('任务状态：未知（缺少 ScheduledTasks 模块）') }
    if ($Info.QueryFailed) {
        $reason = ([string]$Info.Error).Trim()
        if ($reason.Length -gt 120) { $reason = $reason.Substring(0, 120) + '…' }
        return @("任务状态：未知（查询失败$(if ($reason) { "：$reason" })）")
    }
    if (@($Info.Tasks).Count -eq 0) { return @('已注册任务：无') }
    return @($Info.Tasks | ForEach-Object {
            $detail = "$($_.TaskName)：$($_.State)"
            if ($_.NextRun) { $detail += "，下次 $($_.NextRun)" }
            if ($_.LastRun) { $detail += "，上次 $($_.LastRun)（结果 $($_.LastResult)）" }
            $detail
        })
}

# 查询计划任务；查询本身抛错时也返回一个可展示的对象，不能把异常抛进主菜单。
function Get-TaskMenuInfo {
    [CmdletBinding()]
    param([scriptblock]$Query)
    if (-not $Query) { $Query = { Get-ScheduledTaskDoctorInfo } }
    try {
        $info = & $Query
        if (-not $info) {
            return [pscustomobject]@{ Available = $true; QueryFailed = $true; Error = '查询没有返回结果'; Tasks = @() }
        }
        return [pscustomobject]@{
            Available   = [bool]$info.Available
            QueryFailed = [bool]$info.QueryFailed
            Error       = [string]$info.Error
            Tasks       = @($info.Tasks)
        }
    } catch {
        return [pscustomobject]@{ Available = $true; QueryFailed = $true; Error = $_.Exception.Message; Tasks = @() }
    }
}

# 安装任务前的确认文案。两种必要确认合并成一次提问：
#   * Required（AutoApply 的 Spec.Confirm）：允许安装会自动写入 hosts 的任务；
#   * TaskExists：允许覆盖已存在的同名任务。
# 两者都不满足时不会执行；查询失败（ExistsKnown=false）时按“不存在”处理，
# 不自动加 -TaskForce，也不要谎称没有任务。
function Get-TaskInstallPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [bool]$Required = $false,
        [bool]$TaskExists = $false,
        [bool]$ExistsKnown = $true
    )
    $auto = $Arguments -contains 'AutoApply'
    $name = if ($auto) { 'Cloudflare-Hosts-Optimizer AutoApply' } else { 'Cloudflare-Hosts-Optimizer DryRun' }
    $need = [bool]$Required -or [bool]$TaskExists
    $text = ''
    if ($TaskExists) {
        $text = if ($auto) { "覆盖已存在的任务「$name」（该任务会自动写入 hosts）" } else { "覆盖已存在的任务「$name」" }
    } elseif ($Required) {
        $text = "安装任务「$name」（会按计划自动写入 hosts）"
    }
    return [pscustomobject]@{
        NeedConfirm = $need
        Text        = $text
        TaskExists  = [bool]$TaskExists
        ExistsKnown = [bool]$ExistsKnown
        AutoApply   = [bool]$auto
    }
}

# 安装任务前决定参数：任务已存在但用户取消 → 返回 $null（不执行）；
# 确认覆盖 → 追加 -TaskForce。
function Get-TaskInstallPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [bool]$TaskExists = $false,
        [bool]$Confirmed = $false
    )
    if ($TaskExists -and -not $Confirmed) { return $null }
    $args = @($Arguments)
    if ($TaskExists) { $args += '-TaskForce' }
    return [pscustomobject]@{ Arguments = $args }
}

function Format-ElevatedResult {
    [CmdletBinding()]
    param(
        [System.Nullable[int]]$ExitCode,
        [bool]$Cancelled = $false
    )
    if ($Cancelled) { return '已取消提权，可重新选择 9/10 再试。' }
    if ($null -eq $ExitCode) { return '' }
    if ($ExitCode -eq 0) { return '管理员窗口已结束（退出码 0）。' }
    return "管理员窗口已结束（退出码 $ExitCode），请查看报告或重试。"
}

# 提权子窗口的命令行。用显式 -Elevated 开关：正式写入没有参数，不能靠
# "-ElevatedArgs 非空" 来判断。
function New-ElevatedArgumentLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MenuScript,
        [AllowEmptyCollection()][string[]]$Arguments = @()
    )
    $joined = ($Arguments -join ' ')
    return '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Elevated -ElevatedArgs "{1}"' -f $MenuScript, $joined
}

# 生成一屏文字；每项前面显示序号（1-9 可直达）。选中样式由 Menu.ps1 负责。
function Format-MenuFrame {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Header = @(),
        [Parameter(Mandatory)]$Items,
        [AllowEmptyString()][string]$Footer = ''
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($h in $Header) { $lines.Add($h) }
    $lines.Add('')
    foreach ($item in @($Items)) {
        $lines.Add(('{0,2}) {1}' -f $item.Key, $item.Label))
    }
    if ($Footer) {
        $lines.Add('')
        $lines.Add($Footer)
    }
    return @($lines)
}

# 域名总览：domains.txt 的列表、hosts 托管区块里的映射、两边差集。
function Get-DomainOverview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DomainsFile,
        [Parameter(Mandatory)][string]$HostsPath
    )
    $listed = @()
    $invalid = @()
    $invalidItems = @()
    $listedError = ''
    if (Test-Path -LiteralPath $DomainsFile) {
        try {
            $res = Read-DomainsFile -Path $DomainsFile
            $listed = @($res.Domains)
            $invalid = @($res.Invalid)
            $invalidItems = @($res.InvalidItems)
        } catch {
            $listedError = $_.Exception.Message
        }
    }

    $managed = [ordered]@{}
    $hostsError = ''
    try {
        $doc = Read-HostsDocument -Path $HostsPath
        $lines = @($doc.Text -split "`r?`n")
        $block = Get-HostsBlockInfo -Lines $lines
        $map = Get-HostsBlockMap -Lines $lines -BlockInfo $block
        foreach ($k in $map.Keys) { $managed[$k] = @($map[$k]) }
    } catch {
        $hostsError = $_.Exception.Message
    }

    $listedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $listed) { [void]$listedSet.Add($d) }
    $managedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $managed.Keys) { [void]$managedSet.Add($k) }

    [pscustomobject]@{
        DomainsFile  = $DomainsFile
        Listed       = @($listed)
        Invalid      = @($invalid)
        InvalidItems = @($invalidItems)
        ListedError  = $listedError
        Managed      = $managed
        HostsError   = $hostsError
        OnlyListed   = @($listed | Where-Object { -not $managedSet.Contains($_) })
        OnlyManaged  = @($managed.Keys | Where-Object { -not $listedSet.Contains($_) })
    }
}

# 菜单状态栏用的轻量汇总。只读本地文件，不执行 cfst.exe、不联网。
function Get-MenuStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DomainsFile,
        [Parameter(Mandatory)][string]$HostsPath,
        [Parameter(Mandatory)][string]$CfstDir,
        [string]$ReportPath
    )
    $listed = 0
    $invalid = 0
    if (Test-Path -LiteralPath $DomainsFile) {
        try {
            $r = Read-DomainsFile -Path $DomainsFile
            $listed = @($r.Domains).Count
            $invalid = @($r.Invalid).Count
        } catch { }
    }

    $managed = 0
    $hostsError = ''
    try {
        $doc = Read-HostsDocument -Path $HostsPath
        $lines = @($doc.Text -split "`r?`n")
        $block = Get-HostsBlockInfo -Lines $lines
        $map = Get-HostsBlockMap -Lines $lines -BlockInfo $block
        $managed = @($map.Keys).Count
    } catch {
        $hostsError = $_.Exception.Message
    }

    $exe = Join-Path $CfstDir 'cfst.exe'
    $ip = Join-Path $CfstDir 'ip.txt'
    $cfst = if ((Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $ip)) { '已安装' }
            elseif (Test-Path -LiteralPath $exe) { '缺少 ip.txt' }
            else { '未安装' }

    $lastRun = ''
    if ($ReportPath -and (Test-Path -LiteralPath $ReportPath)) {
        $lastRun = (Get-Item -LiteralPath $ReportPath).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
    }

    [pscustomobject]@{
        Listed = $listed; Invalid = $invalid; Managed = $managed
        HostsError = $hostsError; Cfst = $cfst; LastRun = $lastRun
    }
}
