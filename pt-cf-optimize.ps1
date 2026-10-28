#Requires -Version 7.0
<#
.SYNOPSIS
    优选 Cloudflare 边缘 IP 并写入 Windows hosts（适用于 PT 站等 CF 托管站点）。

.DESCRIPTION
    流程：CFST 全量测延迟/丢包 -> 取延迟最低的一批 -> 本脚本独立测吞吐
          -> 按落地机房分层抽样 -> 按实测吞吐排序
          -> 对每个域名做连通性验证 -> 备份 hosts -> 只替换标记区块 -> 刷新 DNS。

    为什么不用 CFST 的下载测速：
      CFST 的默认测速地址可能失效（例如 cf.xiu2.xyz/url 返回 403），
      会把错误页算出虚高速度。所以 CFST 只用 -dd（纯延迟/丢包），
      吞吐量由本脚本直接请求 -SpeedTestUrl 实测，不依赖第三方测速地址。

    安全边界：
      * 只改 hosts 中本脚本管理的域名，其余内容逐字节保留。
      * 只向测速地址做批量扫描；对目标站仅每域名每 IP 发 1 次 HEAD。
      * 不登录、不带 Cookie、不爬页面、不改系统 DNS/网卡/防火墙/代理配置。
      * 不改变出口 IP（前提：目标域名在代理旁路里）。

.PARAMETER DryRun
    只扫描和验证，不写 hosts。

.PARAMETER Rollback
    用最近一次备份恢复 hosts。

.PARAMETER TopN
    最终写入的 IP 数量（1-3，默认 2）。每个域名逐个验证，只写验证通过的 IP。

.PARAMETER Domains
    域名列表，优先于 -DomainsFile。

.PARAMETER DomainsFile
    域名文件，默认 .\domains.txt。每行一个域名，# 开头为注释。

.PARAMETER CfstPath
    CloudflareSpeedTest 的 cfst.exe 路径。不提供则自动查找 .\cfst\cfst.exe；
    找不到就用内置 PowerShell 扫描。

.PARAMETER SpeedTestUrl
    吞吐测速地址，支持 {bytes} 占位符。
    默认 https://speed.cloudflare.com/__down?bytes={bytes}。

.PARAMETER NoCfst
    不查找 cfst.exe，强制使用内置扫描。

.PARAMETER Version
    打印版本号并退出。

.EXAMPLE
    .\pt-cf-optimize.ps1 -DryRun

.EXAMPLE
    .\pt-cf-optimize.ps1

.EXAMPLE
    .\pt-cf-optimize.ps1 -Rollback
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Rollback,
    [switch]$Version,
    [switch]$NoCfst,
    [ValidateRange(1, 3)][int]$TopN = 2,
    [string[]]$Domains,
    [string]$DomainsFile,
    [string]$CfstPath,
    [string]$SpeedTestUrl = 'https://speed.cloudflare.com/__down?bytes={bytes}',
    [ValidateRange(1, 5)][int]$ScanSamples = 2,
    [ValidateRange(16, 512)][int]$MaxCandidates = 192,
    [ValidateRange(4, 64)][int]$ThroughputCandidates = 32,
    [ValidateRange(1, 3)][int]$ThroughputSamples = 1,
    [ValidateRange(500000, 20000000)][int]$ThroughputBytes = 1000000,
    [ValidateRange(0, 16)][int]$RefineTop = 6,
    [ValidateRange(0, 5000)][int]$VerifyDelayMs = 400
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
$ScriptVersion = '0.1.0'

$BeginMarker = '# >>> pt-cf-optimize BEGIN (auto-generated; -Rollback to undo) >>>'
$EndMarker = '# <<< pt-cf-optimize END <<<'
$LegacyTag = '# [pt-cf-optimize] '

$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$BackupDir = Join-Path $Root 'backup'
$ReportPath = Join-Path $Root 'last-report.txt'
$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'

$script:Log = [System.Collections.Generic.List[string]]::new()

if ($Version) {
    Write-Output "pt-cf-optimize $ScriptVersion"
    return
}

if (-not $DomainsFile) { $DomainsFile = Join-Path $Root 'domains.txt' }

function Read-DomainsFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $result = @()
    foreach ($raw in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $hostName = ($line -split '\s+')[0].TrimEnd('.').ToLowerInvariant()
        if ($hostName) { $result += $hostName }
    }
    return $result
}

if (-not $Domains -or $Domains.Count -eq 0) {
    $Domains = @(Read-DomainsFile -Path $DomainsFile)
}
if (-not $Domains -or $Domains.Count -eq 0) {
    throw "没有配置任何域名。请复制 domains.example.txt 为 domains.txt 并填入目标域名，或用 -Domains 指定。当前路径：$DomainsFile"
}
$Domains = @($Domains | ForEach-Object { $_.Trim().TrimEnd('.').ToLowerInvariant() } |
    Where-Object { $_ } | Select-Object -Unique)

function Say {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    $script:Log.Add($Text)
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '需要管理员权限。请右键 PowerShell 7 -> 以管理员身份运行，再执行本脚本。'
    }
}

function Get-CurlExe {
    $c = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $c) { throw '找不到 curl.exe（Windows 10/11 自带）。' }
    return $c.Source
}

# ---------------------------------------------------------------------------
# 备份 / 回滚
# ---------------------------------------------------------------------------
function Backup-Hosts {
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest = Join-Path $BackupDir "hosts-$stamp.bak"
    Copy-Item -LiteralPath $HostsPath -Destination $dest -Force
    Get-ChildItem -LiteralPath $BackupDir -Filter 'hosts-*.bak' |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 5 |
        Remove-Item -Force
    return $dest
}

function Invoke-Rollback {
    Assert-Admin
    $baks = @(Get-ChildItem -LiteralPath $BackupDir -Filter 'hosts-*.bak' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($baks.Count -eq 0) { throw "没有找到备份文件：$BackupDir" }
    $latest = $baks[0]
    Copy-Item -LiteralPath $latest.FullName -Destination $HostsPath -Force
    ipconfig /flushdns | Out-Null
    Say "已用备份恢复 hosts：$($latest.Name)" 'Green'
    Say "备份时间：$($latest.LastWriteTime)" 'DarkGray'
}

# ---------------------------------------------------------------------------
# 代理旁路检查（只读，不修改 Clash 配置）
# ---------------------------------------------------------------------------
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
    $p = Get-ProxyState
    if (-not $p.Enabled) {
        Say '代理：未启用系统代理，所有流量直连。' 'Green'
        return
    }
    Say "代理：系统代理已开启 -> $($p.Server)" 'Yellow'
    $missing = @($Domains | Where-Object { -not (Test-BypassStrict -Domain $_ -Bypass $p.Bypass) })
    if ($missing.Count -eq 0) {
        Say '旁路：所有目标域名都在 ProxyOverride 中，PT 流量直连。' 'Green'
    } else {
        Say '旁路：以下域名未在 ProxyOverride 中（会走代理，出口 IP 会变，有封号风险）：' 'Red'
        foreach ($m in $missing) { Say "  - $m" 'Red' }
        Say '  请先在 Clash 旁路里补上这些域名，再重新运行。' 'Red'
    }
}

function Test-TunAdapter {
    $tun = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'TAP|TUN|Wintun|WireGuard|Tailscale|Clash|Mihomo'
        })
    if ($tun.Count -gt 0) {
        Say '警告：检测到可能处于 TUN 模式的虚拟网卡（所有流量会被代理接管）：' 'Red'
        foreach ($t in $tun) { Say "  - $($t.Name) / $($t.InterfaceDescription)" 'Red' }
        Say '  请关闭 TUN 模式后再扫描，否则测速结果和出口 IP 都不可信。' 'Red'
        return $false
    }
    Say '网卡：未检测到 TUN 模式虚拟网卡。' 'Green'
    return $true
}

# ---------------------------------------------------------------------------
# 候选 IP
# ---------------------------------------------------------------------------
function New-CandidateIps {
    param([int]$Count)
    # 官方 Cloudflare IPv4 段（含 CFST 里能命中的 104.28.0.0/14）
    $ranges = @(
        @('173.245.48.0', 20), @('103.21.244.0', 22), @('103.22.200.0', 22), @('103.31.4.0', 22),
        @('141.101.64.0', 18), @('108.162.192.0', 18), @('190.93.240.0', 20), @('188.114.96.0', 20),
        @('197.234.240.0', 22), @('198.41.128.0', 17), @('162.158.0.0', 15), @('104.16.0.0', 13),
        @('104.24.0.0', 14), @('104.28.0.0', 14), @('172.64.0.0', 13), @('131.0.72.0', 22)
    )
    # 本机实测有响应的种子，提高命中率
    $seeds = @(
        '104.16.0.1', '104.17.0.1', '104.18.0.1', '104.19.0.1', '104.20.0.1', '104.21.0.1',
        '104.24.0.1', '104.25.0.1', '104.26.0.1', '104.26.4.1', '104.26.10.251', '104.27.0.1',
        '104.28.0.1', '104.29.111.59', '104.16.192.1', '104.17.128.1', '104.17.141.134',
        '104.17.240.1', '104.18.64.1', '104.18.128.1', '104.18.240.1', '104.19.64.1',
        '104.20.64.1', '104.21.64.1', '162.158.0.1', '162.159.0.1', '188.114.96.1', '188.114.97.1'
    )
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $seeds) { if ($list.Count -lt $Count -and -not $list.Contains($s)) { $list.Add($s) } }

    $rnd = [System.Random]::new()
    $guard = 0
    while ($list.Count -lt $Count -and $guard -lt ($Count * 30)) {
        $guard++
        $r = $ranges[$rnd.Next($ranges.Count)]
        $hostBits = 32 - [int]$r[1]
        $base = [long]0
        foreach ($o in ($r[0] -split '\.')) { $base = ($base -shl 8) -bor [long]$o }
        $val = $base + [long]($rnd.NextDouble() * [math]::Pow(2, $hostBits))
        $o1 = [int](($val -shr 24) -band 255)
        $o2 = [int](($val -shr 16) -band 255)
        $o3 = [int](($val -shr 8) -band 255)
        $o4 = [int]($val -band 255)
        if ($o4 -eq 0 -or $o4 -eq 255) { continue }
        $ip = "$o1.$o2.$o3.$o4"
        if (-not $list.Contains($ip)) { $list.Add($ip) }
    }
    return @($list)
}

# ---------------------------------------------------------------------------
# 延迟扫描
# ---------------------------------------------------------------------------
function Find-Cfst {
    param([string]$Explicit)
    $cands = @()
    if ($Explicit) { $cands += $Explicit }
    $cands += (Join-Path $Root 'cfst\cfst.exe')
    $cands += (Join-Path $Root 'cfst.exe')
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

function Invoke-CfstLatencyScan {
    param([string]$Exe)
    $dir = Split-Path -Parent $Exe
    $csv = Join-Path $dir 'result.csv'
    if (Test-Path -LiteralPath $csv) { Remove-Item -LiteralPath $csv -Force }
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'ip.txt'))) {
        Say "CFST 目录下缺少 ip.txt：$dir" 'Yellow'
        return @()
    }

    $proxyVars = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')
    $saved = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($k in $proxyVars) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

    Push-Location $dir
    try {
        foreach ($k in $proxyVars) { [Environment]::SetEnvironmentVariable($k, $null) }
        # -dd 只测延迟/丢包，不做下载测速（默认测速地址已失效，会给出假速度）
        $cfstArgs = @('-dd', '-tlr', '0.05', '-p', '0', '-o', 'result.csv', '-f', 'ip.txt')
        & $Exe @cfstArgs *> $null
        $code = $LASTEXITCODE
        Say "CFST 延迟扫描退出码：$code" 'DarkGray'
        if (-not (Test-Path -LiteralPath $csv)) { return @() }

        $rows = @()
        foreach ($l in @(Get-Content -LiteralPath $csv -Encoding UTF8 | Select-Object -Skip 1)) {
            if ([string]::IsNullOrWhiteSpace($l)) { continue }
            $p = $l.Split(',')
            if ($p.Count -lt 5) { continue }
            $ip = $p[0].Trim()
            if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { continue }
            $loss = 1.0;  [void][double]::TryParse($p[3].Trim(), [ref]$loss)
            $delay = 0.0; [void][double]::TryParse($p[4].Trim(), [ref]$delay)
            if ($delay -le 0) { continue }
            $rows += [pscustomobject]@{
                IP = $ip; Loss = $loss; Ttfb = ($delay / 1000.0)
                Colo = ''; Source = 'cfst'
            }
        }
        return $rows
    } finally {
        Pop-Location
        foreach ($k in $proxyVars) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

function Invoke-BuiltinLatencyScan {
    param([string]$CurlExe, [int]$Candidates, [int]$Samples)

    $ips = New-CandidateIps -Count $Candidates
    Say "内置延迟扫描：$($ips.Count) 个候选 IP，每个 $Samples 次探测 ..." 'Cyan'

    $probe = $ips | ForEach-Object -Parallel {
        $ip = $_
        $curlPath = $using:CurlExe
        $sampleCount = $using:Samples

        function Get-Median([double[]]$arr) {
            if (-not $arr -or $arr.Count -eq 0) { return 0.0 }
            $s = @($arr | Sort-Object)
            $n = $s.Count
            if ($n % 2 -eq 1) { return [double]$s[[int][math]::Floor($n / 2)] }
            return ([double]$s[$n / 2 - 1] + [double]$s[$n / 2]) / 2.0
        }

        $ok = 0; $con = @(); $tls = @(); $ttf = @(); $colo = ''
        for ($i = 0; $i -lt $sampleCount; $i++) {
            $raw = & $curlPath -sS --noproxy '*' --max-time 6 `
                --resolve "speed.cloudflare.com:443:$ip" `
                -w '|@@|%{time_connect}|%{time_appconnect}|%{time_starttransfer}' `
                'https://speed.cloudflare.com/cdn-cgi/trace' 2>$null
            $exit = $LASTEXITCODE
            $s = ($raw -join "`n")
            if ($s -match 'colo=([A-Za-z]{3})') { $colo = $matches[1].ToUpperInvariant() }
            if ($exit -ne 0) { continue }
            $p = (($s -split '\|@@\|')[-1]) -split '\|'
            if ($p.Count -lt 3) { continue }
            $ok++
            $con += [double]$p[0]; $tls += [double]$p[1]; $ttf += [double]$p[2]
        }
        if ($ok -eq 0) { return }
        [pscustomobject]@{
            IP      = $ip
            Colo    = $colo
            Loss    = 1.0 - ($ok / [double]$sampleCount)
            Connect = Get-Median $con
            Tls     = Get-Median $tls
            Ttfb    = Get-Median $ttf
            Source  = 'builtin'
        }
    } -ThrottleLimit 24

    return @($probe | Where-Object { $_ -and $_.Ttfb -gt 0 -and $_.Loss -le 0.05 } | Sort-Object Ttfb)
}

# ---------------------------------------------------------------------------
# 独立吞吐测速（不依赖第三方测速地址）
# ---------------------------------------------------------------------------
function Invoke-ThroughputTest {
    param([string]$CurlExe, $Candidates, [int]$Samples, [int]$Bytes, [string]$UrlTemplate)

    $testUri = [uri]($UrlTemplate -replace '\{bytes\}', '1')
    $testHost = $testUri.Host
    $testPort = if ($testUri.Port -gt 0) { $testUri.Port } else { 443 }

    Say "吞吐测速：$($Candidates.Count) 个 IP x $Samples 次 x $([math]::Round($Bytes / 1MB, 1))MB（$testHost）..." 'Cyan'
    $rows = $Candidates | ForEach-Object -Parallel {
        $ip = $_.IP
        $curlPath = $using:CurlExe
        $sampleCount = $using:Samples
        $byteCount = $using:Bytes
        $urlTemplate = $using:UrlTemplate
        $resolveHost = $using:testHost
        $resolvePort = $using:testPort
        $speeds = @()
        for ($i = 0; $i -lt $sampleCount; $i++) {
            $url = $urlTemplate -replace '\{bytes\}', [string]$byteCount
            $raw = & $curlPath -sS --noproxy '*' --max-time 30 `
                --resolve "${resolveHost}:${resolvePort}:$ip" `
                -o NUL -w '%{speed_download}|%{size_download}|%{time_total}' `
                $url 2>$null
            $p = (($raw -join '') -split '\|')
            if ($p.Count -lt 3) { continue }
            $bytesGot = 0.0; [void][double]::TryParse($p[1], [ref]$bytesGot)
            $time = 0.0;     [void][double]::TryParse($p[2], [ref]$time)
            if ($bytesGot -lt 500000 -or $time -le 0) { continue }
            $speeds += ($bytesGot / $time)
        }
        if ($speeds.Count -eq 0) {
            return [pscustomobject]@{ IP = $ip; SpeedMBps = 0.0; Samples = 0 }
        }
        $sorted = @($speeds | Sort-Object)
        $median = $sorted[[int][math]::Floor($sorted.Count / 2)]
        [pscustomobject]@{ IP = $ip; SpeedMBps = ($median / 1MB); Samples = $speeds.Count }
    } -ThrottleLimit 6
    return @($rows)
}

function Get-ColoForIp {
    param([string]$CurlExe, [string]$Ip)
    $raw = & $CurlExe -sS --noproxy '*' --max-time 6 `
        --resolve "speed.cloudflare.com:443:$Ip" `
        'https://speed.cloudflare.com/cdn-cgi/trace' 2>$null
    $s = ($raw -join "`n")
    if ($s -match 'colo=([A-Za-z]{3})') { return $matches[1].ToUpperInvariant() }
    return ''
}

function Resolve-Colo {
    param([string]$CurlExe, $Candidates)
    $rows = $Candidates | ForEach-Object -Parallel {
        $ip = $_.IP
        $curlPath = $using:CurlExe
        $raw = & $curlPath -sS --noproxy '*' --max-time 6 `
            --resolve "speed.cloudflare.com:443:$ip" `
            'https://speed.cloudflare.com/cdn-cgi/trace' 2>$null
        $s = ($raw -join "`n")
        $colo = ''
        if ($s -match 'colo=([A-Za-z]{3})') { $colo = $matches[1].ToUpperInvariant() }
        [pscustomobject]@{ IP = $ip; Colo = $colo; Loss = $_.Loss; Ttfb = $_.Ttfb }
    } -ThrottleLimit 16
    return @($rows)
}

# 按落地机房轮流取样，避免延迟排序把候选全选成 HKG（HKG 延迟低但大流量极易卡死）
function Select-Stratified {
    param($Candidates, [int]$Count)
    $groups = @($Candidates | Group-Object Colo |
        Sort-Object { ($_.Group | Measure-Object -Property Ttfb -Minimum).Minimum })
    $picked = @()
    $idx = 0
    while ($picked.Count -lt $Count) {
        $added = $false
        foreach ($g in $groups) {
            if ($idx -lt $g.Group.Count) {
                $picked += $g.Group[$idx]
                $added = $true
                if ($picked.Count -ge $Count) { break }
            }
        }
        if (-not $added) { break }
        $idx++
    }
    return @($picked)
}

# ---------------------------------------------------------------------------
# 域名验证
# ---------------------------------------------------------------------------
function Test-DomainIp {
    param([string]$Domain, [string]$Ip, [string]$CurlExe)
    $raw = & $CurlExe -sS -I --noproxy '*' --max-time 10 `
        --resolve "${Domain}:443:$Ip" `
        -w '|@@|%{http_code}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}' `
        "https://$Domain/" 2>$null
    $exit = $LASTEXITCODE
    $s = ($raw -join "`n")
    $p = (($s -split '\|@@\|')[-1]) -split '\|'
    $http = if ($p.Count -ge 1) { [string]$p[0] } else { '000' }
    $con = if ($p.Count -ge 2) { [double]$p[1] } else { 0.0 }
    $tls = if ($p.Count -ge 3) { [double]$p[2] } else { 0.0 }
    $ttf = if ($p.Count -ge 4) { [double]$p[3] } else { 0.0 }
    $ok = ($exit -eq 0 -and $http -match '^\d{3}$' -and $http -ne '000')
    return [pscustomobject]@{ Ok = $ok; Http = $http; Connect = $con; Tls = $tls; Ttfb = $ttf; Exit = $exit }
}

# ---------------------------------------------------------------------------
# 写 hosts（只动标记区块和本脚本管理的域名）
# ---------------------------------------------------------------------------
function Update-HostsFile {
    param([string]$Path, [hashtable]$Map, [string[]]$AllDomains)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $nonAscii = $false
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii = $true; break } }
    $text = if ($nonAscii) { [Text.Encoding]::UTF8.GetString($bytes) } else { [Text.Encoding]::ASCII.GetString($bytes) }
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = $text -split "`r?`n"

    $active = @($Map.Keys)
    $out = [System.Collections.Generic.List[string]]::new()
    $inBlock = $false

    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -eq $BeginMarker) { $inBlock = $true; continue }
        if ($t -eq $EndMarker) { $inBlock = $false; continue }
        if ($inBlock) { continue }

        $isTagged = $t.StartsWith($LegacyTag)
        $work = if ($isTagged) { $t.Substring($LegacyTag.Length).Trim() } else { $t }

        if ($work -and -not $work.StartsWith('#')) {
            $parts = $work -split '\s+'
            if ($parts.Count -ge 2) {
                $hostName = $parts[1].TrimEnd('.').ToLowerInvariant()
                if ($active -contains $hostName) {
                    # 仍在管理：保留为注释，实际地址由下面的区块提供
                    $out.Add($LegacyTag + $work)
                    continue
                }
                if ($isTagged) {
                    # 本次未通过验证：还原用户原来的条目，避免把站弄挂
                    $out.Add($work)
                    continue
                }
            }
        }
        if ($isTagged) { $out.Add($work); continue }
        $out.Add($line)
    }

    while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }

    $out.Add('')
    $out.Add($BeginMarker)
    foreach ($d in $AllDomains) {
        if (-not $Map.ContainsKey($d)) { continue }
        foreach ($ip in $Map[$d]) { $out.Add("$ip`t$d") }
    }
    $out.Add($EndMarker)
    $out.Add('')

    $newText = ($out -join $nl)
    if (-not $newText.EndsWith($nl)) { $newText += $nl }
    $enc = if ($nonAscii) { [Text.UTF8Encoding]::new($false) } else { [Text.ASCIIEncoding]::new() }
    [IO.File]::WriteAllText($Path, $newText, $enc)
}

# ===========================================================================
# 主流程
# ===========================================================================
Say ''
Say '==== Cloudflare 优选 IP -> hosts ====' 'Cyan'
Say "hosts: $HostsPath" 'DarkGray'
Say "域名数: $($Domains.Count)" 'DarkGray'
Say ''

if ($Rollback) {
    Invoke-Rollback
    Say ''
    Say '完成。' 'Green'
    return
}

# 正式写入需要管理员；提前检查，避免扫描几分钟后才报错
if (-not $DryRun) { Assert-Admin }

$curlExe = Get-CurlExe

Show-ProxyCheck
[void](Test-TunAdapter)
Say ''

# --- 阶段 1：延迟/丢包筛选 ---
$latency = @()
$cfst = $null
if (-not $NoCfst) { $cfst = Find-Cfst -Explicit $CfstPath }
if ($cfst) {
    Say "使用 CFST 做全量延迟扫描：$cfst" 'Cyan'
    try {
        $latency = @(Invoke-CfstLatencyScan -Exe $cfst)
    } catch {
        Say "CFST 运行失败：$($_.Exception.Message)" 'Yellow'
        $latency = @()
    }
    if ($latency.Count -eq 0) { Say 'CFST 没有产出结果，改用内置扫描。' 'Yellow' }
}
if ($latency.Count -eq 0) {
    if ($NoCfst) {
        Say '已指定 -NoCfst，使用内置扫描。' 'Yellow'
    } elseif (-not $cfst) {
        Say '未找到 cfst.exe，使用内置扫描。' 'Yellow'
        Say '（想更快更全：从官方 Releases 下载 cfst_windows_amd64.zip，解压到 .\cfst\ 后重跑）' 'DarkGray'
    }
    $latency = @(Invoke-BuiltinLatencyScan -CurlExe $curlExe -Candidates $MaxCandidates -Samples $ScanSamples)
}
if ($latency.Count -eq 0) {
    throw '没有扫到任何可用 IP。请检查网络，或关闭代理/TUN 后重试。'
}
$latency = @($latency | Sort-Object Ttfb)
Say "延迟/丢包筛选后可用 IP：$($latency.Count)，最佳 $($latency[0].IP)（$([math]::Round($latency[0].Ttfb * 1000))ms）" 'Gray'

# 合理性检查：延迟 <5ms 基本只可能是走了代理
$speedProxy = ($latency | Select-Object -First 10 | Measure-Object -Property Ttfb -Average).Average
if ($speedProxy -lt 0.005) {
    throw '平均延迟异常低（<5ms），疑似测速流量走了代理。请关闭系统代理/TUN 后重试。'
}

# --- 阶段 2：独立吞吐测速 ---
# 先探明前 64 个候选的落地机房，再按机房分层抽样（避免候选被 HKG 全部占据）
$pool = @($latency | Select-Object -First ([int][math]::Min(64, $latency.Count)))
Say "探测候选落地区域（$($pool.Count) 个）..." 'Cyan'
$pool = @(Resolve-Colo -CurlExe $curlExe -Candidates $pool)
$candidates = @(Select-Stratified -Candidates $pool -Count $ThroughputCandidates)
$coloSummary = (@($candidates | Group-Object Colo | ForEach-Object {
    $name = if ($_.Name) { $_.Name } else { '??' }
    "$name x$($_.Count)"
})) -join ', '
Say "分层抽样 $($candidates.Count) 个（$coloSummary）" 'Gray'

$tp = @(Invoke-ThroughputTest -CurlExe $curlExe -Candidates $candidates -Samples $ThroughputSamples -Bytes $ThroughputBytes -UrlTemplate $SpeedTestUrl)
$tpMap = @{}
foreach ($t in $tp) { if ($t) { $tpMap[$t.IP] = [double]$t.SpeedMBps } }

$ranked = foreach ($c in $candidates) {
    $sp = if ($tpMap.ContainsKey($c.IP)) { $tpMap[$c.IP] } else { 0.0 }
    [pscustomobject]@{
        IP = $c.IP; Colo = $c.Colo; Loss = $c.Loss; Ttfb = $c.Ttfb; SpeedMBps = $sp
    }
}
$ranked = @($ranked | Sort-Object @{ Expression = 'SpeedMBps'; Descending = $true },
                                   @{ Expression = 'Ttfb'; Descending = $false })

# 对吞吐靠前的 IP 再做一次更长的复核（3MB x 2 次），减少抖动误判
if ($RefineTop -gt 0) {
    $refineList = @($ranked | Where-Object { $_.SpeedMBps -gt 0 } | Select-Object -First $RefineTop)
    if ($refineList.Count -gt 0) {
        $refine = @(Invoke-ThroughputTest -CurlExe $curlExe -Candidates $refineList -Samples 2 -Bytes 3000000 -UrlTemplate $SpeedTestUrl)
        $refMap = @{}
        foreach ($r in $refine) { if ($r) { $refMap[$r.IP] = [double]$r.SpeedMBps } }
        foreach ($r in $ranked) {
            if ($refMap.ContainsKey($r.IP) -and $refMap[$r.IP] -gt 0) { $r.SpeedMBps = $refMap[$r.IP] }
        }
    }
}

$withSpeed = @($ranked | Where-Object { $_.SpeedMBps -gt 0 })
if ($withSpeed.Count -gt 0) {
    $ranked = @($withSpeed | Sort-Object @{ Expression = 'SpeedMBps'; Descending = $true },
                                     @{ Expression = 'Ttfb'; Descending = $false })
} else {
    Say '警告：所有候选都没完成吞吐测速，改为按延迟排序（可能只适合网页）。' 'Yellow'
    $ranked = @($ranked | Sort-Object Ttfb)
}

Say ''
Say '吞吐排名（前 8）：' 'Cyan'
$ranked | Select-Object -First 8 IP, Colo, Loss, Ttfb, SpeedMBps |
    Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Say $_.TrimEnd() }

$picks = @($ranked | Select-Object -First $TopN)
# 补齐落地区域码（CFST 纯延迟模式没有这一列）
foreach ($pk in $picks) {
    if (-not $pk.Colo) { $pk.Colo = Get-ColoForIp -CurlExe $curlExe -Ip $pk.IP }
}
Say ''
Say '选定 IP：' 'Cyan'
$picks | Select-Object IP, Colo, Loss, Ttfb, SpeedMBps |
    Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Say $_.TrimEnd() }
Say ''

# --- 阶段 3：逐域名验证 ---
Say '逐域名验证（每域名每 IP 1 次 HEAD）...' 'Cyan'
$map = @{}
$verifyRows = @()
foreach ($d in $Domains) {
    $passed = @()
    foreach ($p in $picks) {
        $r = Test-DomainIp -Domain $d -Ip $p.IP -CurlExe $curlExe
        $verifyRows += [pscustomobject]@{
            Domain = $d; IP = $p.IP; Colo = $p.Colo; Ok = $r.Ok
            Http = $r.Http; Connect = $r.Connect; Tls = $r.Tls; Ttfb = $r.Ttfb
        }
        if ($r.Ok) { $passed += [pscustomobject]@{ IP = $p.IP; Ttfb = $r.Ttfb } }
        Start-Sleep -Milliseconds $VerifyDelayMs
    }
    if ($passed.Count -gt 0) {
        # 按实际 TTFB 排序，最快的排前面
        $ordered = @($passed | Sort-Object Ttfb | ForEach-Object { $_.IP })
        $map[$d] = $ordered
        Say ("  {0,-22} OK  {1}" -f $d, ($ordered -join ', ')) 'Green'
    } else {
        Say ("  {0,-22} 失败，保持原样（非 CF 或不可用）" -f $d) 'Yellow'
    }
}
Say ''

if ($map.Count -eq 0) {
    throw '所有域名验证都失败，未修改 hosts。'
}

# --- 阶段 4：写入 ---
if ($DryRun) {
    Say 'DryRun：不写 hosts。将写入以下内容：' 'Cyan'
    foreach ($d in $Domains) {
        if ($map.ContainsKey($d)) {
            foreach ($ip in $map[$d]) { Say ("  {0,-16} {1}" -f $ip, $d) 'White' }
        }
    }
} else {
    Assert-Admin
    $backup = Backup-Hosts
    Say "已备份 hosts -> $backup" 'DarkGray'
    try {
        Update-HostsFile -Path $HostsPath -Map $map -AllDomains $Domains
        ipconfig /flushdns | Out-Null
        Say '已写入 hosts 并刷新 DNS。' 'Green'
    } catch {
        Copy-Item -LiteralPath $backup -Destination $HostsPath -Force
        ipconfig /flushdns | Out-Null
        Say "写入失败，已自动还原：$($_.Exception.Message)" 'Red'
        throw
    }
}

# --- 报告 ---
Say ''
Say '==== 验证结果 ====' 'Cyan'
$verifyRows | Select-Object Domain, IP, Colo, Http, Ok, Ttfb |
    Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Say $_.TrimEnd() }

Say ''
Say '==== 说明 ====' 'Cyan'
$failed = @($Domains | Where-Object { -not $map.ContainsKey($_) })
if ($failed.Count -gt 0) {
    Say '以下域名未通过验证，已保持原样（可能不是 Cloudflare 托管或当前不可用）：' 'Yellow'
    foreach ($f in $failed) { Say "  - $f" 'DarkGray' }
}
Say 'hosts 只影响这些域名的网页/tracker；P2P 传输和 IPv6 对等连接不受影响。' 'DarkGray'
Say '写入 A 记录后，Windows 对这些域名不再使用 DNS 的 AAAA（浏览器走 IPv4 优选）。' 'DarkGray'
Say '回滚：.\pt-cf-optimize.ps1 -Rollback' 'DarkGray'
Say "报告已保存：$ReportPath" 'DarkGray'

$script:Log | Out-File -LiteralPath $ReportPath -Encoding utf8
Say ''
Say '完成。' 'Green'
