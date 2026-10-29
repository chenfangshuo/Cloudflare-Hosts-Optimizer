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
      * 验证失败的域名保留上一次的映射；只有 -Prune 才删除。
      * 只向测速地址做批量请求；对目标站仅每域名每 IP 1 次 HEAD。
      * 不登录、不带 Cookie、不访问 announce URL。

.PARAMETER DryRun
    只扫描和验证，不修改 hosts。

.PARAMETER Rollback
    用最近一次备份恢复 hosts。可在 domains.txt 缺失时使用。

.PARAMETER Version
    打印版本号并退出。

.PARAMETER Force
    与 -Rollback 同用时允许覆盖写入后被其他程序修改过的 hosts；
    与正常流程同用时允许在检测到 TUN 网卡后继续。

.PARAMETER Prune
    删除不再出现在 domains.txt 中的历史托管映射（默认保留）。

.PARAMETER CheckResolved
    写入后解析每个域名，报告系统实际返回的地址（用于核对是否走 IPv4）。

.PARAMETER ExperimentalRanges
    允许扫描 CF 官方列表之外的实验网段（104.28.0.0/14）。

.PARAMETER TopN
    每个域名写入的 IP 数（1-3，默认 1）。hosts 不保证多行之间的故障转移。

.PARAMETER Domains
    域名列表，优先于 -DomainsFile。

.PARAMETER DomainsFile
    域名文件，默认 .\domains.txt。

.PARAMETER CfstPath
    cfst.exe 路径；不提供则自动查找 .\cfst\cfst.exe。

.PARAMETER SpeedTestUrl
    吞吐测速地址，支持 {bytes} 占位符。必须是 https，且由 Cloudflare 托管。

.PARAMETER HostsPath
    高级选项：hosts 文件路径，默认系统 hosts。用于测试/沙箱。

.PARAMETER ReportPath
    报告文件路径。默认正常运行时写 .\last-report.txt；-DryRun 默认不写。

.EXAMPLE
    .\pt-cf-optimize.ps1 -DryRun

.EXAMPLE
    .\pt-cf-optimize.ps1

.EXAMPLE
    .\pt-cf-optimize.ps1 -Rollback

.EXAMPLE
    .\pt-cf-optimize.ps1 -Prune -TopN 1
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Rollback,
    [switch]$Version,
    [switch]$NoCfst,
    [switch]$Force,
    [switch]$Prune,
    [switch]$CheckResolved,
    [switch]$ExperimentalRanges,
    [switch]$DropUnreachable,
    [ValidateRange(1, 3)][int]$TopN = 1,
    [ValidateRange(1, 5)][int]$CandidatesPerDomain = 3,
    [ValidateRange(0, 5)][int]$BackfillCandidates = 1,
    [ValidateRange(1, 16)][int]$MaxDomainProbes = 6,
    [ValidateRange(2, 15)][int]$VerifyTimeoutSec = 5,
    [ValidateRange(0, 100)][int]$MinImprovementPct = 15,
    [ValidateRange(0, 20)][int]$ConfirmThresholdPct = 5,
    [string[]]$Domains,
    [string]$DomainsFile,
    [string]$CfstPath,
    [string]$SpeedTestUrl = 'https://speed.cloudflare.com/__down?bytes={bytes}',
    [string]$HostsPath,
    [string]$ReportPath,
    [ValidateRange(1, 5)][int]$ScanSamples = 2,
    [ValidateRange(16, 512)][int]$MaxCandidates = 192,
    [ValidateRange(4, 64)][int]$ThroughputCandidates = 32,
    [ValidateRange(1, 3)][int]$ThroughputSamples = 1,
    [ValidateRange(500000, 20000000)][int]$ThroughputBytes = 1000000,
    [ValidateRange(1, 16)][int]$RefineTop = 6,    [ValidateRange(0, 5000)][int]$VerifyDelayMs = 400
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '0.3.1'

# -Version 放在加载 lib 之前，库缺失/损坏时也能用
if ($Version) {
    [Console]::Out.WriteLine("pt-cf-optimize $ScriptVersion")
    exit 0
}

$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:RepoRoot = $Root

. (Join-Path $Root 'lib\Domains.ps1')
. (Join-Path $Root 'lib\HostsFile.ps1')
. (Join-Path $Root 'lib\Probe.ps1')

$script:Log = [System.Collections.Generic.List[string]]::new()
$script:FailCode = 0

function Say {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    $script:Log.Add($Text)
}

function Fail {
    param([string]$Message, [int]$Code = 1)
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

function Find-Cfst {
    param([string]$Explicit)
    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
        throw "指定的 cfst.exe 不存在：$Explicit"
    }
    foreach ($c in @((Join-Path $Root 'cfst\cfst.exe'), (Join-Path $Root 'cfst.exe'))) {
        if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
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

function Test-BypassStrict {
    param([string]$Domain, [string]$Bypass)
    foreach ($raw in ($Bypass -split ';')) {
        $e = $raw.Trim()
        if (-not $e -or $e -eq '<local>') { continue }
        if ($e.Contains('*')) {
            if ($Domain -like $e) { return $true }
        } elseif ($Domain -ieq $e) {
            return $true
        }
    }
    return $false
}

function Show-ProxyCheck {
    param([string[]]$TargetDomains)
    $p = Get-ProxyState
    if (-not $p.Enabled) {
        Say '代理：未启用 WinINET 系统代理（这不排除 PAC/TUN/应用级代理）。' 'Yellow'
        return
    }
    Say "代理：WinINET 系统代理已开启 -> $($p.Server)" 'Yellow'
    $missing = @($TargetDomains | Where-Object { -not (Test-BypassStrict -Domain $_ -Bypass $p.Bypass) })
    if ($missing.Count -eq 0) {
        Say '旁路：目标域名均在 ProxyOverride 中（仅代表 WinINET 层直连）。' 'Green'
    } else {
        Say '旁路：以下域名不在 ProxyOverride 中，可能走代理、导致出口 IP 变化：' 'Red'
        foreach ($m in $missing) { Say "  - $m" 'Red' }
    }
}

function Test-TunAdapter {
    $tun = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'TAP|TUN|Wintun|WireGuard|Tailscale|Clash|Mihomo'
        })
    if ($tun.Count -gt 0) {
        Say '警告：检测到可能处于 TUN 模式的网卡（可能接管流量）：' 'Red'
        foreach ($t in $tun) { Say "  - $($t.Name) / $($t.InterfaceDescription)" 'Red' }
        return $true
    }
    Say '网卡：未发现已知 TUN 虚拟网卡（这不等于已证明直连）。' 'Green'
    return $false
}

function Invoke-Main {
    $hostsPathResolved = if ($HostsPath) { $HostsPath } else { Join-Path $env:SystemRoot 'System32\drivers\etc\hosts' }
    $domainsFileResolved = if ($DomainsFile) { $DomainsFile } else { Join-Path $Root 'domains.txt' }

    if ($Rollback -and $DryRun) { Fail '-Rollback 不能与 -DryRun 同时使用。' 2 }

    if ($Rollback) {
        Assert-AdminForPath $hostsPathResolved
        $backupDir = Get-HostsBackupDir -HostsPath $hostsPathResolved -FallbackRoot $Root
        $r = Invoke-HostsRollback -HostsPath $hostsPathResolved -BackupDir $backupDir -LegacyBackupDir (Join-Path $Root 'backup') -Force:$Force
        $flush = Clear-DnsCache
        Say "已恢复 hosts：$($r.Restored)" 'Green'
        if (-not $flush.Ok) { Say "警告：flushdns 失败：$($flush.Output)" 'Yellow' }
        return 0
    }

    # ---- 域名 ----
    $domainList = @()
    if ($Domains) {
        foreach ($d in $Domains) {
            $n = ConvertTo-NormalizedDomain -Value $d -Strict
            if (-not $n) { Fail "非法域名：$d" 2 }
            $domainList += $n
        }
    } else {
        $res = Read-DomainsFile -Path $domainsFileResolved
        if ($res.Invalid.Count -gt 0) {
            Fail ("域名文件含非法项：{0}" -f ($res.Invalid -join ', ')) 2
        }
        $domainList = @($res.Domains)
    }
    $domainList = @($domainList | Select-Object -Unique)
    if ($domainList.Count -eq 0) {
        Fail "没有配置任何域名。请复制 domains.example.txt 为 domains.txt 并填入目标域名，或用 -Domains 指定。当前路径：$domainsFileResolved" 2
    }

    if (-not $DryRun) { Assert-AdminForPath $hostsPathResolved }
    $curlExe = Get-CurlExe

    Say ''
    Say '==== Cloudflare 优选 IP -> hosts ====' 'Cyan'
    Say "hosts: $hostsPathResolved" 'DarkGray'
    Say "域名数: $($domainList.Count)" 'DarkGray'
    Say ''

    Show-ProxyCheck -TargetDomains $domainList
    $tun = Test-TunAdapter
    if ($tun -and -not $DryRun -and -not $Force) {
        Fail '检测到 TUN 网卡。为避免测速和访问走代理，已中止；确认风险后加 -Force 继续。' 3
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
            Fail "hosts 中存在需要人工处理的映射，已中止且未修改：$details" 4
        }
    } catch {
        if ($script:FailCode) { throw }
        Fail $_.Exception.Message 4
    }

    # ---- 延迟筛选 ----
    $ranges = Get-CfRanges -Experimental:$ExperimentalRanges
    $latency = @()
    $cfst = $null
    if (-not $NoCfst) {
        try { $cfst = Find-Cfst -Explicit $CfstPath }
        catch { Fail $_.Exception.Message 2 }
    }

    if ($cfst) {
        Say "使用 CFST 做全量延迟扫描：$cfst" 'Cyan'
        try { $latency = @(Invoke-CfstLatencyScan -Exe $cfst -Ranges $ranges) }
        catch { Say "CFST 运行失败：$($_.Exception.Message)" 'Yellow'; $latency = @() }
        if ($latency.Count -eq 0) { Say 'CFST 没有产出结果，改用内置扫描。' 'Yellow' }
    }
    if ($latency.Count -eq 0) {
        if ($NoCfst) { Say '已指定 -NoCfst，使用内置扫描。' 'Yellow' }
        elseif (-not $cfst) { Say '未找到 cfst.exe，使用内置扫描。' 'Yellow' }
        $latency = @(Invoke-BuiltinLatencyScan -CurlExe $curlExe -Candidates $MaxCandidates -Samples $ScanSamples -Ranges $ranges)
    }
    if ($latency.Count -eq 0) { Fail '没有扫到任何可用 IP。请检查网络后重试。' 3 }

    $latency = @($latency | Sort-Object Ttfb)
    Say "延迟/丢包筛选后可用 IP：$($latency.Count)，最佳 $($latency[0].IP)（$([math]::Round($latency[0].Ttfb * 1000))ms）" 'Gray'

    $avgTtfb = ($latency | Select-Object -First 10 | Measure-Object -Property Ttfb -Average).Average
    if ($avgTtfb -lt 0.005) {
        Say '警告：平均延迟异常低（<5ms），测速可能经过了代理。结果仅供参考。' 'Yellow'
    }

    # ---- 机房分层 ----
    $pool = @($latency | Select-Object -First ([int][math]::Min(256, $latency.Count)))
    Say "探测候选落地区域（$($pool.Count) 个）..." 'Cyan'
    $pool = @(Resolve-Colo -CurlExe $curlExe -Candidates $pool)
    $candidates = @(Select-Stratified -Candidates $pool -Count $ThroughputCandidates)
    $coloSummary = (@($candidates | Group-Object Colo | ForEach-Object {
                $name = if ($_.Name) { $_.Name } else { '??' }
                "$name x$($_.Count)"
            })) -join ', '
    Say "分层抽样 $($candidates.Count) 个（$coloSummary）" 'Gray'

    # ---- 吞吐初测 ----
    $quick = @(Invoke-ThroughputTest -CurlExe $curlExe -Candidates $candidates -Samples $ThroughputSamples -Bytes $ThroughputBytes -UrlTemplate $SpeedTestUrl -ThrottleLimit 6)
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
        $final = @(Invoke-ThroughputTest -CurlExe $curlExe -Candidates $promoted -Samples 3 -Bytes 2097152 -UrlTemplate $SpeedTestUrl -ThrottleLimit 1 -MaxTime 15)
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
        Say '决赛结果（只使用决赛成绩）：' 'Cyan'
        $finalRows | Select-Object IP, Colo, Loss, Ttfb, SpeedMBps, Valid |
            Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Say $_.TrimEnd() }

        $rankedFinal = @($finalRows | Where-Object { $_.Valid -ge 2 -and $_.SpeedMBps -gt 0 } |
            Sort-Object @{ Expression = 'SpeedMBps'; Descending = $true }, @{ Expression = 'Ttfb'; Descending = $false })
        $globalCandidates = @($rankedFinal | Select-Object -First $CandidatesPerDomain)
        $reserveCandidates = @($rankedFinal | Select-Object -Skip $CandidatesPerDomain -First $BackfillCandidates)
    } else {
        Say '警告：没有候选通过吞吐初测，本次只做基线与兜底检查。' 'Yellow'
    }

    Say ''
    Say '全局候选（逐域名只从这里取前几个，按基线决定是否切换）：' 'Cyan'
    if ($globalCandidates.Count -gt 0) {
        $globalCandidates | Select-Object IP, Colo, Ttfb, SpeedMBps |
            Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Say $_.TrimEnd() }
    } else {
        Say '  （无）' 'Yellow'
    }
    if ($reserveCandidates.Count -gt 0) {
        Say '补位候选（前几个都不可用时才测）：' 'Cyan'
        $reserveCandidates | Select-Object IP, Colo, Ttfb, SpeedMBps |
            Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Say $_.TrimEnd() }
    }
    Say ''

    # ---- 逐域名选择：基线 = 当前 hosts/DNS 路径 ----
    $map = @{}
    $decisions = @()
    $dropPrevious = @()

    Say '逐域名验证与选择（基线 = 当前 hosts/DNS 路径）...' 'Cyan'
    foreach ($d in $domainList) {
        # 1) 基线：不指定 IP，走系统当前路径
        $baseResult = Test-DomainIp -Domain $d -CurlExe $curlExe -NoResolve -MaxTime $VerifyTimeoutSec
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
            $r = Test-DomainIp -Domain $d -Ip $p.IP -CurlExe $curlExe -MaxTime $VerifyTimeoutSec
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
                $r = Test-DomainIp -Domain $d -Ip $p.IP -CurlExe $curlExe -MaxTime $VerifyTimeoutSec
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
                $r = Test-DomainIp -Domain $d -Ip $ip -CurlExe $curlExe -MaxTime $VerifyTimeoutSec
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
                $r = Test-DomainIp -Domain $d -Ip $ip -CurlExe $curlExe -MaxTime $VerifyTimeoutSec
                $candidates += [pscustomobject]@{
                    IP = $ip; Colo = ''; Ok = $r.Ok; Class = $r.Class; Ttfb = $r.Ttfb; Source = 'dns'
                }
                [void]$seen.Add($ip)
                Start-Sleep -Milliseconds $VerifyDelayMs
            }
        }

        # 4) 选择：只有改善足够或基线失败才切换
        $decision = Select-DomainIp -Baseline $baseline -Candidates $candidates -MinImprovementPct $MinImprovementPct

        # 4b) 改善接近阈值时，基线和最佳候选各复核一次
        if ($ConfirmThresholdPct -gt 0 -and $baseline.Ok -and $null -ne $decision.ImprovementPct -and
            [math]::Abs([double]$decision.ImprovementPct - $MinImprovementPct) -le $ConfirmThresholdPct) {
            $best = @($candidates | Where-Object { $_.Ok -and $_.IP } |
                Sort-Object @{ Expression = { if ($_.Class -eq 'ok') { 0 } else { 1 } } },
                            @{ Expression = 'Ttfb'; Descending = $false } |
                Select-Object -First 1)
            if ($best.Count -gt 0) {
                $b2 = Test-DomainIp -Domain $d -CurlExe $curlExe -NoResolve -MaxTime $VerifyTimeoutSec
                Start-Sleep -Milliseconds $VerifyDelayMs
                $c2 = Test-DomainIp -Domain $d -Ip $best[0].IP -CurlExe $curlExe -MaxTime $VerifyTimeoutSec
                if ($b2.Ok -and $c2.Ok) {
                    $avgBase = ($baseline.Ttfb + $b2.Ttfb) / 2.0
                    $avgBest = ($best[0].Ttfb + $c2.Ttfb) / 2.0
                    $baseline = [pscustomobject]@{ IP = $baseline.IP; Ok = $true; Class = $baseline.Class; Ttfb = $avgBase }
                    $candidates = @($candidates | ForEach-Object {
                            if ($_.IP -eq $best[0].IP) {
                                [pscustomobject]@{ IP = $_.IP; Colo = $_.Colo; Ok = $_.Ok; Class = $_.Class; Ttfb = $avgBest; Source = $_.Source }
                            } else { $_ }
                        })
                    $decision = Select-DomainIp -Baseline $baseline -Candidates $candidates -MinImprovementPct $MinImprovementPct
                }
                Start-Sleep -Milliseconds $VerifyDelayMs
            }
        }

        # 5) 行动
        if ($decision.Changed -and $decision.IP) {
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
            $action = 'update'
        } elseif ($decision.IP) {
            $action = if ($baselineFromBlock) { 'keep' } else { 'dns' }
        } else {
            $action = Get-PreviousAction -HasPrevious:$baselineFromBlock -Baseline $baseline -Decision $decision -DropUnreachable:$DropUnreachable
            if ($action -eq 'drop') { $dropPrevious += $d }
        }

        $chosenTtfb = $null
        if ($decision.IP) {
            $chosen = @($candidates | Where-Object { $_.IP -eq $decision.IP } | Select-Object -First 1)
            if ($chosen.Count -gt 0) { $chosenTtfb = [math]::Round($chosen[0].Ttfb, 2) }
            elseif ($decision.IP -eq $baseline.IP) { $chosenTtfb = [math]::Round($baseline.Ttfb, 2) }
        }
        $decisions += [pscustomobject]@{
            Domain     = $d
            BaselineIP = $baseline.IP
            BaseState  = $baseline.Class
            BaseTTFB   = if ($baseline.Ok) { [math]::Round($baseline.Ttfb, 2) } else { $null }
            ChosenIP   = $decision.IP
            ChosenTTFB = $chosenTtfb
            ImprovePct = $decision.ImprovementPct
            Reason     = $decision.Reason
            Action     = $action
        }

        if ($action -eq 'update') {
            Say ("  {0,-24} 切换 {1} -> {2}  [{3}]" -f $d, $baseline.IP, $decision.IP, $decision.Reason) 'Green'
        } elseif ($action -in @('keep', 'dns')) {
            Say ("  {0,-24} 保留 {1}  [{2}]" -f $d, $decision.IP, $decision.Reason) 'DarkGray'
        } elseif ($action -eq 'keep-unreachable') {
            Say ("  {0,-24} 未验证通过，保留旧映射（-DropUnreachable 可删除）" -f $d) 'Yellow'
        } elseif ($action -eq 'drop') {
            Say ("  {0,-24} 旧映射为 1034 受限，已丢弃" -f $d) 'Yellow'
        } else {
            Say ("  {0,-24} 无可用候选" -f $d) 'Yellow'
        }
    }
    Say ''

    # ---- 更新 hosts ----
    try {
        $update = Update-HostsDocument -Document $doc -VerifiedMap $map -ManagedDomains $domainList -Prune:$Prune -DropPreviousDomains $dropPrevious
    } catch {
        Fail $_.Exception.Message 4
    }

    if ($DryRun) {
        Say 'DryRun：不修改 hosts。计划写入：' 'Cyan'
        if ($update.FinalMap.Count -eq 0) {
            Say '  （无变更）' 'Yellow'
        } else {
            foreach ($d in $update.FinalMap.Keys) {
                foreach ($ip in @($update.FinalMap[$d])) { Say ("  {0,-16} {1}" -f $ip, $d) 'White' }
            }
        }
        Say ''
        Say "变更检测：$(if ($update.Changed) { '会修改 hosts' } else { '内容无变化，不会写入' })" 'DarkGray'
    } else {
        $backupDir = Get-HostsBackupDir -HostsPath $hostsPathResolved -FallbackRoot $Root
        try {
            $write = Write-HostsDocument -Document $doc -Update $update -BackupDir $backupDir -Version $ScriptVersion
        } catch {
            Fail $_.Exception.Message 4
        }
        if ($write.Changed) {
            Say "已写入 hosts（备份：$($write.Backup)）" 'Green'
        } else {
            Say 'hosts 内容无变化，未写入。' 'Green'
        }
        $flush = Clear-DnsCache
        if (-not $flush.Ok) { Say "警告：flushdns 失败：$($flush.Output)" 'Yellow' }
    }

    # ---- 解析核对 ----
    if ($CheckResolved) {
        Say ''
        Say '解析核对（系统实际返回的地址）：' 'Cyan'
        foreach ($d in $domainList) {
            try {
                $addrs = @([System.Net.Dns]::GetHostAddresses($d) | ForEach-Object { $_.IPAddressToString })
                Say ("  {0,-24} {1}" -f $d, ($addrs -join ', ')) 'Gray'
            } catch {
                Say ("  {0,-24} 解析失败" -f $d) 'Yellow'
            }
        }
    }

    # ---- 报告 ----
    if ($decisions.Count -gt 0) {
        Say ''
        Say '==== 逐域名决策 ====' 'Cyan'
        $decisions | Select-Object Domain, BaselineIP, BaseState, BaseTTFB, ChosenIP, ChosenTTFB, ImprovePct, Reason, Action |
            Format-Table -AutoSize | Out-String -Width 260 | ForEach-Object { Say $_.TrimEnd() }
    }

    Say ''
    Say '说明：' 'Cyan'
    $unreachable = @($decisions | Where-Object { $_.Action -eq 'keep-unreachable' } | ForEach-Object { $_.Domain })
    if ($unreachable.Count -gt 0) {
        Say '以下域名本次未验证通过，已保留旧映射（-DropUnreachable 可删除）：' 'Yellow'
        foreach ($f in $unreachable) { Say "  - $f" 'DarkGray' }
    }
    $failed = @($decisions | Where-Object { $_.Action -in @('drop', 'none') } | ForEach-Object { $_.Domain })
    if ($failed.Count -gt 0) {
        Say '以下域名没有可用候选（可能非 CF、不可用或边缘受限），未写入：' 'Yellow'
        foreach ($f in $failed) { Say "  - $f" 'DarkGray' }
    }
    Say 'hosts 只影响这些域名的网页/tracker；P2P 和 IPv6 对等连接不受影响。' 'DarkGray'
    Say '写入 A 记录后，Windows 通常不再使用 DNS 的 AAAA；应用自带解析器可能不同。' 'DarkGray'
    Say '回滚：.\pt-cf-optimize.ps1 -Rollback' 'DarkGray'
    if ($script:ReportPathResolved) { Say "报告：$($script:ReportPathResolved)" 'DarkGray' }

    return 0
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
$script:ReportPathResolved = $ReportPath
if (-not $script:ReportPathResolved -and -not $DryRun -and -not $Version -and -not $Rollback) {
    $script:ReportPathResolved = Join-Path $Root 'last-report.txt'
}

$script:ExitCode = 0
try {
    Invoke-Main | Out-Null
} catch {
    $msg = $_.Exception.Message
    Write-Host "错误：$msg" -ForegroundColor Red
    $script:Log.Add("ERROR: $msg")
    $script:ExitCode = if ($script:FailCode) { $script:FailCode } else { 1 }
}

if ($script:ReportPathResolved) {
    try {
        $script:Log | Out-File -LiteralPath $script:ReportPathResolved -Encoding utf8
    } catch {
        Write-Host "警告：报告写入失败：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

exit $script:ExitCode
