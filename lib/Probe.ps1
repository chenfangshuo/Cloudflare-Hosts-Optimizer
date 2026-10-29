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
        [string]$Proto = '=https',
        [string]$Range,
        [int]$MaxFileSize = 0
    )

    $curlArgs = @('-q', '-sS', '--noproxy', '*', '--max-redirs', '0', '--proto', $Proto, '--max-time', [string]$MaxTime)
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
        [int]$MaxTime = 20
    )

    $target = Split-SpeedTestUrl -UrlTemplate $UrlTemplate
    $targetHost = $target.Host
    $targetPort = $target.Port
    Write-Host "吞吐测速：$($Candidates.Count) 个 IP x $Samples 次 x $([math]::Round($Bytes / 1MB, 1))MB（$targetHost）..." -ForegroundColor Cyan

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
        Write-Host "CFST 目录下缺少 ip.txt：$dir" -ForegroundColor Yellow
        return @()
    }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ('pt-cf-optimize-' + [guid]::NewGuid().ToString('N'))
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
        Write-Host "CFST 延迟扫描退出码：$code" -ForegroundColor DarkGray
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
        [Parameter(Mandatory)][string[]]$Ranges
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

    Write-Host "内置延迟扫描：$($ips.Count) 个候选 IP，每个 $Samples 次探测 ..." -ForegroundColor Cyan
    $probe = $ips | ForEach-Object -Parallel {
        $ip = $_
        $curlPath = $using:CurlExe
        $sampleCount = $using:Samples
        $ok = 0; $ttf = @(); $colo = ''
        for ($i = 0; $i -lt $sampleCount; $i++) {
            $fmt = '|@@|%{time_connect}|%{time_appconnect}|%{time_starttransfer}'
            $raw = & $curlPath -q -sS --noproxy '*' --max-redirs 0 --proto '=https' `
                --max-time 6 --resolve "speed.cloudflare.com:443:$ip" `
                -w $fmt 'https://speed.cloudflare.com/cdn-cgi/trace' 2>$null
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

function Resolve-Colo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CurlExe,
        [Parameter(Mandatory)]$Candidates,
        # 分批探测并在每批结束后回调，避免 256 个候选跑几分钟却没有任何输出
        [scriptblock]$OnProgress
    )
    $list = @($Candidates)
    $total = $list.Count
    $rows = [System.Collections.Generic.List[object]]::new()
    $start = Get-Date
    $chunkSize = 32

    for ($i = 0; $i -lt $total; $i += $chunkSize) {
        $last = [math]::Min($i + $chunkSize - 1, $total - 1)
        $chunk = @($list[$i..$last])
        $part = $chunk | ForEach-Object -Parallel {
            $ip = $_.IP
            $curlPath = $using:CurlExe
            $raw = & $curlPath -q -sS --noproxy '*' --max-redirs 0 --proto '=https' `
                --max-time 6 --resolve "speed.cloudflare.com:443:$ip" `
                'https://speed.cloudflare.com/cdn-cgi/trace' 2>$null
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
    $class = 'bad'
    if ($r.ExitCode -eq 0 -and $remoteOk) {
        switch -Regex ($r.Http) {
            '^(200|204|301|302|303|307|308|401)$' { $class = 'ok' }
            '^(403|503)$' {
                $tmp = Join-Path ([IO.Path]::GetTempPath()) ('cf-body-' + [guid]::NewGuid().ToString('N') + '.txt')
                try {
                    $null = Invoke-CurlProbe -CurlExe $CurlExe -Url "https://$Domain/" `
                        -Resolve $resolveArg -MaxTime ([math]::Min($MaxTime, 6)) -Output $tmp -Range '0-8191' -MaxFileSize 65536
                    $body = ''
                    if (Test-Path -LiteralPath $tmp) {
                        # 只读前 16KB，避免错误页异常大时占用内存
                        $bytes = [IO.File]::ReadAllBytes($tmp)
                        $take = [math]::Min($bytes.Length, 16384)
                        if ($take -gt 0) { $body = [Text.Encoding]::UTF8.GetString($bytes, 0, $take) }
                    }
                    $cf = Get-CfErrorClass -Body $body
                    if ($cf -eq 'restricted') { $class = 'restricted' }
                    elseif ($r.Http -eq '403') { $class = 'waf' }
                    else { $class = 'bad' }
                } catch {
                    if ($r.Http -eq '403') { $class = 'waf' } else { $class = 'bad' }
                } finally {
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                }
            }
            default { $class = 'bad' }
        }
    }

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

    $improvement = [math]::Round((($Baseline.Ttfb - $best.Ttfb) / $Baseline.Ttfb) * 100, 1)
    # 百分比和绝对毫秒门槛都在这里先判一次：不满足的组合不再进入复核，省 2 次 HEAD。
    $deltaMs = ($Baseline.Ttfb - $best.Ttfb) * 1000
    if (($improvement -ge $MinImprovementPct) -and ($deltaMs -ge $MinImprovementMs)) {
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
    if ($Reason -ne 'improved') {
        return [pscustomobject]@{ Switch = $true; Reason = 'confirmed-class'; Pct = $null; BaseMs = $null; BestMs = $null }
    }

    $baseMedian = Get-Median -Values (@($BaseTtfb) + @($BaseSamples))
    $bestMedian = Get-Median -Values (@($BestTtfb) + @($CandidateSamples))
    if ($null -eq $baseMedian -or $null -eq $bestMedian -or $baseMedian -le 0) {
        return [pscustomobject]@{ Switch = $false; Reason = 'not-confirmed'; Pct = $null; BaseMs = $null; BestMs = $null }
    }

    $pct = [math]::Round((($baseMedian - $bestMedian) / $baseMedian) * 100, 1)
    $deltaMs = ($baseMedian - $bestMedian) * 1000
    $ok = ($pct -ge $MinImprovementPct) -and ($deltaMs -ge $MinImprovementMs)
    return [pscustomobject]@{
        Switch = $ok
        Reason = if ($ok) { 'confirmed' } else { 'not-confirmed' }
        Pct    = $pct
        BaseMs = [math]::Round($baseMedian * 1000)
        BestMs = [math]::Round($bestMedian * 1000)
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
