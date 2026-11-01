#Requires -Version 7.0
<#
.SYNOPSIS
    优选 Cloudflare 边缘 IP 并写入 Windows hosts（适用于 PT 站等 CF 托管站点）。

.DESCRIPTION
    流程：CFST 全量测延迟/丢包 -> 延迟预筛 -> 探测机房并分层抽样
          -> 独立吞吐初测 -> 决赛（3x2MB，串行）-> 逐域名 HEAD 验证
          -> 严格解析 hosts -> 增量合并 -> 备份 -> 原子替换 -> 刷新 DNS。

    安全约束：
      * 标记结构异常、编码无法识别、存在多别名/IPv6 冲突时，直接拒绝改写。
      * 验证失败的域名默认保留上一次的映射；明确 1034/1003 才删除；
        只有 -Prune 才删除不在域名列表里的历史映射。
      * 只向测速地址做批量请求；对目标站只做少量 HEAD 探测
        （每域名典型 6-10 次，含基线、候选、旧映射和切换前复核）。
      * 不登录、不带 Cookie、不访问 announce URL。

.PARAMETER DryRun
    只扫描和验证，不修改 hosts。

.PARAMETER Plan
    不修改 hosts，生成机器可读的 JSON 计划（默认 .\plan.json），便于自动化和二次开发。

.PARAMETER PlanPath
    -Plan 的 JSON 输出路径。

.PARAMETER Rollback
    用最近一次备份恢复 hosts。可在 domains.txt 缺失时使用。

.PARAMETER RollbackFrom
    与 -Rollback 同用：恢复指定备份（hosts-*.bak 文件），而不是最近一次。
    只在最近一次备份已经写坏、需要退回更早状态时使用。

.PARAMETER AllowUntrustedBackup
    与 -Rollback 同用：允许使用“普通用户可改写”的目录/文件里的备份。
    系统 hosts 的自动回滚默认只信管理员/SYSTEM 独占写权限的备份；只有你确认某个
    旧备份内容可信、又需要人工恢复时才用这个开关。它不会绕过 manifest/preHash 校验。

.PARAMETER Version
    打印版本号并退出。

.PARAMETER Doctor
    只读自检：检查 PowerShell/curl、hosts 结构与编码、域名文件、CFST、探测与测速端点、
    代理与 TUN、备份目录、机房缓存和已注册的计划任务，然后退出。
    不写 hosts、不需要管理员；只向 Cloudflare 公共端点发少量请求，不访问目标站点。
    有失败项时退出码为 1。

.PARAMETER InstallTask
    注册计划任务并退出。默认注册 DryRun 任务（只生成报告、不写 hosts、不需要管理员）；
    AutoApply 需要管理员。任务每 -TaskIntervalDays 天在 -TaskAt 运行一次。

.PARAMETER UninstallTask
    删除计划任务并退出。不带 -TaskName 时删除两个默认任务（DryRun/AutoApply）。

.PARAMETER TaskMode
    计划任务模式：DryRun（默认）或 AutoApply（自动写入 hosts，需要管理员）。

.PARAMETER TaskIntervalDays
    计划任务的间隔天数（1-30，默认 14）。

.PARAMETER TaskAt
    计划任务的运行时间（24 小时 HH:mm）。默认 DryRun 10:00、AutoApply 04:00。

.PARAMETER TaskName
    自定义任务名；-UninstallTask 时也可以只删指定的一个。

.PARAMETER TaskForce
    覆盖已存在的同名计划任务。与全局 -Force 无关。

.PARAMETER NoCfst
    不使用 cfst.exe，改用内置扫描（从 Cloudflare 官方 IPv4 段随机抽样）。

.PARAMETER Force
    与 -Rollback 同用时允许覆盖写入后被其他程序修改过的 hosts；
    与正常流程同用时允许在检测到 TUN 网卡后继续。

.PARAMETER Prune
    删除不再出现在 domains.txt 中的历史托管映射（默认保留）。

.PARAMETER CheckResolved
    写入后解析每个域名，报告系统实际返回的地址（用于核对是否走 IPv4）。

.PARAMETER ExperimentalRanges
    允许扫描 CF 官方列表之外的实验网段（104.28.0.0/14）。

.PARAMETER NoColoCache
    不使用上次的机房缓存，每次都探测全部候选（默认使用缓存，最长 14 天）。

.PARAMETER ColoCachePath
    机房缓存文件路径，默认 %LOCALAPPDATA%\Cloudflare-Hosts-Optimizer\colo-cache.json。

.PARAMETER ColoCacheMaxAgeDays
    机房缓存的有效天数（0-365，默认 14）。0 表示不使用缓存。

.PARAMETER TopN
    每个域名写入的 IP 数（1-3，默认 1）。hosts 不保证多行之间的故障转移。

.PARAMETER CandidatesPerDomain
    每个域名参与对比的全局候选数（1-5，默认 3）。

.PARAMETER BackfillCandidates
    前几个全局候选都不可用时，补测的候选数（0-5，默认 1）。

.PARAMETER MaxDomainProbes
    每个域名的候选探测硬上限（1-16，默认 6）；不含基线和 DNS 回退。

.PARAMETER VerifyTimeoutSec
    单次域名验证超时（秒，2-15，默认 5）。

.PARAMETER MinImprovementPct
    候选相对基线至少快多少百分比才切换（0-100，默认 15）。

.PARAMETER MinImprovementMs
    切换所需的绝对改善下限（毫秒，默认 30）。基线很快时，15% 可能只有十几毫秒，
    落在测量噪声里；两个门槛都满足才切换。

.PARAMETER DropUnreachable
    旧映射连接失败时也删除。默认保留并告警；明确 1034/1003 始终自动删除。

.PARAMETER Domains
    域名列表，优先于 -DomainsFile。

.PARAMETER DomainsFile
    域名文件，默认 .\domains.txt。

.PARAMETER CfstPath
    cfst.exe 路径；不提供则自动查找 .\cfst\cfst.exe。

.PARAMETER SpeedTestUrl
    吞吐测速地址，支持 {bytes} 占位符。必须是 https，且由 Cloudflare 托管。

.PARAMETER ProbeUrl
    延迟扫描和机房探测使用的 cdn-cgi/trace 地址（默认 speed.cloudflare.com）。
    只允许 https，且必须是 Cloudflare 托管的站点。显式指定后不会自动回退到备用端点。

.PARAMETER HostsPath
    高级选项：hosts 文件路径，默认系统 hosts。用于测试/沙箱。

.PARAMETER ReportPath
    报告文件路径。默认正常运行时写 .\last-report.txt；-DryRun 默认不写。

.EXAMPLE
    .\Cloudflare-Hosts-Optimizer.ps1 -DryRun

.EXAMPLE
    .\Cloudflare-Hosts-Optimizer.ps1

.EXAMPLE
    .\Cloudflare-Hosts-Optimizer.ps1 -Rollback

.EXAMPLE
    .\Cloudflare-Hosts-Optimizer.ps1 -Prune -TopN 1
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Plan,
    [switch]$Rollback,
    [string]$RollbackFrom,
    [switch]$Version,
    [switch]$Doctor,
    [switch]$InstallTask,
    [switch]$UninstallTask,
    [ValidateSet('DryRun', 'AutoApply')][string]$TaskMode = 'DryRun',
    [ValidateRange(1, 30)][int]$TaskIntervalDays = 14,
    [string]$TaskAt,
    [string]$TaskName,
    [switch]$TaskForce,
    [switch]$NoCfst,
    [switch]$Force,
    [switch]$Prune,
    [switch]$CheckResolved,
    [switch]$ExperimentalRanges,
    [switch]$DropUnreachable,
    [switch]$NoColoCache,
    [string]$ColoCachePath,
    [ValidateRange(0, 365)][int]$ColoCacheMaxAgeDays = 14,
    [ValidateRange(1, 3)][int]$TopN = 1,
    [ValidateRange(1, 5)][int]$CandidatesPerDomain = 3,
    [ValidateRange(0, 5)][int]$BackfillCandidates = 1,
    [ValidateRange(1, 16)][int]$MaxDomainProbes = 6,
    [ValidateRange(2, 15)][int]$VerifyTimeoutSec = 5,
    [ValidateRange(0, 100)][int]$MinImprovementPct = 15,
    [ValidateRange(0, 5000)][int]$MinImprovementMs = 30,
    [string[]]$Domains,
    [string]$DomainsFile,
    [string]$CfstPath,
    [string]$SpeedTestUrl = 'https://speed.cloudflare.com/__down?bytes={bytes}',
    [string]$ProbeUrl,
    [string]$HostsPath,
    [string]$ReportPath,
    [string]$PlanPath,
    [switch]$AllowUntrustedBackup,
    [ValidateRange(1, 5)][int]$ScanSamples = 2,
    [ValidateRange(16, 512)][int]$MaxCandidates = 192,
    [ValidateRange(4, 64)][int]$ThroughputCandidates = 32,
    [ValidateRange(1, 3)][int]$ThroughputSamples = 1,
    [ValidateRange(500000, 20000000)][int]$ThroughputBytes = 1000000,
    [ValidateRange(1, 16)][int]$RefineTop = 6,
    [ValidateRange(0, 5000)][int]$VerifyDelayMs = 400
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '0.5.6'
# 脚本级参数在 Invoke-Main 里取不到 $PSBoundParameters，提前记下来：
# 用户显式给的 -ProbeUrl 失败时不自动回退到备用端点；-InstallTask 用它决定透传哪些参数。
$script:ScriptBoundParameters = @{}
foreach ($k in $PSBoundParameters.Keys) { $script:ScriptBoundParameters[$k] = $PSBoundParameters[$k] }
$script:ProbeUrlExplicit = $PSBoundParameters.ContainsKey('ProbeUrl')

# -Version 放在加载 lib 之前，库缺失/损坏时也能用
if ($Version) {
    [Console]::Out.WriteLine("Cloudflare-Hosts-Optimizer $ScriptVersion")
    exit 0
}

$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:RepoRoot = $Root

. (Join-Path $Root 'lib\Safety.ps1')
. (Join-Path $Root 'lib\Domains.ps1')
. (Join-Path $Root 'lib\HostsFile.ps1')
. (Join-Path $Root 'lib\Probe.ps1')
. (Join-Path $Root 'lib\Endpoint.ps1')
. (Join-Path $Root 'lib\Doctor.ps1')
. (Join-Path $Root 'lib\Schedule.ps1')
. (Join-Path $Root 'lib\Progress.ps1')
. (Join-Path $Root 'lib\RunSummary.ps1')

$script:Log = [System.Collections.Generic.List[string]]::new()
$script:FailCode = 0

function Say {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-StatusLine -Text $Text -Color $Color
    $script:Log.Add($Text)
}

function Fail {
    param([string]$Message, [int]$Code = 1)
    # 先收掉动画行，错误信息才不会被转轮压住
    Stop-TaskSpinner
    $script:FailCode = $Code
    throw $Message
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '需要管理员权限。请右键 PowerShell 7 -> 以管理员身份运行，再执行本脚本。'
    }
}

# 只有目标是系统 hosts 时才需要管理员；-HostsPath 指向临时文件时不需要
function Assert-AdminForPath {
    param([string]$Path)
    $systemHosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if ([IO.Path]::GetFullPath($Path) -ieq [IO.Path]::GetFullPath($systemHosts)) {
        Assert-Admin
    }
}

function Get-ProxyState {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $v = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    if (-not $v) { return [pscustomobject]@{ Enabled = $false; Server = ''; Bypass = '' } }
    return [pscustomobject]@{
        Enabled = ($v.ProxyEnable -eq 1)
        Server  = [string]$v.ProxyServer
        Bypass  = [string]$v.ProxyOverride
    }
}

function Show-ProxyCheck {
    param([string[]]$TargetDomains)
    $p = Get-ProxyState
    if (-not $p.Enabled) {
        Say '代理：未启用 WinINET 系统代理' 'Gray'
        Say '不排除 PAC / TUN / 应用级代理。' 'DarkGray'
        return
    }
    Say "代理：已开启（WinINET $($p.Server)）" 'Gray'
    Say '浏览器等 WinINET 程序走它；本工具的探测和测速带 --noproxy，不走它。' 'DarkGray'
    Say 'TUN / WFP / PAC 这类透明转发不受 --noproxy 影响，见下面的网卡检查。' 'DarkGray'

    $missing = @($TargetDomains | Where-Object { -not (Test-BypassStrict -Domain $_ -Bypass $p.Bypass) })
    if ($missing.Count -eq 0) {
        Say '旁路：目标域名都在 ProxyOverride 中' 'Gray'
        Say '浏览器开着代理时也会直连，hosts 映射可以生效。' 'DarkGray'
    } else {
        Say ("旁路：{0} 个域名不在 ProxyOverride" -f $missing.Count) 'Yellow'
        Say '浏览器开着代理时，这些域名可能不走 hosts；本工具的测速不受影响。' 'DarkGray'
        foreach ($m in $missing) { Say "- $m" 'Yellow' }
    }
}

function Get-TunAdapters {
    # 返回已启用的已知 TUN 虚拟网卡；缺少 NetAdapter 模块时返回 $null（与"没有 TUN"区分）
    if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) { return $null }
    # 前置逗号：空数组直接输出会被折叠成 $null，和"模块缺失"混淆
    return , @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'TAP|TUN|Wintun|WireGuard|Tailscale|Clash|Mihomo'
        })
}

function Test-TunAdapter {
    $tun = Get-TunAdapters
    if ($null -eq $tun) {
        Say '网卡：缺少 NetAdapter 模块，跳过 TUN 检测' 'Yellow'
        return $false
    }
    if ($tun.Count -gt 0) {
        Say '网卡：检测到可能的 TUN 虚拟网卡' 'Red'
        Say 'TUN 会接管流量，--noproxy 绕不过；正式运行会中止，确认风险后加 -Force 继续。' 'DarkGray'
        foreach ($t in $tun) { Say "- $($t.Name) / $($t.InterfaceDescription)" 'Red' }
        return $true
    }
    Say '网卡：未发现已知 TUN 虚拟网卡' 'Gray'
    Say '只说明没有已知 TUN，不排除 WFP / 透明代理。' 'DarkGray'
    return $false
}

function Invoke-Doctor {
    # 只读自检：不写 hosts、不需要管理员；联网项只打 Cloudflare 公共端点。
    $checks = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Group, [string]$Name, [string]$Status, [string]$Detail)
        $checks.Add((New-DoctorCheck -Group $Group -Name $Name -Status $Status -Detail $Detail))
    }

    # ---- 环境 ----
    # 检查要跑几秒（端点、CFST -h），期间显示计时转轮；报告统一在最后分组打印
    Start-TaskSpinner
    $bits = if ([Environment]::Is64BitProcess) { '64 位' } else { '32 位' }
    & $add '环境' 'PowerShell' 'OK' ("{0}（{1}）" -f $PSVersionTable.PSVersion, $bits)

    $curlExe = $null
    try {
        $curlExe = Get-CurlExe
        $verLine = @(& $curlExe --version 2>$null | Select-Object -First 1)
        & $add '环境' 'curl.exe' 'OK' ("{0}；{1}" -f $curlExe, ($verLine -join ' '))
    } catch {
        & $add '环境' 'curl.exe' 'FAIL' $_.Exception.Message
    }

    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    & $add '环境' '管理员权限' 'OK' $(if ($isAdmin) {
            '当前是管理员；正式写入 hosts 可用。'
        } else {
            '当前不是管理员；-Doctor/-DryRun/-Plan 不需要，正式写入 hosts 时才需要。'
        })

    # ---- hosts ----
    $doctorHostsPath = if ($HostsPath) { $HostsPath } else { Join-Path $env:SystemRoot 'System32\drivers\etc\hosts' }
    $hostsInfo = Get-HostsDoctorInfo -HostsPath $doctorHostsPath
    if ($hostsInfo.Error) {
        & $add 'hosts' '文件与结构' 'FAIL' $hostsInfo.Error
    } elseif ($hostsInfo.Conflicts.Count -gt 0) {
        $detail = ($hostsInfo.Conflicts | ForEach-Object {
                "第 $($_.Line) 行 [$($_.Reason)]：$($_.Hosts)"
            }) -join '；'
        & $add 'hosts' '区块外冲突' 'FAIL' "正式运行会因此中止且不改写：$detail"
    } else {
        $blockText = if ($hostsInfo.HasBlock) { "有（受管域名 $($hostsInfo.ManagedCount) 个）" } else { '无（下次运行会新建）' }
        & $add 'hosts' '文件与结构' 'OK' ("{0}；编码 {1}；托管区块：{2}" -f $doctorHostsPath, $hostsInfo.Encoding, $blockText)
    }

    # ---- 域名 ----
    $domainsFileResolved = if ($DomainsFile) { $DomainsFile } else { Join-Path $Root 'domains.txt' }
    $domainList = @()
    if ($Domains) {
        $bad = @($Domains | Where-Object { -not (ConvertTo-NormalizedDomain -Value $_ -Strict) })
        if ($bad.Count -gt 0) {
            $badPreview = @($bad | ForEach-Object { Get-SafeInputPreview -Value $_ })
            & $add '域名' '域名列表' 'FAIL' "非法项：$($badPreview -join ', ')"
        } else {
            $domainList = @($Domains | ForEach-Object { ConvertTo-NormalizedDomain -Value $_ -Strict })
            & $add '域名' '域名列表' 'OK' "来自 -Domains，共 $($domainList.Count) 个"
        }
    } elseif (-not (Test-Path -LiteralPath $domainsFileResolved)) {
        & $add '域名' 'domains.txt' 'SKIP' "不存在：$domainsFileResolved（可以用 domains.example.txt 或 Import-Domains.ps1 生成）"
    } else {
        try {
            $res = Read-DomainsFile -Path $domainsFileResolved
            if ($res.Invalid.Count -gt 0) {
                $invalidText = @($res.InvalidItems | ForEach-Object { "第 $($_.Line) 行 $($_.Preview)" }) -join '，'
                & $add '域名' 'domains.txt' 'FAIL' "非法项：$invalidText"
            } elseif (@($res.Domains).Count -eq 0) {
                & $add '域名' 'domains.txt' 'WARN' "文件里没有域名：$domainsFileResolved"
            } else {
                $domainList = @($res.Domains)
                & $add '域名' 'domains.txt' 'OK' ("{0} 个域名（{1}）" -f $domainList.Count, $domainsFileResolved)
            }
        } catch {
            & $add '域名' 'domains.txt' 'FAIL' $_.Exception.Message
        }
    }

    # ---- CFST ----
    $cfst = Get-CfstDoctorInfo -CfstPath $CfstPath -Root $Root -BuiltinRanges (Get-CfRanges)
    if ($cfst.Error) {
        & $add 'CFST' 'cfst.exe' 'FAIL' $cfst.Error
    } elseif (-not $cfst.Found) {
        & $add 'CFST' 'cfst.exe' 'SKIP' '未找到（会自动回退到内置扫描）；想要更好的覆盖可放到 cfst\cfst.exe'
    } else {
        $ver = if ($cfst.Version) { "v$($cfst.Version)" } else { '版本未知' }
        & $add 'CFST' 'cfst.exe' 'OK' "$ver；$($cfst.Path)"
        if (-not (Test-Path -LiteralPath $cfst.IpFile)) {
            & $add 'CFST' 'ip.txt' 'WARN' "缺少：$($cfst.IpFile)（CFST 会运行失败，自动回退内置扫描）"
        } else {
            $ipDetail = "$($cfst.CidrCount) 个网段"
            if ($cfst.ExtraInIpFile -gt 0) {
                $ipDetail += "；$($cfst.ExtraInIpFile) 个 /24 不在内置列表（$($cfst.ExtraExamples -join ', ') 等），会被过滤，除非 -ExperimentalRanges"
            }
            if ($cfst.MissingFromIpFile -gt 0) {
                $ipDetail += "；$($cfst.MissingFromIpFile) 个内置 /24 不在 ip.txt（$($cfst.MissingExamples -join ', ') 等），只有内置扫描覆盖"
            }
            & $add 'CFST' 'ip.txt' 'OK' $ipDetail
        }
    }

    # ---- 端点 ----
    if ($curlExe) {
        $probeArgs = @{ CurlExe = $curlExe; AllowFallback = $true }
        if ($ProbeUrl) { $probeArgs['PrimaryUrl'] = $ProbeUrl }
        $probe = Resolve-ProbeEndpoint @probeArgs
        if (-not $probe.Ok) {
            & $add '端点' '探测端点' 'FAIL' "$($probe.Url)：$($probe.Detail)。正式运行会中止（退出码 3）。"
        } elseif ($probe.UsedFallback) {
            & $add '端点' '探测端点' 'WARN' $probe.Detail
        } else {
            & $add '端点' '探测端点' 'OK' "$($probe.Url)（$($probe.Detail)）"
        }

        $speed = Test-SpeedEndpoint -CurlExe $curlExe -UrlTemplate $SpeedTestUrl
        $speedHost = (Split-SpeedTestUrl -UrlTemplate $SpeedTestUrl).Host
        if (-not $speed.Ok) {
            & $add '端点' '测速端点' 'FAIL' "$speedHost：$($speed.Detail)。可以用 -SpeedTestUrl 换一个地址。"
        } elseif ($speed.Skipped) {
            & $add '端点' '测速端点' 'WARN' "$speedHost：$($speed.Detail)"
        } else {
            & $add '端点' '测速端点' 'OK' "$speedHost：$($speed.Detail)"
        }
    } else {
        & $add '端点' '探测/测速端点' 'SKIP' '缺少 curl.exe，无法检查'
    }

    # ---- 网络 ----
    $proxy = Get-ProxyState
    if (-not $proxy.Enabled) {
        & $add '网络' 'WinINET 代理' 'OK' '未启用系统代理（这不排除 PAC/TUN/应用级代理）'
    } else {
        $proxyStatus = 'OK'
        $proxyDetail = "已开启 -> $($proxy.Server)"
        if ($domainList.Count -gt 0) {
            $notBypassed = @($domainList | Where-Object { -not (Test-BypassStrict -Domain $_ -Bypass $proxy.Bypass) })
            if ($notBypassed.Count -eq 0) {
                $proxyDetail += '；目标域名都在 ProxyOverride 中'
            } else {
                $proxyStatus = 'WARN'
                $proxyDetail += "；$($notBypassed.Count) 个域名不在 ProxyOverride：$($notBypassed -join ', ')"
            }
        }
        & $add '网络' 'WinINET 代理' $proxyStatus $proxyDetail
    }

    $tun = Get-TunAdapters
    if ($null -eq $tun) {
        & $add '网络' 'TUN 网卡' 'SKIP' '缺少 NetAdapter 模块，无法检测'
    } elseif ($tun.Count -gt 0) {
        $names = ($tun | ForEach-Object { "$($_.Name)/$($_.InterfaceDescription)" }) -join '；'
        & $add '网络' 'TUN 网卡' 'WARN' "$names。正式运行会中止，除非 -Force。"
    } else {
        & $add '网络' 'TUN 网卡' 'OK' '未发现已知 TUN 虚拟网卡（不排除 WFP/透明代理）'
    }

    # ---- 存储 ----
    $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    $backupDir = if ($programData) { Join-Path $programData 'Cloudflare-Hosts-Optimizer\backup' } else { Join-Path $Root 'backup' }
    $bk = Get-BackupDoctorInfo -BackupDir $backupDir -TestWritable:$isAdmin
    if (-not $bk.Exists) {
        & $add '存储' '备份目录' 'WARN' "尚未创建：$backupDir（第一次正式运行会创建）"
    } elseif ($isAdmin -and $bk.Writable -eq $false) {
        & $add '存储' '备份目录' 'WARN' "不可写：$backupDir（正式运行会回退到 $Root\backup）"
    } else {
        $newest = if ($bk.Newest) { $bk.Newest } else { '暂无备份' }
        $note = if (-not $isAdmin) { '；非管理员，未测试写入' } else { '' }
        & $add '存储' '备份目录' 'OK' ("{0}；{1} 个备份，最近 {2}{3}" -f $backupDir, $bk.Count, $newest, $note)
    }

    $cacheFile = if ($ColoCachePath) { $ColoCachePath } else { Get-ColoCacheDefaultPath -Root $Root }
    if (-not (Test-Path -LiteralPath $cacheFile)) {
        & $add '存储' '机房缓存' 'SKIP' "尚未生成：$cacheFile（首次运行会全量探测）"
    } else {
        $cached = Read-ColoCache -Path $cacheFile -MaxAgeDays $ColoCacheMaxAgeDays
        if ($cached) {
            & $add '存储' '机房缓存' 'OK' ("{0} 个区域（{1}）：{2}" -f $cached.Colos.Count,
                $cached.UpdatedAt.ToLocalTime().ToString('yyyy-MM-dd'), ($cached.Colos -join '/'))
        } else {
            & $add '存储' '机房缓存' 'WARN' '已过期或无法读取，下次运行会全量探测（只影响耗时，不影响结果）'
        }
    }

    # ---- 计划任务 ----
    $taskInfo = Get-ScheduledTaskDoctorInfo
    if (-not $taskInfo.Available) {
        & $add '计划' '计划任务' 'SKIP' '缺少 ScheduledTasks 模块，无法查询'
    } elseif ($taskInfo.QueryFailed) {
        & $add '计划' '计划任务' 'WARN' ("查询计划任务失败：{0}" -f $taskInfo.Error)
    } elseif (@($taskInfo.Tasks).Count -eq 0) {
        & $add '计划' '计划任务' 'SKIP' '未注册（可选：-InstallTask -TaskMode DryRun）'
    } else {
        foreach ($t in @($taskInfo.Tasks)) {
            $status = 'OK'
            $detail = "状态 $($t.State)"
            if ($t.NextRun) { $detail += "，下次 $($t.NextRun)" }
            if ($t.LastRun) { $detail += "，上次 $($t.LastRun)（结果 $($t.LastResult)）" }
            if ($t.State -eq 'Disabled') { $status = 'WARN'; $detail += '；任务已禁用' }
            if ($t.ScriptExists -eq $false) {
                $status = 'WARN'
                $detail += "；任务指向的脚本不存在：$($t.ScriptPath)（移动过目录后需要重新注册）"
            }
            # 267011 = SCHED_S_TASK_HAS_NOT_RUN，刚注册还没跑过的任务不该报警
            if ($t.LastResult -ne $null -and $t.LastResult -ne 0 -and $t.LastResult -ne 267011 -and $t.LastRun) {
                $status = 'WARN'
                $detail += "；上次运行返回 $($t.LastResult)"
            }
            & $add '计划' $t.TaskName $status $detail
        }
    }

    # ---- 解析核对（只在 -CheckResolved 时做，只查 DNS） ----
    if ($CheckResolved -and $domainList.Count -gt 0) {
        foreach ($d in $domainList) {
            try {
                $addrs = @([System.Net.Dns]::GetHostAddresses($d) | ForEach-Object { $_.IPAddressToString })
                $v4 = @($addrs | Where-Object { $_ -notmatch ':' })
                $v6 = @($addrs | Where-Object { $_ -match ':' })
                $st = if ($v4.Count -gt 0) { 'OK' } else { 'WARN' }
                $detail = "A $($v4.Count) 个$(if ($v4.Count -gt 0) { "（$($v4[0])）" })；AAAA $($v6.Count) 个"
                & $add '域名解析' $d $st $detail
            } catch {
                & $add '域名解析' $d 'WARN' '解析失败'
            }
        }
    }

    Stop-TaskSpinner
    Say ''
    Say "Cloudflare-Hosts-Optimizer $ScriptVersion · Doctor" 'Cyan'
    foreach ($line in (Format-DoctorReport -Checks $checks)) {
        $color = if ($line.StartsWith('[FAIL]')) { 'Red' }
                 elseif ($line.StartsWith('[WARN]')) { 'Yellow' }
                 elseif ($line.StartsWith('[ OK ]')) { 'Green' }
                 elseif ($line.StartsWith('== ')) { 'Cyan' }
                 else { 'Gray' }
        Say $line $color
    }
    return (Get-DoctorExitCode -Checks $checks)
}

function Invoke-TaskInstall {
    if ($TaskMode -eq 'AutoApply') { Assert-Admin }
    if ($script:ScriptBoundParameters.ContainsKey('Domains')) {
        Fail '-InstallTask 不支持 -Domains：域名数组没法安全写进任务命令行，也会把站点清单暴露在任务参数里。请用 domains.txt 或 -DomainsFile。' 2
    }
    # 任务的工作目录固定为仓库根；相对路径必须在这里按“调用者当前目录”定死成绝对路径，
    # 否则安装时校验的和运行时打开的可能不是同一个文件。
    $makeAbsolute = {
        param([string]$p)
        if (-not $p) { return $p }
        try {
            if ([IO.Path]::IsPathRooted($p)) { return [IO.Path]::GetFullPath($p) }
            return [IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $p))
        } catch { return $p }
    }

    $df = & $makeAbsolute ($(if ($DomainsFile) { $DomainsFile } else { Join-Path $Root 'domains.txt' }))
    if (-not (Test-Path -LiteralPath $df)) { Fail "找不到域名文件：$df。计划任务每次运行都要用它。" 2 }
    $res = Read-DomainsFile -Path $df
    if ($res.Invalid.Count -gt 0) {
        $invalidText = @($res.InvalidItems | ForEach-Object { "第 $($_.Line) 行 $($_.Preview)" }) -join '，'
        Fail "域名文件含非法项：$invalidText" 2
    }
    if (@($res.Domains).Count -eq 0) { Fail "域名文件里没有域名：$df" 2 }

    $extra = @{}
    foreach ($k in $script:TaskPassThroughParams) {
        if ($script:ScriptBoundParameters.ContainsKey($k)) { $extra[$k] = $script:ScriptBoundParameters[$k] }
    }
    # 路径类参数定成绝对路径；SpeedTestUrl/ProbeUrl 是 URL，不能碰
    foreach ($k in @('DomainsFile', 'CfstPath', 'ColoCachePath')) {
        if ($extra.ContainsKey($k)) { $extra[$k] = & $makeAbsolute ([string]$extra[$k]) }
    }
    if ($DomainsFile) { $extra['DomainsFile'] = $df }
    $report = & $makeAbsolute ($(if ($ReportPath) { $ReportPath } else { Join-Path $Root 'last-report.txt' }))

    try {
        $spec = New-OptimizerTaskSpec -Root $Root -Mode $TaskMode -IntervalDays $TaskIntervalDays -At $TaskAt `
            -ReportPath $report -TaskName $TaskName -ExtraParameters $extra
    } catch { Fail $_.Exception.Message 2 }

    try { $null = Install-OptimizerTask -Spec $spec -TaskForce:$TaskForce }
    catch { Fail $_.Exception.Message 1 }

    Say "已注册计划任务：$($spec.TaskName)" 'Green'
    Say "频率：每 $($spec.IntervalDays) 天，$($spec.At)（从注册后的下一个该时间开始）" 'Gray'
    Say "模式：$(if ($spec.Mode -eq 'DryRun') { 'DryRun —— 只写报告，不修改 hosts' } else { 'AutoApply —— 自动写入 hosts（需要管理员）' })" 'Gray'
    Say "程序：$($spec.Execute)" 'DarkGray'
    Say "报告：$($spec.ReportPath)" 'DarkGray'
    Say "删除：.\Cloudflare-Hosts-Optimizer.ps1 -UninstallTask -TaskName '$($spec.TaskName)'" 'DarkGray'
    return 0
}

function Invoke-TaskUninstall {
    $names = if ($TaskName) { @($TaskName) } else { $script:DefaultTaskNames }
    # 先校验全部名字：通配符交给原生命令会被当成模式，可能删到别的程序的任务
    foreach ($n in @($names)) {
        $nameError = Test-OptimizerTaskName -TaskName $n
        if ($nameError) { Fail "任务名无效「$n」：$nameError" 2 }
    }
    try { $rows = @(Uninstall-OptimizerTask -TaskName $names -ScriptPath (Join-Path $Root 'Cloudflare-Hosts-Optimizer.ps1')) }
    catch { Fail $_.Exception.Message 1 }

    $failed = @()
    foreach ($r in $rows) {
        if ($r.Removed) {
            Say "$($r.TaskName)：$($r.Detail)" 'Green'
        } else {
            Say "$($r.TaskName)：$($r.Detail)" 'Red'
            $failed += $r
        }
    }
    if ($failed.Count -gt 0) { Fail '有任务没有删除成功；AutoApply 任务需要管理员 PowerShell。' 1 }
    return 0
}

function Invoke-Main {
    # ---- 模式互斥 ----
    if ($InstallTask -and $UninstallTask) { Fail '-InstallTask 和 -UninstallTask 只能选一个。' 2 }
    if (($InstallTask -or $UninstallTask) -and ($DryRun -or $Plan -or $PlanPath -or $Rollback -or $Doctor)) {
        Fail '-InstallTask/-UninstallTask 不能与 -DryRun/-Plan/-Rollback/-Doctor 同时使用；要注册只读任务请用 -TaskMode DryRun。' 2
    }
    if (-not $InstallTask) {
        foreach ($p in @('TaskIntervalDays', 'TaskAt', 'TaskMode', 'TaskForce')) {
            if ($script:ScriptBoundParameters.ContainsKey($p)) {
                Fail "-$p 只能与 -InstallTask 一起使用（-UninstallTask 可以用 -TaskName）。" 2
            }
        }
    }
    if (-not $InstallTask -and -not $UninstallTask -and $script:ScriptBoundParameters.ContainsKey('TaskName')) {
        Fail '-TaskName 只能与 -InstallTask/-UninstallTask 一起使用。' 2
    }
    if ($Doctor) {
        if ($Rollback -or $Plan -or $PlanPath) {
            Fail '-Doctor 不能与 -Rollback/-Plan 同时使用。' 2
        }
        $script:ExitCode = Invoke-Doctor
        return 0
    }

    # ---- 计划任务 ----
    if ($InstallTask) { return (Invoke-TaskInstall) }
    if ($UninstallTask) { return (Invoke-TaskUninstall) }

    $script:RunWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $hostsPathResolved = if ($HostsPath) { $HostsPath } else { Join-Path $env:SystemRoot 'System32\drivers\etc\hosts' }
    $domainsFileResolved = if ($DomainsFile) { $DomainsFile } else { Join-Path $Root 'domains.txt' }

    $planMode = [bool]$Plan -or [bool]$PlanPath
    $readOnly = [bool]$DryRun -or $planMode
    $planFile = if ($PlanPath) { $PlanPath } else { Join-Path $Root 'plan.json' }
    if ($Rollback -and $readOnly) { Fail '-Rollback 不能与 -DryRun/-Plan 同时使用。' 2 }
    if ($RollbackFrom -and -not $Rollback) { Fail '-RollbackFrom 只能与 -Rollback 一起使用。' 2 }
    if ($AllowUntrustedBackup -and -not $Rollback) { Fail '-AllowUntrustedBackup 只能与 -Rollback 一起使用。' 2 }
    # 这个开关只授权“用户指定的那一份”备份；不能用来在所有不可信目录里自动挑最新
    if ($AllowUntrustedBackup -and -not $RollbackFrom) { Fail '-AllowUntrustedBackup 必须同时指定 -RollbackFrom <备份文件>。' 2 }

    # ---- 输出路径不得与输入文件（或彼此）指向同一个文件 ----
    # 报告/计划/缓存/摘要都是“旁路输出”，不经过 hosts 事务；一旦和 hosts 撞车就会绕开保护。
    # 系统 hosts 永远在保护集合里，即使本次用的是沙箱 -HostsPath。
    $script:SafeInputPaths = @(Get-ProtectedInputPaths -HostsPath $hostsPathResolved -DomainsFile $domainsFileResolved -RollbackFrom $RollbackFrom)
    $coloCacheResolved = if ($ColoCachePath) { $ColoCachePath } else { Get-ColoCacheDefaultPath -Root $Root }
    $mainOutputs = @($script:ReportPathResolved, $planFile, $coloCacheResolved, (Join-Path $Root 'last-run.json'))
    for ($i = 0; $i -lt $mainOutputs.Count; $i++) {
        $out = $mainOutputs[$i]
        if (-not $out) { continue }
        $others = @()
        for ($j = 0; $j -lt $mainOutputs.Count; $j++) {
            if ($j -ne $i -and $mainOutputs[$j]) { $others += $mainOutputs[$j] }
        }
        $conflict = Assert-OutputPathSafe -Path $out -InputPaths $script:SafeInputPaths -OtherOutputs $others
        if ($conflict) { Fail $conflict 2 }
    }

    if ($Rollback) {
        Assert-AdminForPath $hostsPathResolved
        $script:RunMode = 'rollback'
        $script:RunHostsPath = $hostsPathResolved
        # 只查、不创建：回滚不应该为了找备份去建目录或写探针
        $backupDirs = @(Get-HostsBackupDirs -HostsPath $hostsPathResolved -FallbackRoot $Root)
        if ($AllowUntrustedBackup) {
            Say '警告：-AllowUntrustedBackup 已启用；会接受普通用户可写目录里的备份，请确认来源。' 'Yellow'
        }
        $r = Invoke-HostsRollback -HostsPath $hostsPathResolved -BackupDir $backupDirs -LegacyBackupDir (Join-Path $Root 'backup') -BackupPath $RollbackFrom -Force:$Force -AllowUntrustedBackup:$AllowUntrustedBackup
        $flush = Clear-DnsCache
        if ($r.Unchanged) { Say "hosts 已经是该备份的内容，无需恢复：$($r.Restored)" 'Green' }
        else { Say "已恢复 hosts：$($r.Restored)" 'Green' }
        if (-not $flush.Ok) { Say "警告：flushdns 失败：$($flush.Output)" 'Yellow' }
        $script:RunChanged = -not $r.Unchanged
        $script:RunCommittedAt = $r.CommittedAt
        $script:RunSummaryLine = if ($r.Unchanged) { '无变化（hosts 已是该备份内容）' } else { '已恢复 hosts' }
        return 0
    }

    $script:RunHostsPath = $hostsPathResolved
    $script:RunMode = if ($planMode) { 'plan' } elseif ($DryRun) { 'dryrun' } else { 'write' }

    # ---- 域名 ----
    $domainList = @()
    if ($Domains) {
        foreach ($d in $Domains) {
            $n = ConvertTo-NormalizedDomain -Value $d -Strict
            if (-not $n) { Fail ("非法域名：{0}" -f (Get-SafeInputPreview -Value $d)) 2 }
            $domainList += $n
        }
    } else {
        $res = Read-DomainsFile -Path $domainsFileResolved
        if ($res.Invalid.Count -gt 0) {
            $invalidText = @($res.InvalidItems | ForEach-Object { "第 $($_.Line) 行 $($_.Preview)" }) -join '，'
            Fail ("域名文件含非法项：{0}" -f $invalidText) 2
        }
        $domainList = @($res.Domains)
    }
    $domainList = @($domainList | Select-Object -Unique)
    if ($domainList.Count -eq 0) {
        Fail "没有配置任何域名。请复制 domains.example.txt 为 domains.txt 并填入目标域名，或用 -Domains 指定。当前路径：$domainsFileResolved" 2
    }

    # 测速地址是参数错误，尽早失败，不要扫完几分钟才发现。
    try { $null = Split-SpeedTestUrl -UrlTemplate $SpeedTestUrl } catch { Fail $_.Exception.Message 2 }
    # -ProbeUrl 是参数错误也尽早失败，不要等扫描前的预检才抛异常
    if ($ProbeUrl) {
        try { $null = Split-ProbeUrl -Url $ProbeUrl } catch { Fail $_.Exception.Message 2 }
    }

    if (-not $readOnly) { Assert-AdminForPath $hostsPathResolved }
    $curlExe = Get-CurlExe

    $modeText = if ($planMode) { 'Plan' } elseif ($DryRun) { 'DryRun' } else { '写入 hosts' }
    Say ''
    Say "Cloudflare-Hosts-Optimizer $ScriptVersion · $modeText · $($domainList.Count) 个域名" 'Cyan'
    Say "hosts: $hostsPathResolved" 'DarkGray'

    Start-Step '检查环境与端点' '约 5 秒' -Total 6
    Show-ProxyCheck -TargetDomains $domainList
    $tun = Test-TunAdapter
    # DryRun/Plan 同样会真实请求目标站，不能因为“不写 hosts”就放行 TUN
    if ($tun -and -not $Force) {
        Fail '检测到 TUN 网卡。--noproxy 只能绕过 HTTP 代理，绕不过 TUN；为避免测速和访问走代理，已中止。关闭 TUN/透明代理后重试，或确认风险后加 -Force 继续。' 3
    }
    Say ''

    # ---- 读取 hosts（尽早校验结构，避免白扫几分钟才报错） ----
    try {
        $doc = Read-HostsDocument -Path $hostsPathResolved
        $hostsLines = @($doc.Text -split "`r?`n")
        $blockInfo = Get-HostsBlockInfo -Lines $hostsLines
        $previousMap = Get-HostsBlockMap -Lines $hostsLines -BlockInfo $blockInfo

        # 提前检查多别名/IPv6/其他工具区块冲突，避免扫描几分钟后才失败
        $preflightSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($d in $domainList) { [void]$preflightSet.Add($d) }
        $preflight = Get-HostsOutsideInfo -Lines $hostsLines -BlockInfo $blockInfo -ManagedSet $preflightSet
        if ($preflight.Conflicts.Count -gt 0) {
            $details = ($preflight.Conflicts | ForEach-Object {
                    "第 $($_.Line) 行 [$($_.Reason)]：$($_.Hosts)"
                }) -join '; '
            Fail "hosts 中存在需要人工处理的映射，已中止且未修改：$details。请按行号处理后重试。" 4
        }
    } catch {
        if ($script:FailCode) { throw }
        Fail $_.Exception.Message 4
    }

    # ---- 端点预检 ----
    # 先确认 trace / 测速端点活着，否则要扫几分钟才发现测不到速度。
    $probeArgs = @{ CurlExe = $curlExe; AllowFallback = (-not $script:ProbeUrlExplicit) }
    if ($ProbeUrl) { $probeArgs['PrimaryUrl'] = $ProbeUrl }
    $probe = Resolve-ProbeEndpoint @probeArgs
    if ($probe.UsedFallback) { Say "警告：$($probe.Detail)" 'Yellow' }
    if (-not $probe.Ok) {
        Fail ("探测端点不可用：$($probe.Url)（$($probe.Detail)）。请检查网络；也可以用 -ProbeUrl 换一个 Cloudflare 托管的 trace 地址。可以先运行 -Doctor 检查环境。") 3
    }
    Say "探测端点：$($probe.Host)" 'Gray'
    Say '延迟扫描和机房判断用的 trace 地址。' 'DarkGray'

    $speedCheck = Test-SpeedEndpoint -CurlExe $curlExe -UrlTemplate $SpeedTestUrl
    # 瞬时超时很常见，失败后重试一次再判定
    if (-not $speedCheck.Ok -and -not $speedCheck.Skipped) {
        Start-Sleep -Milliseconds 400
        $speedCheck = Test-SpeedEndpoint -CurlExe $curlExe -UrlTemplate $SpeedTestUrl
    }
    $speedHost = (Split-SpeedTestUrl -UrlTemplate $SpeedTestUrl).Host
    if (-not $speedCheck.Ok) {
        Fail ("测速端点不可用：$speedHost（$($speedCheck.Detail)）。可以换 -SpeedTestUrl，或检查网络/代理。可以先运行 -Doctor 检查环境。") 3
    }
    if ($speedCheck.Skipped) {
        Say "测速端点：$speedHost（$($speedCheck.Detail)）" 'Yellow'
    } else {
        Say "测速端点：$speedHost，$($speedCheck.Detail)" 'Gray'
        Say '只确认端点可用，不参与排名。' 'DarkGray'
    }
    Complete-Step

    # ---- 延迟筛选 ----
    Start-Step '延迟筛选' '约 1–3 分钟'
    # 从这里开始是长时间的网络阶段，装一个 Ctrl+C 提示，免得按了没反应
    Install-CancelNotice
    $ranges = Get-CfRanges -Experimental:$ExperimentalRanges
    $latency = @()
    $cfst = $null
    if (-not $NoCfst) {
        try { $cfst = Find-Cfst -Explicit $CfstPath -Root $Root }
        catch { Fail $_.Exception.Message 2 }
    }

    Start-TaskSpinner
    try {
        if ($cfst) {
            Say "使用 CFST 做全量延迟扫描（可能需要 1–3 分钟）：$cfst" 'Gray'
            try { $latency = @(Invoke-CfstLatencyScan -Exe $cfst -Ranges $ranges) }
            catch { Say "CFST 运行失败：$($_.Exception.Message)" 'Yellow'; $latency = @() }
            if ($latency.Count -eq 0) { Say 'CFST 没有产出结果，改用内置扫描。' 'Yellow' }
        }
        if ($latency.Count -eq 0) {
            if ($NoCfst) { Say '已指定 -NoCfst，使用内置扫描。' 'Yellow' }
            elseif (-not $cfst) { Say '未找到 cfst.exe，使用内置扫描。' 'Yellow' }
            $latency = @(Invoke-BuiltinLatencyScan -CurlExe $curlExe -Candidates $MaxCandidates -Samples $ScanSamples -Ranges $ranges -ProbeUrl $probe.Url)
        }
    } finally {
        Stop-TaskSpinner
    }
    if ($latency.Count -eq 0) { Fail '没有扫到任何可用 IP。请检查网络后重试。' 3 }

    $latency = @($latency | Sort-Object Ttfb)
    Say "延迟/丢包筛选后可用 IP：$($latency.Count)，最佳 $($latency[0].IP)（$([math]::Round($latency[0].Ttfb * 1000))ms）" 'Gray'

    $avgTtfb = ($latency | Select-Object -First 10 | Measure-Object -Property Ttfb -Average).Average
    if ($avgTtfb -lt 0.005) {
        Say '警告：平均延迟异常低（<5ms），测速可能经过了代理。结果仅供参考。' 'Yellow'
    }
    Complete-Step

    # ---- 机房分层 ----
    Start-Step '探测机房' '约 2–6 分钟'
    $pool = @($latency | Select-Object -First ([int][math]::Min(256, $latency.Count)))
    $probeTarget = $pool.Count

    # 上次探测到的区域；覆盖这些区域后可以提前结束，省掉几分钟的重复探测
    $useCache = -not $NoColoCache -and $ColoCacheMaxAgeDays -gt 0
    $cacheFile = if ($ColoCachePath) { $ColoCachePath } else { Get-ColoCacheDefaultPath -Root $Root }
    $cachedColos = @()
    if ($useCache) {
        $cached = Read-ColoCache -Path $cacheFile -MaxAgeDays $ColoCacheMaxAgeDays
        if ($cached) {
            $cachedColos = @($cached.Colos)
            Say ("机房缓存：{0} 记录 {1} 个区域（{2}）。探测覆盖后提前结束。" -f
                $cached.UpdatedAt.ToLocalTime().ToString('yyyy-MM-dd'),
                $cachedColos.Count, ($cachedColos -join '/')) 'DarkGray'
        } elseif (Test-Path -LiteralPath $cacheFile) {
            Say '机房缓存已过期或无法读取，本次全量探测。' 'DarkGray'
        }
    }

    Say "探测候选落地区域（$($pool.Count) 个，可能需要几分钟）..." 'Gray'
    Start-TaskSpinner
    try {
        $pool = @(Resolve-Colo -CurlExe $curlExe -Candidates $pool -EarlyStopColos $cachedColos `
                -EarlyStopMinProbe ([int][math]::Max(64, $ThroughputCandidates * 2)) -ProbeUrl $probe.Url -OnProgress {
                param($Done, $Total, $ElapsedSec)
                if (Test-TaskSpinnerActive) {
                    Update-TaskSpinner -Detail ("{0}/{1} · {2:N0}s" -f $Done, $Total, $ElapsedSec)
                } else {
                    # 计划任务/管道：没有动画，按批打印，报告里能看到进度
                    Say ("已探测 {0}/{1}（{2:N0}s）" -f $Done, $Total, $ElapsedSec) 'DarkGray'
                }
            })
    } finally {
        Stop-TaskSpinner
    }

    if ($useCache -and $pool.Count -lt $probeTarget) {
        Say ("已覆盖缓存区域，提前结束：探测 {0}/{1} 个候选。" -f $pool.Count, $probeTarget) 'DarkGray'
    }

    $candidates = @(Select-Stratified -Candidates $pool -Count $ThroughputCandidates)
    $coloSummary = (@($candidates | Group-Object Colo | ForEach-Object {
                $name = if ($_.Name) { $_.Name } else { '??' }
                "$name x$($_.Count)"
            })) -join ', '
    Say "分层抽样 $($candidates.Count) 个（$coloSummary）" 'Gray'

    # 只有完整探测过一轮、且池子足够大才写缓存（提前结束时看到的是子集，写回会越缩越小；
    # 小池子本来就很快，缓存反而会把它覆盖成更窄的区域集合）。
    # 只记录抽样里出现 ≥2 次的区域（最多 6 个）：稀有区域下次经常消失，
    # 留着它会让覆盖检查永远失败，缓存等于没有
    if ($useCache -and $pool.Count -eq $probeTarget -and $probeTarget -ge 64) {
        $observed = @(Get-CachableColos -Candidates $candidates)
        if ($observed.Count -gt 0 -and -not (Write-ColoCache -Path $cacheFile -Colos $observed -ProtectedPaths $script:SafeInputPaths)) {
            Say "警告：机房缓存写入失败（$cacheFile），不影响本次结果。" 'Yellow'
        }
    }
    Complete-Step

    # ---- 吞吐初测 ----
    Start-Step '吞吐测速' '约 1–3 分钟'
    Start-TaskSpinner
    Update-TaskSpinner -Detail '初测'
    try {
        $quick = @(Invoke-ThroughputTest -CurlExe $curlExe -Candidates $candidates -Samples $ThroughputSamples -Bytes $ThroughputBytes -UrlTemplate $SpeedTestUrl -ThrottleLimit 6 -Phase '初测')
    } finally {
        Stop-TaskSpinner
    }
    $quickMap = @{}
    foreach ($q in $quick) { if ($q) { $quickMap[$q.IP] = $q } }

    $ranked = foreach ($c in $candidates) {
        $q = $quickMap[$c.IP]
        [pscustomobject]@{
            IP = $c.IP; Colo = $c.Colo; Loss = $c.Loss; Ttfb = $c.Ttfb
            QuickSpeed = if ($q) { [double]$q.SpeedMBps } else { 0.0 }
            QuickValid = if ($q) { [int]$q.Valid } else { 0 }
        }
    }
    $promoted = @($ranked | Where-Object { $_.QuickValid -ge 1 -and $_.QuickSpeed -gt 0 } |
        Sort-Object @{ Expression = 'QuickSpeed'; Descending = $true }, @{ Expression = 'Ttfb'; Descending = $false } |
        Select-Object -First $RefineTop)

    $globalCandidates = @()
    $reserveCandidates = @()
    if ($promoted.Count -gt 0) {
        # 决赛：3 x 2MB，串行，避免互相抢带宽
        Start-TaskSpinner
        Update-TaskSpinner -Detail '决赛'
        try {
            $final = @(Invoke-ThroughputTest -CurlExe $curlExe -Candidates $promoted -Samples 3 -Bytes 2097152 -UrlTemplate $SpeedTestUrl -ThrottleLimit 1 -MaxTime 15 -Phase '决赛')
        } finally {
            Stop-TaskSpinner
        }
        $finalMap = @{}
        foreach ($f in $final) { if ($f) { $finalMap[$f.IP] = $f } }

        $finalRows = foreach ($p in $promoted) {
            $f = $finalMap[$p.IP]
            [pscustomobject]@{
                IP = $p.IP; Colo = $p.Colo; Loss = $p.Loss; Ttfb = $p.Ttfb
                SpeedMBps = if ($f) { [double]$f.SpeedMBps } else { 0.0 }
                Valid = if ($f) { [int]$f.Valid } else { 0 }
                Reasons = if ($f) { $f.Reasons } else { '' }
            }
        }

        Say ''
        Say '决赛结果（只使用决赛成绩）：' 'White'
        $finalRows | Select-Object IP, Colo, Loss, Ttfb, SpeedMBps, Valid |
            Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Say $_.Trim() }

        $rankedFinal = @($finalRows | Where-Object { $_.Valid -ge 2 -and $_.SpeedMBps -gt 0 } |
            Sort-Object @{ Expression = 'SpeedMBps'; Descending = $true }, @{ Expression = 'Ttfb'; Descending = $false })
        $globalCandidates = @($rankedFinal | Select-Object -First $CandidatesPerDomain)
        $reserveCandidates = @($rankedFinal | Select-Object -Skip $CandidatesPerDomain -First $BackfillCandidates)
    } else {
        Say '警告：没有候选通过吞吐初测，本次只做基线与兜底检查。' 'Yellow'
    }

    Say ''
    Say '全局候选（逐域名只从这里取前几个，按基线决定是否切换）：' 'White'
    if ($globalCandidates.Count -gt 0) {
        $globalCandidates | Select-Object IP, Colo, Ttfb, SpeedMBps |
            Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Say $_.Trim() }
    } else {
        Say '（无）' 'Yellow'
    }
    if ($reserveCandidates.Count -gt 0) {
        Say ''
        Say '补位候选（前几个都不可用时才测）：' 'White'
        $reserveCandidates | Select-Object IP, Colo, Ttfb, SpeedMBps |
            Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Say $_.Trim() }
    }
    Complete-Step

    # ---- 逐域名选择：基线 = 当前 hosts/DNS 路径 ----
    Start-Step '逐站验证' '约 1–3 分钟'
    $map = @{}
    $decisions = @()
    $dropPrevious = @()

    Say '逐域名验证与选择（基线 = 当前 hosts/DNS 路径）...' 'Gray'
    $verifyIndex = 0
    Start-TaskSpinner
    foreach ($d in $domainList) {
        $verifyIndex++
        Update-TaskSpinner -Detail ("{0}/{1} {2}" -f $verifyIndex, $domainList.Count, $d)
        # 1) 基线：不指定 IP，走系统当前路径
        $baseResult = Test-DomainIp -Domain $d -CurlExe $curlExe -NoResolve -MaxTime $VerifyTimeoutSec
        # 每个物理 IP 最多 2 次 HEAD：基线、候选、复核都记在这里；失败但打到某个 IP 的探测也算。
        $ipProbes = @{}
        Add-ProbeUse -Budget $ipProbes -Ip $baseResult.RemoteIp
        $baseline = [pscustomobject]@{
            IP = $baseResult.RemoteIp; Ok = $baseResult.Ok
            Class = $baseResult.Class; Ttfb = $baseResult.Ttfb
        }
        $baselineFromBlock = $previousMap.Contains($d)

        # 2) 候选：全局前 K + 补位 + 旧映射（去重，受 MaxDomainProbes 约束）
        $candidates = @()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($baseline.IP -and $baseline.Ok) { [void]$seen.Add($baseline.IP) }
        $probes = 0

        foreach ($p in $globalCandidates) {
            if ($probes -ge $MaxDomainProbes) { break }
            if ($seen.Contains($p.IP)) { continue }
            if (-not (Test-ProbeBudgetAllows -Budget $ipProbes -Ip $p.IP)) { continue }
            $r = Test-DomainIp -Domain $d -Ip $p.IP -CurlExe $curlExe -MaxTime $VerifyTimeoutSec
            Add-ProbeUse -Budget $ipProbes -Ip $p.IP
            $candidates += [pscustomobject]@{
                IP = $p.IP; Colo = $p.Colo; Ok = $r.Ok; Class = $r.Class; Ttfb = $r.Ttfb; Source = 'global'
            }
            [void]$seen.Add($p.IP)
            $probes++
            Start-Sleep -Milliseconds $VerifyDelayMs
        }

        # 前 K 个都没有可用结果时，才测补位候选
        $anyWorking = @($candidates | Where-Object { $_.Ok }).Count -gt 0
        if (-not $anyWorking) {
            foreach ($p in $reserveCandidates) {
                if ($probes -ge $MaxDomainProbes) { break }
                if ($seen.Contains($p.IP)) { continue }
                if (-not (Test-ProbeBudgetAllows -Budget $ipProbes -Ip $p.IP)) { continue }
                $r = Test-DomainIp -Domain $d -Ip $p.IP -CurlExe $curlExe -MaxTime $VerifyTimeoutSec
                Add-ProbeUse -Budget $ipProbes -Ip $p.IP
                $candidates += [pscustomobject]@{
                    IP = $p.IP; Colo = $p.Colo; Ok = $r.Ok; Class = $r.Class; Ttfb = $r.Ttfb; Source = 'reserve'
                }
                [void]$seen.Add($p.IP)
                $probes++
                Start-Sleep -Milliseconds $VerifyDelayMs
            }
        }

        if ($baselineFromBlock) {
            foreach ($ip in @($previousMap[$d] | Select-Object -Unique)) {
                if ($probes -ge $MaxDomainProbes) { break }
                if ($seen.Contains($ip)) { continue }
                if (-not (Test-ProbeBudgetAllows -Budget $ipProbes -Ip $ip)) { continue }
                $r = Test-DomainIp -Domain $d -Ip $ip -CurlExe $curlExe -MaxTime $VerifyTimeoutSec
                Add-ProbeUse -Budget $ipProbes -Ip $ip
                $candidates += [pscustomobject]@{
                    IP = $ip; Colo = ''; Ok = $r.Ok; Class = $r.Class; Ttfb = $r.Ttfb; Source = 'previous'
                }
                [void]$seen.Add($ip)
                $probes++
                Start-Sleep -Milliseconds $VerifyDelayMs
            }
        }

        # 3) 受限（1034）且没有可用候选：回退到该域名自己的 DNS A 记录
        $anyWorking = @($candidates | Where-Object { $_.Ok }).Count -gt 0
        $anyRestricted = ($baseline.Class -eq 'restricted') -or
            (@($candidates | Where-Object { $_.Class -eq 'restricted' }).Count -gt 0)
        if (-not $anyWorking -and $anyRestricted) {
            $dnsIps = @(Resolve-DnsName -Name $d -Type A -DnsOnly -NoHostsFile -ErrorAction SilentlyContinue |
                    Where-Object { $_.Type -eq 'A' -and $_.IPAddress } |
                    ForEach-Object { $_.IPAddress } |
                    Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and (Test-IpAllowed -Ip $_ -Ranges $ranges) } |
                    Select-Object -Unique | Select-Object -First 2)
            foreach ($ip in $dnsIps) {
                if ($seen.Contains($ip)) { continue }
                if (-not (Test-ProbeBudgetAllows -Budget $ipProbes -Ip $ip)) { continue }
                $r = Test-DomainIp -Domain $d -Ip $ip -CurlExe $curlExe -MaxTime $VerifyTimeoutSec
                Add-ProbeUse -Budget $ipProbes -Ip $ip
                $candidates += [pscustomobject]@{
                    IP = $ip; Colo = ''; Ok = $r.Ok; Class = $r.Class; Ttfb = $r.Ttfb; Source = 'dns'
                }
                [void]$seen.Add($ip)
                Start-Sleep -Milliseconds $VerifyDelayMs
            }
        }

        # 4) 选择：只有改善足够或基线失败才切换
        $decision = Select-DomainIp -Baseline $baseline -Candidates $candidates `
            -MinImprovementPct $MinImprovementPct -MinImprovementMs $MinImprovementMs

        # 4b) 准备切换且基线可用时，切换前复核：只比较基线与选中的候选。
        #     不在全部候选里重选（未复核的 IP 不该因复核噪声胜出）；
        #     候选复测失败/受限则不切换；百分比和绝对毫秒门槛都要满足。
        if ($decision.Changed -and $decision.IP -and $baseline.Ok) {
            $best = @($candidates | Where-Object { $_.IP -eq $decision.IP } | Select-Object -First 1)
            if ($best.Count -gt 0) {
                $b2 = Test-DomainIp -Domain $d -CurlExe $curlExe -NoResolve -MaxTime $VerifyTimeoutSec
                Add-ProbeUse -Budget $ipProbes -Ip $b2.RemoteIp
                Start-Sleep -Milliseconds $VerifyDelayMs

                # 系统解析在两次探测之间换了 IP（可能是候选、第三个地址或 IPv6）：
                # 两个不同 IP 的样本不能合并成同一条基线，本次不切换。
                # 注意：失败/受限但带着新 RemoteIp 的响应同样算“换了 IP”。
                $recheckPlan = Get-RecheckPlan -BaselineIp $baseline.IP -B2 $b2 `
                    -CandidateBudgetAllows (Test-ProbeBudgetAllows -Budget $ipProbes -Ip $best[0].IP)
                if ($recheckPlan -eq 'ip-changed') {
                    $decision = [pscustomobject]@{
                        IP = $baseline.IP; Changed = $false; Reason = 'baseline-ip-changed'
                        ImprovementPct = $null; BestIP = $best[0].IP; BestTtfb = $best[0].Ttfb
                    }
                } else {
                    $c2 = $null
                    if ($recheckPlan -eq 'need-candidate') {
                        # 基线复核失败也要验证候选：早先一次成功不能替代这一次
                        $c2 = Test-DomainIp -Domain $d -Ip $best[0].IP -CurlExe $curlExe -MaxTime $VerifyTimeoutSec
                        Add-ProbeUse -Budget $ipProbes -Ip $best[0].IP
                        Start-Sleep -Milliseconds $VerifyDelayMs
                    }

                    if (-not $c2) {
                        # 预算不足，无法确认候选：保守不切换
                        $decision = [pscustomobject]@{
                            IP = $baseline.IP; Changed = $false; Reason = 'candidate-budget-exhausted'
                            ImprovementPct = $null; BestIP = $best[0].IP; BestTtfb = $best[0].Ttfb
                        }
                    } else {
                        $baseSamples = @()
                        if ($b2.Ok) { $baseSamples += $b2.Ttfb }
                        $candSamples = @()
                        if ($c2 -and $c2.Ok) { $candSamples += $c2.Ttfb }

                        $confirm = Resolve-SwitchConfirmation -BaseTtfb $baseline.Ttfb -BestTtfb $best[0].Ttfb `
                            -BaseSamples $baseSamples -CandidateSamples $candSamples `
                            -CandidateFlaky:([bool]($c2 -and -not $c2.Ok)) -BaselineRetestFailed:(-not $b2.Ok) `
                            -BaselineClass $b2.Class -CandidateClass $(if ($c2) { $c2.Class } else { '' }) `
                            -Reason $decision.Reason `
                            -MinImprovementPct $MinImprovementPct -MinImprovementMs $MinImprovementMs

                        # 复核中位数回写到两边（成功和失败都写），报告里的
                        # BaseTTFB / ChosenTTFB / BestTTFB 才能和 ImprovePct 对得上。
                        if ($null -ne $confirm.BaseMs) { $baseline.Ttfb = [double]$confirm.BaseMs / 1000.0 }
                        if ($null -ne $confirm.BestMs) { $best[0].Ttfb = [double]$confirm.BestMs / 1000.0 }

                        $decision = Resolve-ConfirmedDecision -Confirm $confirm -Best $best[0] -BaselineIP $baseline.IP
                    }
                }
            }
        }

        # 5) 行动
        $chosenSource = $null
        if ($decision.IP) {
            $chosen0 = @($candidates | Where-Object { $_.IP -eq $decision.IP } | Select-Object -First 1)
            if ($chosen0.Count -gt 0) { $chosenSource = $chosen0[0].Source }
        }

        $action = Get-DomainAction -Decision $decision -BaselineFromBlock $baselineFromBlock `
            -ChosenSource $chosenSource -Baseline $baseline -DropUnreachable:$DropUnreachable

        if ($action -eq 'update') {
            $ordered = @($decision.IP)
            if ($TopN -gt 1) {
                $chosenObj = @($candidates | Where-Object { $_.IP -eq $decision.IP } | Select-Object -First 1)
                $chosenClass = if ($chosenObj.Count -gt 0) { $chosenObj[0].Class } else { $baseline.Class }
                $chosenT = if ($chosenObj.Count -gt 0) { $chosenObj[0].Ttfb } else { $baseline.Ttfb }
                $extra = @($candidates | Where-Object {
                        $_.Ok -and $_.IP -ne $decision.IP -and $_.Class -eq $chosenClass -and
                        $_.Ttfb -le ($chosenT * 1.5)
                    } | Sort-Object @{ Expression = 'Ttfb'; Descending = $false } |
                    Select-Object -First ($TopN - 1) | ForEach-Object { $_.IP })
                $ordered += $extra
            }
            $map[$d] = $ordered
        } elseif ($action -eq 'release') {
            if ($baselineFromBlock) { $dropPrevious += $d }
        } elseif ($action -eq 'drop') {
            $dropPrevious += $d
        }

        $chosenTtfb = $null
        $displayIp = $decision.IP
        if ($decision.IP) {
            $chosen = @($candidates | Where-Object { $_.IP -eq $decision.IP } | Select-Object -First 1)
            if ($chosen.Count -gt 0) { $chosenTtfb = [math]::Round($chosen[0].Ttfb, 3) }
            elseif ($decision.IP -eq $baseline.IP) { $chosenTtfb = [math]::Round($baseline.Ttfb, 3) }
        } elseif ($action -in @('keep', 'keep-unreachable') -and $baseline.IP) {
            # 基线可用、本次没有可用候选：报告显示实际保留的地址，而不是空。
            $displayIp = $baseline.IP
            if ($baseline.Ok) { $chosenTtfb = [math]::Round($baseline.Ttfb, 3) }
        }
        $bestTtfb = if ($null -ne $decision.BestTtfb) { [math]::Round([double]$decision.BestTtfb, 3) } else { $null }
        $decisions += [pscustomobject]@{
            Domain     = $d
            BaselineIP = $baseline.IP
            BaseState  = $baseline.Class
            BaseTTFB   = if ($baseline.Ok) { [math]::Round($baseline.Ttfb, 3) } else { $null }
            ChosenIP   = $displayIp
            ChosenTTFB = $chosenTtfb
            BestTTFB   = $bestTtfb
            ImprovePct = $decision.ImprovementPct
            Reason     = $decision.Reason
            Action     = $action
        }

        $reasonText = Get-ReasonText -Reason $decision.Reason
        if ($action -eq 'update') {
            Say ("{0,-24} 切换 {1} -> {2}  [{3}]" -f $d, $baseline.IP, $decision.IP, $reasonText) 'Green'
        } elseif ($action -in @('keep', 'dns')) {
            Say ("{0,-24} 保留 {1}  [{2}]" -f $d, $displayIp, $reasonText) 'DarkGray'
        } elseif ($action -eq 'release') {
            Say ("{0,-24} 该 zone 只服务自己的 IP，删除托管条目并交还 DNS  [{1}]" -f $d, $reasonText) 'DarkGray'
        } elseif ($action -eq 'keep-unreachable') {
            Say ("{0,-24} 未验证通过，保留旧映射（-DropUnreachable 可删除）" -f $d) 'Yellow'
        } elseif ($action -eq 'drop') {
            Say ("{0,-24} 旧映射为 1034 受限，已丢弃" -f $d) 'Yellow'
        } else {
            Say ("{0,-24} 无可用候选" -f $d) 'Yellow'
        }
    }
    Stop-TaskSpinner
    Complete-Step

    # ---- 更新 hosts ----
    $updateStepName = if ($readOnly) { '生成计划' } else { '写入 hosts' }
    Start-Step $updateStepName '几秒'
    try {
        $update = Update-HostsDocument -Document $doc -VerifiedMap $map -ManagedDomains $domainList -Prune:$Prune -DropPreviousDomains $dropPrevious
    } catch {
        Fail $_.Exception.Message 4
    }

    # 删除托管条目后，如果区块外还有该域名的旧条目，hosts 仍会生效。
    if ($update.Warnings -and $update.Warnings.Count -gt 0) {
        Say ''
        Say '警告：以下域名的托管条目已移除（DryRun 下为“将移除”），但 hosts 区块外仍有条目，仍会生效：' 'Yellow'
        foreach ($w in $update.Warnings) {
            $kind = if ($w.Kind -eq 'restored') { '已恢复的旧条目' } else { '手工条目' }
            Say ("- {0} 第 {1} 行：{2}（{3}）" -f $w.Domain, $w.Line, $w.Ip, $kind) 'Yellow'
        }
        Say '如需真正交还 DNS，请手动删除或注释这些行。' 'DarkGray'
    }

    if ($readOnly) {
        if ($planMode) {
            Say 'Plan：不修改 hosts，输出 JSON 计划。计划写入：' 'Gray'
        } else {
            Say 'DryRun：不修改 hosts。计划写入：' 'Gray'
        }
        if ($update.FinalMap.Count -eq 0) {
            Say '（无变更）' 'Yellow'
        } else {
            foreach ($d in $update.FinalMap.Keys) {
                foreach ($ip in @($update.FinalMap[$d])) { Say ("{0,-16} {1}" -f $ip, $d) 'White' }
            }
        }
        Say ''
        Say "变更检测：$(if ($update.Changed) { '会修改 hosts' } else { '内容无变化，不会写入' })" 'DarkGray'

        if ($planMode) {
            try {
                $planConflict = Assert-OutputPathSafe -Path $planFile -InputPaths @($script:SafeInputPaths)
                if ($planConflict) { Fail $planConflict 2 }
                $planDoc = New-PlanDocument -Version $ScriptVersion -HostsPath $hostsPathResolved `
                    -Decisions $decisions -FinalMap $update.FinalMap -Warnings $update.Warnings -Changed $update.Changed
                $planDir = Split-Path -Parent $planFile
                if ($planDir -and -not (Test-Path -LiteralPath $planDir)) {
                    New-Item -ItemType Directory -Path $planDir -Force | Out-Null
                }
                $planDoc | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $planFile -Encoding utf8
                Say "JSON 计划：$planFile" 'Gray'
            } catch {
                Fail "写入 JSON 计划失败：$($_.Exception.Message)" 4
            }
        }
    } else {
        $backupDir = Get-HostsBackupDir -HostsPath $hostsPathResolved -FallbackRoot $Root
        try {
            $write = Write-HostsDocument -Document $doc -Update $update -BackupDir $backupDir -Version $ScriptVersion
        } catch {
            Fail $_.Exception.Message 4
        }
        if ($write.Changed) {
            Say "已写入 hosts（备份：$($write.Backup)）" 'Green'
            if ($write.Warning) { Say "警告：$($write.Warning)" 'Yellow' }
        } else {
            Say 'hosts 内容无变化，未写入。' 'Green'
        }
        $script:RunChanged = [bool]$write.Changed
        $script:RunCommittedAt = $write.CommittedAt
        $flush = Clear-DnsCache
        if (-not $flush.Ok) { Say "警告：flushdns 失败：$($flush.Output)" 'Yellow' }
    }
    Complete-Step

    # ---- 解析核对 ----
    if ($CheckResolved) {
        Say ''
        Say '解析核对（系统实际返回的地址）：' 'White'
        foreach ($d in $domainList) {
            try {
                $addrs = @([System.Net.Dns]::GetHostAddresses($d) | ForEach-Object { $_.IPAddressToString })
                Say ("{0,-24} {1}" -f $d, ($addrs -join ', ')) 'Gray'
            } catch {
                Say ("{0,-24} 解析失败" -f $d) 'Yellow'
            }
        }
    }

    # ---- 报告 ----
    if ($script:RunWatch) { $script:RunWatch.Stop() }
    if ($decisions.Count -gt 0) {
        $byAction = @{}
        foreach ($d in $decisions) { $byAction[$d.Action] = 1 + [int]$byAction[$d.Action] }
        $parts = @()
        foreach ($pair in @(
                @('update', '更新'), @('keep', '保留'), @('dns', '沿用 DNS'), @('release', '交还 DNS'),
                @('drop', '丢弃'), @('keep-unreachable', '保留（未验证）'), @('none', '未写入')
            )) {
            $n = [int]$byAction[$pair[0]]
            if ($n -gt 0) { $parts += "$($pair[1]) $n" }
        }
        if ($parts.Count -eq 0) { $parts += '无变更' }
        $elapsed = if ($script:RunWatch) { Format-Duration -Duration $script:RunWatch.Elapsed } else { '' }
        $summaryText = "{0} · 用时 {1}" -f ($parts -join ' · '), $elapsed
        Say "结果：$summaryText" 'White'
        $script:RunSummaryLine = $summaryText
        $script:RunCounts = @{
            updated    = [int]$byAction['update']
            kept       = [int]$byAction['keep'] + [int]$byAction['dns']
            unverified = [int]$byAction['keep-unreachable'] + [int]$byAction['none'] + [int]$byAction['drop']
        }

        Say ''
        Say '==== 逐域名决策 ====' 'Cyan'
        $decisions | Select-Object Domain, BaselineIP, BaseState, BaseTTFB, ChosenIP, ChosenTTFB, BestTTFB, ImprovePct,
            @{ Name = 'Reason'; Expression = { Get-ReasonText -Reason $_.Reason } },
            @{ Name = 'Action'; Expression = { Get-ActionText -Action $_.Action } } |
            Format-Table -AutoSize | Out-String -Width 260 | ForEach-Object { Say $_.Trim() }
    }

    Say ''
    Say '说明：' 'Cyan'
    $unreachable = @($decisions | Where-Object { $_.Action -eq 'keep-unreachable' } | ForEach-Object { $_.Domain })
    if ($unreachable.Count -gt 0) {
        Say '以下域名本次未验证通过，已保留旧映射（-DropUnreachable 可删除）：' 'Yellow'
        foreach ($f in $unreachable) { Say "- $f" 'DarkGray' }
    }
    $failed = @($decisions | Where-Object { $_.Action -in @('drop', 'none') } | ForEach-Object { $_.Domain })
    if ($failed.Count -gt 0) {
        Say '以下域名没有可用候选（可能非 CF、不可用或边缘受限），未写入：' 'Yellow'
        foreach ($f in $failed) { Say "- $f" 'DarkGray' }
    }
    Say 'hosts 只影响这些域名的网页/tracker；P2P 和 IPv6 对等连接不受影响。' 'DarkGray'
    Say '写入 A 记录后，Windows 通常不再使用 DNS 的 AAAA；应用自带解析器可能不同。' 'DarkGray'
    Say '回滚：.\Cloudflare-Hosts-Optimizer.ps1 -Rollback' 'DarkGray'
    if ($script:ReportPathResolved) { Say "报告：$($script:ReportPathResolved)" 'DarkGray' }

    return 0
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
$script:ReportPathResolved = $ReportPath
if (-not $script:ReportPathResolved -and -not $DryRun -and -not $Plan -and -not $PlanPath -and -not $Version -and -not $Rollback -and -not $Doctor -and -not $InstallTask -and -not $UninstallTask) {
    $script:ReportPathResolved = Join-Path $Root 'last-report.txt'
}

# ---- 入口先做一次路径碰撞检查 ----
# 参数错误时尾部也会写报告（在 catch 之后），所以必须在这里拦下，不能只靠 Invoke-Main。
$script:SafeInputPaths = @()
$entryDomains = if ($DomainsFile) { $DomainsFile } else { Join-Path $Root 'domains.txt' }
$entryPlan = if ($PlanPath) { $PlanPath } else { Join-Path $Root 'plan.json' }
$entryColo = if ($ColoCachePath) { $ColoCachePath } else { Get-ColoCacheDefaultPath -Root $Root }
$entryInputs = @(Get-ProtectedInputPaths -HostsPath $HostsPath -DomainsFile $entryDomains -RollbackFrom $RollbackFrom)
$entryOutputs = @($script:ReportPathResolved, $entryPlan, $entryColo, (Join-Path $Root 'last-run.json'))
$entryErrors = @()
for ($i = 0; $i -lt $entryOutputs.Count; $i++) {
    $out = $entryOutputs[$i]
    if (-not $out) { continue }
    # 按槽位排除自己；不能按“值相等”过滤，否则 PlanPath 与 ReportPath 相同时两条都会被滤掉
    $others = @()
    for ($j = 0; $j -lt $entryOutputs.Count; $j++) {
        if ($j -ne $i -and $entryOutputs[$j]) { $others += $entryOutputs[$j] }
    }
    $conflict = Assert-OutputPathSafe -Path $out -InputPaths $entryInputs -OtherOutputs $others
    if ($conflict) { $entryErrors += $conflict }
}
if ($entryErrors.Count -gt 0) {
    foreach ($e in @($entryErrors | Select-Object -Unique)) { [Console]::Error.WriteLine("错误：$e") }
    exit 2
}

$script:RunId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$script:RunStarted = Get-Date
$script:RunMode = ''
$script:RunHostsPath = ''
$script:RunChanged = $false
$script:RunCommittedAt = $null
$script:RunCounts = @{ updated = 0; kept = 0; unverified = 0 }
$script:RunSummaryLine = ''

$script:ExitCode = 0
try {
    Invoke-Main | Out-Null
} catch {
    Stop-TaskSpinner
    # 异常消息可能夹带用户原样输入的 URL（含 passkey），统一脱敏后再输出/落盘
    $msg = Protect-ErrorMessage -Text $_.Exception.Message
    Write-Host "错误：$msg" -ForegroundColor Red
    $script:Log.Add("ERROR: $msg")
    $script:ExitCode = if ($script:FailCode) { $script:FailCode } else { 1 }
    if (-not $script:RunSummaryLine) { $script:RunSummaryLine = "失败：$msg" }
}

if ($script:ReportPathResolved) {
    # 写盘前再确认一次：扫描过程中目标可能被换成 hosts 的别名
    $reportConflict = Assert-OutputPathSafe -Path $script:ReportPathResolved -InputPaths @($script:SafeInputPaths)
    if ($reportConflict) {
        Write-Host "警告：报告没有写入。$reportConflict" -ForegroundColor Yellow
    } else {
        try {
            $runModeText = switch ($script:RunMode) {
                'write' { '写入 hosts' } 'dryrun' { 'DryRun' } 'plan' { 'Plan' } 'rollback' { '回滚' } default { '' }
            }
            $header = @(
                "# Cloudflare-Hosts-Optimizer $ScriptVersion"
                "runId: $($script:RunId)"
                "模式: $runModeText"
                "退出码: $($script:ExitCode)"
                "结果: $($script:RunSummaryLine)"
                "生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                '注意：本报告含站点清单与详细日志，分享前请先检查。'
                '=== 详细日志 ==='
            )
            ($header + $script:Log) | Out-File -LiteralPath $script:ReportPathResolved -Encoding utf8
        } catch {
            Write-Host "警告：报告写入失败：$(Protect-ErrorMessage -Text $_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# 运行摘要只用于菜单展示；失败不影响退出码
if ($script:RunMode) {
    $summaryPath = Join-Path $Root 'last-run.json'
    $summaryConflict = Assert-OutputPathSafe -Path $summaryPath -InputPaths @($script:SafeInputPaths)
    if (-not $summaryConflict) {
        try {
            $run = New-RunSummaryRecord -Mode $script:RunMode -HostsPath $script:RunHostsPath `
                -StartedAt $script:RunStarted -FinishedAt (Get-Date) -ExitCode $script:ExitCode `
                -Changed ([bool]$script:RunChanged) -Updated ([int]$script:RunCounts.updated) `
                -Kept ([int]$script:RunCounts.kept) -Unverified ([int]$script:RunCounts.unverified) `
                -RunId $script:RunId -CommittedAt $script:RunCommittedAt
            $null = Write-RunSummary -Path $summaryPath -Run $run `
                -Committed:([bool]$script:RunChanged -and $null -ne $script:RunCommittedAt) -CommitMode $script:RunMode
        } catch { }
    }
}

exit $script:ExitCode
