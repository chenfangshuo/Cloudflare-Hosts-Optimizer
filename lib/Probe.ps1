#Requires -Version 7.0
<#
    网络探测：curl 调用、吞吐样本有效性、CFST 解析、机房分层。

    约定：
      * 任何 curl 调用都以 -q 开头，忽略用户的 .curlrc。
      * 统一 --noproxy '*'、--max-redirs 0、--proto '=https'。
      * 吞吐样本必须同时满足：退出码 0、HTTP 200/206、字节数达标、remote_ip 匹配。
#>

$script:CfOfficialRanges = @(
    '173.245.48.0/20', '103.21.244.0/22', '103.22.200.0/22', '103.31.4.0/22',
    '141.101.64.0/18', '108.162.192.0/18', '190.93.240.0/20', '188.114.96.0/20',
    '197.234.240.0/22', '198.41.128.0/17', '162.158.0.0/15', '104.16.0.0/13',
    '104.24.0.0/14', '172.64.0.0/13', '131.0.72.0/22'
)
# 非官方列表、但实测有 CF 响应的网段；仅在 -ExperimentalRanges 时启用
$script:CfExperimentalRanges = @('104.28.0.0/14')

# 延迟扫描和机房探测都用这个地址的 colo= 判断落地区域；
# 换主机必须仍是 Cloudflare 托管的站点（--resolve 会把任意 CF 边缘 IP 指到这个名字）。
$script:DefaultProbeUrl = 'https://speed.cloudflare.com/cdn-cgi/trace'

# curl -w 字段的唯一定义：格式串由它生成，解析器按名字取索引，
# 增删字段时两边不会再各改一处、静默错位。
$script:CurlWriteFields = @(
    'http_code', 'size_download', 'time_total', 'time_namelookup',
    'time_connect', 'time_appconnect', 'time_starttransfer', 'remote_ip'
)

function Get-CurlExe {
    [CmdletBinding()]
    param()
    $system = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $system) { return $system }
    $c = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $c) { throw '找不到 curl.exe（Windows 10/11 自带）。' }
    return $c.Source
}

# 面向用户的状态行。主脚本里 Progress.ps1 会先擦掉动画行再写；
# 单独加载 Probe.ps1（测试）时退回 Write-Host。
function Write-ProbeStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Color = 'Cyan'
    )
    if (Get-Command Write-StatusLine -ErrorAction SilentlyContinue) {
        Write-StatusLine -Text $Text -Color $Color
    } else {
        Write-Host $Text -ForegroundColor $Color
    }
}

function Get-Median {
    [CmdletBinding()]
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $s = @($Values | Sort-Object)
    $n = $s.Count
    if ($n % 2 -eq 1) { return [double]$s[[int][math]::Floor($n / 2)] }
    return ([double]$s[$n / 2 - 1] + [double]$s[$n / 2]) / 2.0
}

function Test-IpInCidr {
    [CmdletBinding()]
    param([string]$Ip, [string]$Cidr)
    $ipAddr = $null
    if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$ipAddr)) { return $false }
    $parts = $Cidr -split '/'
    if ($parts.Count -ne 2) { return $false }
    $netAddr = $null
    if (-not [System.Net.IPAddress]::TryParse($parts[0], [ref]$netAddr)) { return $false }
    if ($ipAddr.AddressFamily -ne $netAddr.AddressFamily) { return $false }
    $len = 0
    if (-not [int]::TryParse($parts[1], [ref]$len)) { return $false }
    $a = $ipAddr.GetAddressBytes()
    $n = $netAddr.GetAddressBytes()
    if ($len -lt 0 -or $len -gt ($a.Length * 8)) { return $false }
    $full = [int][math]::Floor($len / 8)
    $rem = $len % 8
    for ($i = 0; $i -lt $full; $i++) {
        if ($a[$i] -ne $n[$i]) { return $false }
    }
    if ($rem -gt 0) {
        $mask = (0xFF -shl (8 - $rem)) -band 0xFF
        if (([int]$a[$full] -band $mask) -ne ([int]$n[$full] -band $mask)) { return $false }
    }
    return $true
}

function Test-IpAllowed {
    [CmdletBinding()]
    param([string]$Ip, [string[]]$Ranges)
    foreach ($r in $Ranges) {
        if (Test-IpInCidr -Ip $Ip -Cidr $r) { return $true }
    }
    return $false
}

function Get-CfRanges {
    [CmdletBinding()]
    param([switch]$Experimental)
    $r = @($script:CfOfficialRanges)
    if ($Experimental) { $r += $script:CfExperimentalRanges }
    return $r
}

# 解析 curl -w 输出。所有时间字段统一扣掉 time_namelookup：
# 候选走 --resolve（解析≈0），基线走系统解析；不扣掉的话基线会白背一次 DNS 时间，
# 15% 的门槛会被解析时间吃掉一部分。
function ConvertFrom-CurlWriteOut {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Raw = '')

    $p = (($Raw -split '\|@@\|')[-1]) -split '\|'
    $idx = @{}
    for ($i = 0; $i -lt $script:CurlWriteFields.Count; $i++) { $idx[$script:CurlWriteFields[$i]] = $i }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $read = {
        param([string]$Name)
        $i = $idx[$Name]
        if ($null -eq $i -or $p.Count -le $i) { return 0.0 }
        $v = 0.0
        if ([double]::TryParse([string]$p[$i], [System.Globalization.NumberStyles]::Float, $inv, [ref]$v)) { return $v }
        return 0.0
    }
    $dns = & $read 'time_namelookup'
    $relative = {
        param([double]$Value)
        $x = $Value - $dns
        if ($x -lt 0) { 0.0 } else { $x }
    }

    $httpIdx = $idx['http_code']
    $remoteIdx = $idx['remote_ip']
    return [pscustomobject]@{
        Http     = if ($p.Count -gt $httpIdx -and $p[$httpIdx]) { [string]$p[$httpIdx] } else { '000' }
        Bytes    = & $read 'size_download'
        Total    = & $read 'time_total'
        Dns      = $dns
        Connect  = & $relative (& $read 'time_connect')
        Tls      = & $relative (& $read 'time_appconnect')
        Ttfb     = & $relative (& $read 'time_starttransfer')
        RemoteIp = if ($p.Count -gt $remoteIdx) { [string]$p[$remoteIdx] } else { '' }
    }
}

function Invoke-CurlProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CurlExe,
        [Parameter(Mandatory)][string]$Url,
        [string]$Resolve,
        [switch]$Head,
        [int]$MaxTime = 10,
        [string]$Output = 'NUL',
        [string]$Range,
        [int]$MaxFileSize = 0
    )

    $curlArgs = @('-q', '-sS', '--noproxy', '*', '--max-redirs', '0', '--proto', '=https', '--max-time', [string]$MaxTime)
    if ($Head) { $curlArgs += '-I' }
    if ($Resolve) { $curlArgs += @('--resolve', $Resolve) }
    if ($Range) { $curlArgs += @('--range', $Range) }
    if ($MaxFileSize -gt 0) { $curlArgs += @('--max-filesize', [string]$MaxFileSize) }
    if ($Output) { $curlArgs += @('-o', $Output) }
    $fmt = '|@@|' + (($script:CurlWriteFields | ForEach-Object { "%{$_}" }) -join '|')
    $curlArgs += @('-w', $fmt)
    $curlArgs += $Url

    $raw = & $CurlExe @curlArgs 2>$null
    $exit = $LASTEXITCODE
    $s = ($raw -join "`n")
    $m = ConvertFrom-CurlWriteOut -Raw $s

    return [pscustomobject]@{
        ExitCode = $exit
        Http     = $m.Http
        Bytes    = $m.Bytes
        Total    = $m.Total
        Dns      = $m.Dns
        Connect  = $m.Connect
        Tls      = $m.Tls
        Ttfb     = $m.Ttfb
        RemoteIp = $m.RemoteIp
        Raw      = $s
    }
}

function Split-SpeedTestUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UrlTemplate)
    $probeUrl = $UrlTemplate -replace '\{bytes\}', '1'
    $uri = $null
    if (-not [uri]::TryCreate($probeUrl, [System.UriKind]::Absolute, [ref]$uri)) { throw "SpeedTestUrl 不是合法 URL：$UrlTemplate" }
    if ($uri.Scheme -ne 'https') { throw 'SpeedTestUrl 只允许 https。' }
    if ($uri.UserInfo) { throw 'SpeedTestUrl 不允许包含凭据。' }
    return [pscustomobject]@{
        Host = $uri.Host
        Port = if ($uri.Port -gt 0) { $uri.Port } else { 443 }
    }
}

function Invoke-ThroughputTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CurlExe,
        [Parameter(Mandatory)]$Candidates,
        [Parameter(Mandatory)][int]$Samples,
        [Parameter(Mandatory)][int]$Bytes,
        [Parameter(Mandatory)][string]$UrlTemplate,
        [int]$ThrottleLimit = 6,
        [int]$MaxTime = 20,
        # 显示用前缀：初测 / 决赛，只影响那一行状态文字
        [string]$Phase = ''
    )

    $target = Split-SpeedTestUrl -UrlTemplate $UrlTemplate
    $targetHost = $target.Host
    $targetPort = $target.Port
    $phaseText = if ($Phase) { "$Phase：" } else { '' }
    Write-ProbeStatus "${phaseText}吞吐测速：$($Candidates.Count) 个 IP x $Samples 次 x $([math]::Round($Bytes / 1MB, 1))MB（$targetHost）..."

    $rows = $Candidates | ForEach-Object -Parallel {
        $ip = $_.IP
        $curlPath = $using:CurlExe
        $sampleCount = $using:Samples
        $byteCount = $using:Bytes
        $urlTemplate = $using:UrlTemplate
        $resolveHost = $using:targetHost
        $resolvePort = $using:targetPort
        $timeoutSec = $using:MaxTime

        $valid = @()
        $failed = 0
        $reasons = @()
        for ($i = 0; $i -lt $sampleCount; $i++) {
            $url = $urlTemplate -replace '\{bytes\}', [string]$byteCount
            $fmt = '|@@|%{http_code}|%{size_download}|%{time_total}|%{remote_ip}'
            $raw = & $curlPath -q -sS --noproxy '*' --max-redirs 0 --proto '=https' `
                --max-time $timeoutSec --resolve "${resolveHost}:${resolvePort}:$ip" -o NUL -w $fmt $url 2>$null
            $exit = $LASTEXITCODE
            $p = (($raw -join '') -split '\|@@\|')[-1] -split '\|'
            $http = if ($p.Count -ge 1) { [string]$p[0] } else { '000' }
            $got = if ($p.Count -ge 2) { [double]$p[1] } else { 0.0 }
            $total = if ($p.Count -ge 3) { [double]$p[2] } else { 0.0 }
            $remote = if ($p.Count -ge 4) { [string]$p[3] } else { '' }

            if ($exit -ne 0) { $failed++; $reasons += "exit=$exit"; continue }
            if ($http -notin @('200', '206')) { $failed++; $reasons += "http=$http"; continue }
            if ($got -lt ($byteCount * 0.95)) { $failed++; $reasons += "short=$([int]$got)"; continue }
            if ($total -le 0) { $failed++; $reasons += 'time=0'; continue }
            if ($remote -ne $ip) { $failed++; $reasons += "remote=$remote"; continue }
            $valid += ($got / $total)
        }

        if ($valid.Count -eq 0) {
            return [pscustomobject]@{ IP = $ip; SpeedMBps = 0.0; Valid = 0; Failed = $failed; Reasons = ($reasons | Select-Object -Unique) -join ',' }
        }
        $sorted = @($valid | Sort-Object)
        $n = $sorted.Count
        $median = if ($n % 2 -eq 1) { [double]$sorted[[int][math]::Floor($n / 2)] }
                  else { ([double]$sorted[$n / 2 - 1] + [double]$sorted[$n / 2]) / 2.0 }
        [pscustomobject]@{
            IP = $ip; SpeedMBps = ($median / 1MB); Valid = $valid.Count; Failed = $failed
            Reasons = ($reasons | Select-Object -Unique) -join ','
        }
    } -ThrottleLimit $ThrottleLimit

    return @($rows)
}

function Invoke-CfstLatencyScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Ranges = $script:CfOfficialRanges
    )

    $dir = Split-Path -Parent $Exe
    $ipFile = Join-Path $dir 'ip.txt'
    if (-not (Test-Path -LiteralPath $ipFile)) {
        Write-ProbeStatus "CFST 目录下缺少 ip.txt：$dir" 'Yellow'
        return @()
    }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ('Cloudflare-Hosts-Optimizer-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $csv = Join-Path $temp 'result.csv'

    $proxyVars = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')
    $saved = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($k in $proxyVars) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

    Push-Location $dir
    try {
        foreach ($k in $proxyVars) { [Environment]::SetEnvironmentVariable($k, $null) }
        # -dd：只测延迟/丢包，不做下载测速
        $cfstArgs = @('-dd', '-tlr', '0.05', '-p', '0', '-o', $csv, '-f', 'ip.txt')
        & $Exe @cfstArgs *> $null
        $code = $LASTEXITCODE
        Write-ProbeStatus "CFST 延迟扫描退出码：$code" 'DarkGray'
        if ($code -ne 0 -or -not (Test-Path -LiteralPath $csv)) { return @() }

        $rows = @()
        foreach ($l in @(Get-Content -LiteralPath $csv -Encoding UTF8 | Select-Object -Skip 1)) {
            if ([string]::IsNullOrWhiteSpace($l)) { continue }
            $p = $l.Split(',')
            if ($p.Count -lt 5) { continue }
            $ip = $p[0].Trim()
            if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { continue }
            if (-not (Test-IpAllowed -Ip $ip -Ranges $Ranges)) { continue }

            $loss = 1.0
            $delay = 0.0
            $okLoss = [double]::TryParse($p[3].Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$loss)
            $okDelay = [double]::TryParse($p[4].Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$delay)
            if (-not $okLoss -or -not $okDelay) { continue }
            if ($loss -lt 0 -or $loss -gt 1) { continue }
            if ($delay -le 0 -or $delay -gt 10000) { continue }

            $rows += [pscustomobject]@{
                IP = $ip; Loss = $loss; Ttfb = ($delay / 1000.0); Colo = ''; Source = 'cfst'
            }
        }
        return $rows
    } finally {
        Pop-Location
        foreach ($k in $proxyVars) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-BuiltinLatencyScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CurlExe,
        [Parameter(Mandatory)][int]$Candidates,
        [Parameter(Mandatory)][int]$Samples,
        [Parameter(Mandatory)][string[]]$Ranges,
        [string]$ProbeUrl = $script:DefaultProbeUrl
    )

    # 从允许网段里随机抽样
    $ips = [System.Collections.Generic.List[string]]::new()
    $rnd = [System.Random]::new()
    $guard = 0
    while ($ips.Count -lt $Candidates -and $guard -lt ($Candidates * 30)) {
        $guard++
        $cidr = $Ranges[$rnd.Next($Ranges.Count)]
        $parts = $cidr -split '/'
        $net = [System.Net.IPAddress]::Parse($parts[0])
        $len = [int]$parts[1]
        $bytes = $net.GetAddressBytes()
        $hostBits = ($bytes.Length * 8) - $len
        $rand = [long]($rnd.NextDouble() * [math]::Pow(2, $hostBits))
        # 在主机位上加随机偏移
        $val = [long]0
        foreach ($b in $bytes) { $val = ($val -shl 8) -bor [long]$b }
        $val += $rand
        $o1 = [int](($val -shr 24) -band 255); $o2 = [int](($val -shr 16) -band 255)
        $o3 = [int](($val -shr 8) -band 255); $o4 = [int]($val -band 255)
        if ($o4 -eq 0 -or $o4 -eq 255) { continue }
        $ip = "$o1.$o2.$o3.$o4"
        if (-not $ips.Contains($ip)) { $ips.Add($ip) }
    }

    Write-ProbeStatus "内置延迟扫描：$($ips.Count) 个候选 IP，每个 $Samples 次探测 ..."
    $probeUrl = $ProbeUrl
    $probeHost = ([uri]$ProbeUrl).Host
    $probe = $ips | ForEach-Object -Parallel {
        $ip = $_
        $curlPath = $using:CurlExe
        $sampleCount = $using:Samples
        $traceUrl = $using:probeUrl
        $traceHost = $using:probeHost
        $ok = 0; $ttf = @(); $colo = ''
        for ($i = 0; $i -lt $sampleCount; $i++) {
            $fmt = '|@@|%{time_connect}|%{time_appconnect}|%{time_starttransfer}'
            $raw = & $curlPath -q -sS --noproxy '*' --max-redirs 0 --proto '=https' `
                --max-time 6 --resolve "${traceHost}:443:$ip" `
                -w $fmt $traceUrl 2>$null
            $exit = $LASTEXITCODE
            $s = ($raw -join "`n")
            if ($s -match 'colo=([A-Za-z]{3})') { $colo = $matches[1].ToUpperInvariant() }
            if ($exit -ne 0) { continue }
            $p = (($s -split '\|@@\|')[-1]) -split '\|'
            if ($p.Count -lt 3) { continue }
            $ok++
            $ttf += [double]$p[2]
        }
        if ($ok -eq 0) { return }
        $sortedTtf = @($ttf | Sort-Object)
        $n = $sortedTtf.Count
        $medianTtf = if ($n % 2 -eq 1) { [double]$sortedTtf[[int][math]::Floor($n / 2)] }
                     else { ([double]$sortedTtf[$n / 2 - 1] + [double]$sortedTtf[$n / 2]) / 2.0 }
        [pscustomobject]@{
            IP = $ip; Colo = $colo; Loss = 1.0 - ($ok / [double]$sampleCount)
            Ttfb = $medianTtf; Source = 'builtin'
        }
    } -ThrottleLimit 24

    return @($probe | Where-Object { $_ -and $_.Ttfb -gt 0 -and $_.Loss -le 0.05 } | Sort-Object Ttfb)
}

# 每 IP 请求预算：默认同一个物理 IP 最多 2 次 HEAD（初测 + 切换前复核）。
# 失败、没有 RemoteIp 的显式探测也要记一次尝试，避免“失败不计数”绕过上限。
function Test-ProbeBudgetAllows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Budget,
        [string]$Ip
    )
    if (-not $Ip) { return $true }
    # 每个域名、每个物理 IP 最多 2 次 HEAD（初测 + 切换前复核）
    return ([int]$Budget[$Ip] -lt 2)
}

function Add-ProbeUse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Budget,
        [string]$Ip
    )
    if (-not $Ip) { return }
    $Budget[$Ip] = 1 + [int]$Budget[$Ip]
}

function Get-ColoCacheDefaultPath {
    [CmdletBinding()]
    param([string]$Root)
    # 缓存是运行产物，优先放在用户本地目录，避免脚本目录只读或位于同步盘
    $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ($local) { return (Join-Path $local 'Cloudflare-Hosts-Optimizer\colo-cache.json') }
    $fallback = if ($Root) { $Root } else { $PSScriptRoot }
    return (Join-Path $fallback 'colo-cache.json')
}

function Read-ColoCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxAgeDays = 14,
        [datetime]$Now = (Get-Date)
    )
    # 任何异常都当成"没有缓存"：缓存只是加速，不能影响主流程
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
        if ([int]$doc.version -ne 1) { return $null }
        $cols = @($doc.colos | Where-Object { $_ -match '^[A-Z]{3}$' } | Select-Object -Unique)
        if ($cols.Count -eq 0) { return $null }
        # 7.5+ 会把 ISO 时间直接反序列化成 DateTime；先转字符串会丢时区，
        # 在 UTC+8 下把 14 天缓存算成 13 天 16 小时或 14 天 8 小时。
        $updatedValue = $doc.updatedAt
        if ($updatedValue -is [datetime]) {
            $updated = $updatedValue
        } elseif ($updatedValue -is [datetimeoffset]) {
            $updated = $updatedValue.UtcDateTime
        } else {
            $updated = [datetime]::Parse([string]$updatedValue, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind)
        }
        if (($Now.ToUniversalTime() - $updated.ToUniversalTime()).TotalDays -gt $MaxAgeDays) { return $null }
        return [pscustomobject]@{ Colos = $cols; UpdatedAt = $updated }
    } catch {
        return $null
    }
}

function Write-ColoCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Colos,
        # 受保护输入（hosts/域名文件/回滚源）：落盘前再确认目标没有变成它们的别名
        [string[]]$ProtectedPaths = @()
    )
    $tmp = $null
    try {
        $cols = @($Colos | Where-Object { $_ -match '^[A-Z]{3}$' } | Select-Object -Unique | Sort-Object)
        if ($cols.Count -eq 0) { return $false }
        $dir = Split-Path -Parent $Path
        if (-not $dir) { $dir = '.' }
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        $doc = [pscustomobject]@{
            version   = 1
            updatedAt = (Get-Date).ToUniversalTime().ToString('o')
            colos     = $cols
        }
        # 固定 "$Path.tmp" 会在预检之后被换成输入文件的硬链接，Set-Content 直接截断输入。
        # 用不可预测的临时名 + 原子 Move，写坏也只会写坏缓存本身。
        $tmp = Join-Path $dir ('.cfo-colo-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))

        foreach ($p in @($ProtectedPaths)) {
            if (-not $p) { continue }
            $r = Test-PathCollision -Left $Path -Right $p
            if ($r.Collision -or $r.Uncertain) { return $false }
        }
        Move-Item -LiteralPath $tmp -Destination $Path -Force
        return $true
    } catch {
        # 缓存写不进去不影响本次结果
        return $false
    } finally {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

# 切换前复核的下一步：只要复核请求落到的 IP 与首次基线不同（无论成功、失败还是 restricted），
# 就按"基线身份已变"处理；否则候选必须在预算允许时重新验证。
function Get-RecheckPlan {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$BaselineIp,
        $B2,
        [bool]$CandidateBudgetAllows = $true
    )
    if ($B2 -and $B2.RemoteIp -and $BaselineIp -and ($B2.RemoteIp -ne $BaselineIp)) {
        return 'ip-changed'
    }
    if (-not $CandidateBudgetAllows) { return 'budget-blocked' }
    return 'need-candidate'
}

function Get-CachableColos {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Candidates,
        [int]$MinCount = 2,
        [int]$Max = 6
    )
    # 只缓存有一定样本量的区域：稀有区域常常下一次就消失，
    # 会让覆盖检查永远失败、缓存彻底失去意义
    return @($Candidates | Where-Object { $_.Colo } |
        Group-Object Colo |
        Where-Object { $_.Count -ge $MinCount } |
        Sort-Object @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false } |
        Select-Object -First $Max |
        ForEach-Object { $_.Name })
}

function Test-ColoCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Rows,
        [string[]]$Colos,
        [int]$MinPerColo = 2
    )
    # 只有每个缓存区域都重新出现且数量够用，才允许提前结束探测
    $list = @($Colos | Where-Object { $_ })
    if ($list.Count -eq 0) { return $false }
    foreach ($c in $list) {
        $n = @($Rows | Where-Object { $_.Colo -eq $c }).Count
        if ($n -lt $MinPerColo) { return $false }
    }
    return $true
}

function Resolve-Colo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CurlExe,
        [Parameter(Mandatory)]$Candidates,
        # 分批探测并在每批结束后回调，避免 256 个候选跑几分钟却没有任何输出
        [scriptblock]$OnProgress,
        # 上次观察到的区域；每批结束后若已覆盖就提前结束，减少重复探测
        [string[]]$EarlyStopColos,
        [int]$EarlyStopMinPerColo = 2,
        [int]$EarlyStopMinProbe = 64,
        # 每批探测多少个；调小便于测试
        [ValidateRange(1, 128)][int]$ChunkSize = 32,
        [string]$ProbeUrl = $script:DefaultProbeUrl
    )
    $probeUrl = $ProbeUrl
    $probeHost = ([uri]$ProbeUrl).Host
    $list = @($Candidates)
    $total = $list.Count
    $rows = [System.Collections.Generic.List[object]]::new()
    $start = Get-Date
    $chunkSize = $ChunkSize

    for ($i = 0; $i -lt $total; $i += $chunkSize) {
        $last = [math]::Min($i + $chunkSize - 1, $total - 1)
        $chunk = @($list[$i..$last])
        $part = $chunk | ForEach-Object -Parallel {
            $ip = $_.IP
            $curlPath = $using:CurlExe
            $traceUrl = $using:probeUrl
            $traceHost = $using:probeHost
            $raw = & $curlPath -q -sS --noproxy '*' --max-redirs 0 --proto '=https' `
                --max-time 6 --resolve "${traceHost}:443:$ip" `
                $traceUrl 2>$null
            $s = ($raw -join "`n")
            $colo = ''
            if ($s -match 'colo=([A-Za-z]{3})') { $colo = $matches[1].ToUpperInvariant() }
            [pscustomobject]@{ IP = $ip; Colo = $colo; Loss = $_.Loss; Ttfb = $_.Ttfb }
        } -ThrottleLimit 16
        foreach ($r in $part) { $rows.Add($r) }

        if ($OnProgress) {
            $done = [math]::Min($i + $chunkSize, $total)
            & $OnProgress $done $total ((Get-Date) - $start).TotalSeconds
        }

        # 覆盖检查只在整批结束后做，保证结果是确定的；不满足就继续全量探测
        if ($EarlyStopColos -and $rows.Count -ge $EarlyStopMinProbe -and
            (Test-ColoCoverage -Rows $rows -Colos $EarlyStopColos -MinPerColo $EarlyStopMinPerColo)) {
            break
        }
    }
    return @($rows)
}

function Select-Stratified {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Candidates,
        [Parameter(Mandatory)][int]$Count
    )
    # 先按 Ttfb 排序，组内也按 Ttfb 排序，避免采样受并行完成顺序影响
    $sorted = @($Candidates | Sort-Object Ttfb)
    $groups = @($sorted | Group-Object Colo | Sort-Object { ($_.Group | Measure-Object -Property Ttfb -Minimum).Minimum })
    $picked = @()
    $idx = 0
    while ($picked.Count -lt $Count) {
        $added = $false
        foreach ($g in $groups) {
            $members = @($g.Group | Sort-Object Ttfb)
            if ($idx -lt $members.Count) {
                $picked += $members[$idx]
                $added = $true
                if ($picked.Count -ge $Count) { break }
            }
        }
        if (-not $added) { break }
        $idx++
    }
    return @($picked)
}

# 识别 Cloudflare 错误页。1034/1003 表示这个边缘 IP 不被该 zone 允许，
# 这种 IP 写进 hosts 会让站点完全打不开，必须当作失败。
function Get-CfErrorClass {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Body)
    if ([string]::IsNullOrEmpty($Body)) { return '' }
    if ($Body -match '(?i)error\s*code:\s*1034' -or $Body -match '(?i)Edge IP Restricted') { return 'restricted' }
    if ($Body -match '(?i)error\s*code:\s*1003' -or $Body -match '(?i)Direct IP access not allowed') { return 'restricted' }
    return ''
}

# 按 HEAD 状态和诊断响应判断单个 IP 对该域名的可用类别。
# unverified 表示 HEAD 403 但诊断请求没拿到可用响应，不能当作可用。
function Get-DomainProbeClass {
    [CmdletBinding()]
    param(
        [int]$HeadExit = 0,
        [AllowEmptyString()][string]$HeadHttp = '',
        [bool]$RemoteOk = $true,
        [int]$DiagExit = -1,
        [AllowEmptyString()][string]$DiagHttp = '',
        [AllowEmptyString()][string]$Body = ''
    )
    if ($HeadExit -ne 0 -or -not $RemoteOk) { return 'bad' }
    switch -Regex ($HeadHttp) {
        '^(200|204|301|302|303|307|308|401)$' { return 'ok' }
        '^(403|503)$' {
            $diagOk = ($DiagExit -eq 0 -and $DiagHttp -in @('200', '206', '403', '503'))
            if (-not $diagOk -or -not $Body) { return 'unverified' }
            $cf = Get-CfErrorClass -Body $Body
            if ($cf -eq 'restricted') { return 'restricted' }
            if ($HeadHttp -eq '403') { return 'waf' }
            return 'bad'
        }
        default { return 'bad' }
    }
}

# 可接受的 HTTP 状态：2xx/3xx + 401/403（登录墙/WAF）
# 但 403/503 会进一步取响应体，排除 CF 的 Edge IP Restricted。
function Test-DomainIp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Domain,
        [string]$Ip = '',
        [Parameter(Mandatory)][string]$CurlExe,
        [int]$MaxTime = 8,
        # 基线探测：不指定 IP，走系统当前的 hosts/DNS 路径
        [switch]$NoResolve
    )
    $resolveArg = if ($NoResolve) { $null } else { "${Domain}:443:$Ip" }
    $r = Invoke-CurlProbe -CurlExe $CurlExe -Url "https://$Domain/" -Resolve $resolveArg -Head -MaxTime $MaxTime

    $remoteOk = $NoResolve -or ($Ip -and $r.RemoteIp -eq $Ip)
    $diagExit = -1
    $diagHttp = ''
    $body = ''

    if ($r.ExitCode -eq 0 -and $remoteOk -and $r.Http -match '^(403|503)$') {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('cf-body-' + [guid]::NewGuid().ToString('N') + '.txt')
        try {
            $diag = Invoke-CurlProbe -CurlExe $CurlExe -Url "https://$Domain/" `
                -Resolve $resolveArg -MaxTime ([math]::Min($MaxTime, 6)) -Output $tmp -Range '0-8191' -MaxFileSize 65536
            $diagExit = $diag.ExitCode
            $diagHttp = $diag.Http
            if ($diagExit -eq 0 -and $diagHttp -in @('200', '206', '403', '503') -and (Test-Path -LiteralPath $tmp)) {
                # 只读前 16KB，避免错误页异常大时占用内存
                $bytes = [IO.File]::ReadAllBytes($tmp)
                $take = [math]::Min($bytes.Length, 16384)
                if ($take -gt 0) { $body = [Text.Encoding]::UTF8.GetString($bytes, 0, $take) }
            }
        } catch {
            $diagExit = -1
            $diagHttp = ''
            $body = ''
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    $class = Get-DomainProbeClass -HeadExit $r.ExitCode -HeadHttp $r.Http -RemoteOk $remoteOk `
        -DiagExit $diagExit -DiagHttp $diagHttp -Body $body

    $ok = ($class -in @('ok', 'waf'))
    return [pscustomobject]@{
        Ok = $ok; Http = $r.Http; Class = $class; Ttfb = $r.Ttfb
        Connect = $r.Connect; Tls = $r.Tls; Dns = $r.Dns
        RemoteIp = $r.RemoteIp; Exit = $r.ExitCode
    }
}

# 在"当前路径基线"和候选之间做选择。
# Baseline: { IP, Ok, Class, Ttfb }；Candidates: { IP, Ok, Class, Ttfb, Source }
function Select-DomainIp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Baseline,
        [Parameter(Mandatory)][AllowEmptyCollection()]$Candidates,
        [ValidateRange(0, 100)][int]$MinImprovementPct = 15,
        [ValidateRange(0, 5000)][int]$MinImprovementMs = 0
    )

    $ranked = @($Candidates | Where-Object { $_ -and $_.Ok -and $_.IP } |
        Sort-Object @{ Expression = { if ($_.Class -eq 'ok') { 0 } else { 1 } } },
                    @{ Expression = 'Ttfb'; Descending = $false })
    $best = $ranked | Select-Object -First 1

    if (-not $best) {
        return [pscustomobject]@{
            IP = $null; Changed = $false; Reason = 'no-working-candidate'
            ImprovementPct = $null; BestIP = $null; BestTtfb = $null
        }
    }
    if (-not $Baseline -or -not $Baseline.Ok -or -not $Baseline.IP) {
        return [pscustomobject]@{
            IP = $best.IP; Changed = $true; Reason = 'baseline-failed'
            ImprovementPct = $null; BestIP = $best.IP; BestTtfb = $best.Ttfb
        }
    }
    if ($best.IP -eq $Baseline.IP) {
        return [pscustomobject]@{
            IP = $Baseline.IP; Changed = $false; Reason = 'baseline-is-best'
            ImprovementPct = 0; BestIP = $best.IP; BestTtfb = $best.Ttfb
        }
    }

    $basePriority = if ($Baseline.Class -eq 'ok') { 0 } else { 1 }
    $bestPriority = if ($best.Class -eq 'ok') { 0 } else { 1 }
    if ($bestPriority -gt $basePriority) {
        return [pscustomobject]@{
            IP = $Baseline.IP; Changed = $false; Reason = 'baseline-class-better'
            ImprovementPct = 0; BestIP = $best.IP; BestTtfb = $best.Ttfb
        }
    }
    if ($bestPriority -lt $basePriority) {
        return [pscustomobject]@{
            IP = $best.IP; Changed = $true; Reason = 'better-class'
            ImprovementPct = $null; BestIP = $best.IP; BestTtfb = $best.Ttfb
        }
    }
    if ($Baseline.Ttfb -le 0) {
        return [pscustomobject]@{
            IP = $best.IP; Changed = $true; Reason = 'baseline-no-ttfb'
            ImprovementPct = $null; BestIP = $best.IP; BestTtfb = $best.Ttfb
        }
    }

    # 判定用未舍入的值：14.96% 不能因为四舍五入变成 15.0 而被放行，
    # 恰好 15%/30ms 也不能因为浮点误差（14.999999999999996）被误拒。
    # 舍入只用于展示。
    $pctRaw = (($Baseline.Ttfb - $best.Ttfb) / $Baseline.Ttfb) * 100
    $improvement = [math]::Round($pctRaw, 1)
    $deltaMs = ($Baseline.Ttfb - $best.Ttfb) * 1000
    if (($pctRaw -ge ($MinImprovementPct - 1e-9)) -and ($deltaMs -ge ($MinImprovementMs - 1e-6))) {
        return [pscustomobject]@{
            IP = $best.IP; Changed = $true; Reason = 'improved'
            ImprovementPct = $improvement; BestIP = $best.IP; BestTtfb = $best.Ttfb
        }
    }
    return [pscustomobject]@{
        IP = $Baseline.IP; Changed = $false; Reason = 'below-threshold'
        ImprovementPct = $improvement; BestIP = $best.IP; BestTtfb = $best.Ttfb
    }
}

# 本次没有可用决策时，如何处理旧映射。
# 只有明确的 1034/1003 才自动丢弃；连接失败默认保留，除非显式 -DropUnreachable。
# 展示用的中文化映射。只影响控制台表格和逐站结果行，plan.json 里仍是原始代码。
function Get-ReasonText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Reason = '')
    $map = @{
        'improved'                = '更快'
        'better-class'            = '状态更好'
        'baseline-failed'         = '基线不可用'
        'baseline-is-best'        = '基线已最优'
        'baseline-class-better'   = '基线状态更好'
        'baseline-no-ttfb'        = '基线无延迟'
        'below-threshold'         = '未达阈值'
        'no-working-candidate'    = '无可用候选'
        'candidate-flaky'         = '候选不稳定'
        'baseline-ip-changed'     = '复核时基线换了 IP'
        'candidate-budget-exhausted' = '候选请求预算已用尽'
        'baseline-failed-on-retest' = '复核时基线失败'
        'confirmed-class'         = '复核确认（状态）'
        'not-confirmed'           = '复核未通过'
        'candidate-degraded'      = '复核时候选变差'
        'confirmed'               = '复核确认'
    }
    if ($map.ContainsKey($Reason)) { return $map[$Reason] }
    return $Reason
}

function Get-ActionText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Action = '')
    $map = @{
        'update'           = '更新'
        'keep'             = '保留'
        'release'          = '交还 DNS'
        'drop'             = '丢弃'
        'keep-unreachable' = '保留（未验证）'
        'none'             = '未写入'
        'dns'              = '沿用 DNS'
    }
    if ($map.ContainsKey($Action)) { return $map[$Action] }
    return $Action
}

function Get-PreviousAction {
    [CmdletBinding()]
    param(
        [bool]$HasPrevious,
        $Baseline,
        $Decision,
        [switch]$DropUnreachable
    )
    if (-not $HasPrevious) { return 'none' }
    if ($Decision -and $Decision.IP) { return 'keep' }
    if ($Baseline -and $Baseline.Class -eq 'restricted') { return 'drop' }
    # 基线本身可用（只是本次没有可用候选）时，旧映射是健康的，不能因
    # -DropUnreachable 被误删。
    if ($Baseline -and $Baseline.Ok) { return 'keep' }
    if ($DropUnreachable) { return 'drop' }
    return 'keep-unreachable'
}

# 类别优先级：ok 最好，waf 次之，restricted/bad/unverified 最差
function Get-CfClassRank {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Class = '')
    switch ($Class) {
        'ok' { return 0 }
        'waf' { return 1 }
        default { return 2 }
    }
}

# 切换前复核：只比较"基线"和"准备切换到的那个候选"，不再在全部候选里重选；
# 候选任意一次复测失败都不切换。
function Resolve-SwitchConfirmation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][double]$BaseTtfb,
        [Parameter(Mandatory)][double]$BestTtfb,
        [AllowEmptyCollection()][double[]]$BaseSamples = @(),
        [AllowEmptyCollection()][double[]]$CandidateSamples = @(),
        [switch]$CandidateFlaky,
        [switch]$BaselineRetestFailed,
        [AllowEmptyString()][string]$BaselineClass = '',
        [AllowEmptyString()][string]$CandidateClass = '',
        [ValidateSet('improved', 'better-class', 'baseline-no-ttfb', 'baseline-failed')][string]$Reason = 'improved',
        [ValidateRange(0, 100)][int]$MinImprovementPct = 15,
        [ValidateRange(0, 5000)][int]$MinImprovementMs = 30
    )

    if ($CandidateFlaky) {
        return [pscustomobject]@{ Switch = $false; Reason = 'candidate-flaky'; Pct = $null; BaseMs = $null; BestMs = $null }
    }
    if ($BaselineRetestFailed) {
        return [pscustomobject]@{ Switch = $true; Reason = 'baseline-failed-on-retest'; Pct = $null; BaseMs = $null; BestMs = $null }
    }

    # 复核时重新比较类别：候选更差拒绝，更好直接确认，打平回到时间门槛。
    # 不能沿用首次的 Reason（例如首次 better-class，复核时基线已恢复正常）。
    $baseRank = if ($BaselineClass) { Get-CfClassRank -Class $BaselineClass } else { $null }
    $candRank = if ($CandidateClass) { Get-CfClassRank -Class $CandidateClass } else { $null }
    if ($null -ne $baseRank -and $null -ne $candRank) {
        if ($candRank -gt $baseRank) {
            return [pscustomobject]@{ Switch = $false; Reason = 'candidate-degraded'; Pct = $null; BaseMs = $null; BestMs = $null }
        }
        if ($candRank -lt $baseRank) {
            return [pscustomobject]@{ Switch = $true; Reason = 'confirmed-class'; Pct = $null; BaseMs = $null; BestMs = $null }
        }
    }

    $baseMedian = Get-Median -Values (@($BaseTtfb) + @($BaseSamples))
    $bestMedian = Get-Median -Values (@($BestTtfb) + @($CandidateSamples))
    if ($null -eq $baseMedian -or $null -eq $bestMedian -or $baseMedian -le 0) {
        # 确实没有可比的基线时间：只有原本就是 baseline-no-ttfb 才允许确认
        if ($Reason -eq 'baseline-no-ttfb') {
            return [pscustomobject]@{ Switch = $true; Reason = 'confirmed-class'; Pct = $null; BaseMs = $null; BestMs = $null }
        }
        return [pscustomobject]@{ Switch = $false; Reason = 'not-confirmed'; Pct = $null; BaseMs = $null; BestMs = $null }
    }

    $pctRaw = (($baseMedian - $bestMedian) / $baseMedian) * 100
    $pct = [math]::Round($pctRaw, 1)
    $deltaMs = ($baseMedian - $bestMedian) * 1000
    # 与初选一致：未舍入值比较 + 极小容差，避免恰好 15%/30ms 被浮点误差挡掉
    $ok = ($pctRaw -ge ($MinImprovementPct - 1e-9)) -and ($deltaMs -ge ($MinImprovementMs - 1e-6))
    return [pscustomobject]@{
        Switch = $ok
        Reason = if ($ok) { 'confirmed' } else { 'not-confirmed' }
        Pct    = $pct
        BaseMs = [math]::Round($baseMedian * 1000)
        BestMs = [math]::Round($bestMedian * 1000)
    }
}

# 根据决策、基线来源和候选来源确定动作。纯函数，便于测试 release/update/keep/dns。
function Get-DomainAction {
    [CmdletBinding()]
    param(
        $Decision,
        [bool]$BaselineFromBlock,
        [string]$ChosenSource,
        $Baseline,
        [switch]$DropUnreachable
    )
    if ($Decision -and $Decision.Changed -and $Decision.IP -and $ChosenSource -eq 'dns') { return 'release' }
    if ($Decision -and $Decision.Changed -and $Decision.IP) { return 'update' }
    if ($Decision -and $Decision.IP) {
        if ($BaselineFromBlock) { return 'keep' }
        return 'dns'
    }
    return Get-PreviousAction -HasPrevious:$BaselineFromBlock -Baseline $Baseline -Decision $Decision -DropUnreachable:$DropUnreachable
}

# 复核之后构造最终决策。复核中位数已经写回 baseline/best，本函数只负责
# 选择 IP 和 Reason，便于测试“确认/未确认”。
function Resolve-ConfirmedDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Confirm,
        [Parameter(Mandatory)]$Best,
        [Parameter(Mandatory)][string]$BaselineIP
    )
    if ($Confirm.Switch) {
        return [pscustomobject]@{
            IP = $Best.IP; Changed = $true
            Reason = $Confirm.Reason; ImprovementPct = $Confirm.Pct
            BestIP = $Best.IP; BestTtfb = $Best.Ttfb
        }
    }
    return [pscustomobject]@{
        IP = $BaselineIP; Changed = $false
        Reason = $Confirm.Reason; ImprovementPct = $Confirm.Pct
        BestIP = $Best.IP; BestTtfb = $Best.Ttfb
    }
}

# ProxyOverride 匹配。除了标准语法（精确域名或 *.example.com），也接受
# 用户常见的非标准写法：带端口、以点开头（.example.com）。
function Test-BypassStrict {
    [CmdletBinding()]
    param([string]$Domain, [string]$Bypass)
    foreach ($raw in ($Bypass -split ';')) {
        $e = $raw.Trim()
        if (-not $e -or $e -eq '<local>') { continue }
        if ($e -match '^(?<host>.+):\d+$') { $e = $matches['host'] }
        if ($e.StartsWith('.')) {
            if ($Domain -ieq $e.TrimStart('.')) { return $true }
            $e = "*$e"
        }
        if ($e.Contains('*')) {
            if ($Domain -like $e) { return $true }
        } elseif ($Domain -ieq $e) {
            return $true
        }
    }
    return $false
}

# 定位 cfst.exe。显式路径可以是文件或目录；传目录时找里面的 cfst.exe，
# 避免"找到"目录后运行失败又静默回退。单独放在 lib 里以便离线测试。
function Find-Cfst {
    [CmdletBinding()]
    param(
        [string]$Explicit,
        [string]$Root
    )
    if ($Explicit) {
        $candidate = $Explicit
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $candidate = Join-Path $candidate 'cfst.exe'
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
        throw "指定的 cfst.exe 不存在：$Explicit"
    }
    if ($Root) {
        foreach ($c in @((Join-Path $Root 'cfst\cfst.exe'), (Join-Path $Root 'cfst.exe'))) {
            if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path }
        }
    }
    return $null
}

# 从 `cfst.exe -h` 的输出里取版本号。纯函数，便于测试。
function ConvertFrom-CfstHelpText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text = '')
    if (-not $Text) { return '' }
    $m = [regex]::Match($Text, 'CloudflareSpeedTest\s+v?([0-9][0-9A-Za-z\.\-]*)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# 用 -h 读取版本（-v 会顺带联网查更新）。读不到时返回空串，不影响调用方。
function Get-CfstVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Exe)
    if (-not (Test-Path -LiteralPath $Exe)) { return '' }
    try {
        $out = @(& $Exe -h 2>&1 | Select-Object -First 4)
        return ConvertFrom-CfstHelpText -Text ($out -join "`n")
    } catch {
        return ''
    }
}

# 组装机器可读的 -Plan 文档。纯函数，便于测试字段和结构。
function New-PlanDocument {
    [CmdletBinding()]
    param(
        [string]$Version,
        [string]$HostsPath,
        [AllowEmptyCollection()]$Decisions = @(),
        [AllowEmptyCollection()]$Warnings = @(),
        $FinalMap,
        [bool]$Changed
    )
    $plan = [System.Collections.Generic.List[object]]::new()
    if ($FinalMap) {
        foreach ($k in @($FinalMap.Keys)) {
            foreach ($ip in @($FinalMap[$k])) {
                $plan.Add([pscustomobject]@{ IP = [string]$ip; Domain = [string]$k })
            }
        }
    }
    $warn = @($Warnings | Where-Object { $_ } | ForEach-Object {
            [pscustomobject]@{ Domain = $_.Domain; Line = $_.Line; IP = $_.Ip; Kind = $_.Kind }
        })
    return [pscustomobject]@{
        Version     = $Version
        GeneratedAt = (Get-Date).ToString('o')
        HostsPath   = $HostsPath
        DryRun      = $true
        Changed     = $Changed
        Decisions   = @($Decisions)
        Plan        = @($plan)
        Warnings    = $warn
    }
}
