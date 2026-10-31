#Requires -Version 7.0
<#
    端点：探测（cdn-cgi/trace）和吞吐（/__down）地址的校验、可用性预检、主备选择。

    约定：
      * 所有请求都走 lib/Probe.ps1 的 Invoke-CurlProbe（--noproxy、不跟随重定向、只 https）。
      * 只有 trace 端点有备用（cloudflare.com 自己也是 CF 托管，trace 同样返回 colo=）。
        吞吐端点没有可靠的公开替代，运行中换地址会破坏不同 IP 之间的可比性，
        所以只做预检，失败就带上明确提示中止。
      * 用户显式指定的 -ProbeUrl 不回退：静默换掉用户的选择比直接报错更糟。
#>

$script:FallbackProbeUrl = 'https://cloudflare.com/cdn-cgi/trace'

function Split-ProbeUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)
    $u = $null
    if (-not [uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$u)) { throw "ProbeUrl 不是合法 URL：$Url" }
    if ($u.Scheme -ne 'https') { throw 'ProbeUrl 只允许 https。' }
    if ($u.UserInfo) { throw 'ProbeUrl 不允许包含凭据。' }
    if (-not $u.Host) { throw "ProbeUrl 缺少主机名：$Url" }
    if ($u.Fragment) { throw 'ProbeUrl 不允许包含 #片段。' }
    # --resolve 依赖按域名完成 TLS 握手；IP 字面量既没有 SNI 也没有证书匹配
    $ipAddr = $null
    if ([System.Net.IPAddress]::TryParse($u.Host, [ref]$ipAddr)) { throw 'ProbeUrl 必须是域名，不能是 IP 地址。' }
    $port = if ($u.Port -gt 0) { $u.Port } else { 443 }
    if ($port -ne 443) { throw 'ProbeUrl 只支持 443 端口（--resolve 到 CF 边缘时其他端口通常不监听）。' }
    return [pscustomobject]@{ Url = $Url; Host = $u.Host; Port = $port }
}

# 从 cdn-cgi/trace 的响应体里取 colo=XXX；取不到返回空串。
function Get-TraceColo {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Raw = '')
    $m = [regex]::Match($Raw, '(?m)^colo=([A-Za-z]{3})\s*$')
    if ($m.Success) { return $m.Groups[1].Value.ToUpperInvariant() }
    return ''
}

# 吞吐样本的判定规则。与 Invoke-ThroughputTest 并行块里的内联判定必须保持一致：
# 那边在子 runspace 里，无法直接调用本函数，改动时两处一起改。
function Test-DownloadResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Http,
        [Parameter(Mandatory)][double]$Bytes,
        [Parameter(Mandatory)][int]$ExpectedBytes
    )
    if ($ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; Reason = "curl 退出码 $ExitCode" } }
    # 重定向由 --max-redirs 0 挡住，会被这里当成非 200/206 拒绝
    if ($Http -notin @('200', '206')) { return [pscustomobject]@{ Ok = $false; Reason = "HTTP $Http" } }
    if ($Bytes -lt ($ExpectedBytes * 0.95)) {
        return [pscustomobject]@{ Ok = $false; Reason = "只收到 $([int]$Bytes)/$ExpectedBytes 字节" }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

# 纯判定：输入一次 trace 请求的结果，决定端点是否可用。便于离线测试。
function Test-ProbeResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Http,
        [AllowEmptyString()][string]$Raw = ''
    )
    $colo = Get-TraceColo -Raw $Raw
    $ok = ($ExitCode -eq 0 -and $Http -in @('200', '206') -and $colo)
    $detail = if ($ok) { "HTTP $Http，colo=$colo" }
              elseif ($ExitCode -ne 0) { "curl 退出码 $ExitCode" }
              elseif ($Http -notin @('200', '206')) { "HTTP $Http" }
              else { '响应中没有 colo=' }
    return [pscustomobject]@{ Ok = [bool]$ok; Colo = $colo; Detail = $detail }
}

function Test-ProbeEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CurlExe,
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSec = 6
    )
    # -Output '' 表示不写 -o，响应体连同 -w 输出一起进 Raw，才能匹配 colo=
    $r = Invoke-CurlProbe -CurlExe $CurlExe -Url $Url -Output '' -MaxTime $TimeoutSec
    $res = Test-ProbeResponse -ExitCode $r.ExitCode -Http $r.Http -Raw $r.Raw
    return [pscustomobject]@{
        Url    = $Url
        Ok     = $res.Ok
        Colo   = $res.Colo
        Http   = $r.Http
        Detail = $res.Detail
    }
}

# 纯决策函数：输入两次预检结果，决定本次用哪个端点。便于离线测试。
function Select-ProbeEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Primary,
        $Fallback,
        [switch]$AllowFallback
    )
    $primaryHost = ([uri]$Primary.Url).Host
    if ($Primary.Ok) {
        return [pscustomobject]@{
            Url = $Primary.Url; Host = $primaryHost; UsedFallback = $false; Ok = $true
            Detail = $Primary.Detail
        }
    }
    if ($AllowFallback -and $Fallback -and $Fallback.Ok) {
        return [pscustomobject]@{
            Url = $Fallback.Url; Host = ([uri]$Fallback.Url).Host; UsedFallback = $true; Ok = $true
            Detail = "主端点不可用（$($Primary.Detail)），已改用备用（$($Fallback.Detail)）"
        }
    }
    return [pscustomobject]@{
        Url = $Primary.Url; Host = $primaryHost; UsedFallback = $false; Ok = $false
        Detail = $Primary.Detail
    }
}

function Resolve-ProbeEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CurlExe,
        [string]$PrimaryUrl = $script:DefaultProbeUrl,
        [string]$FallbackUrl = $script:FallbackProbeUrl,
        [switch]$AllowFallback,
        [int]$TimeoutSec = 6
    )
    if (-not $PrimaryUrl) { throw 'ProbeUrl 不能为空。' }
    $null = Split-ProbeUrl -Url $PrimaryUrl
    $primary = Test-ProbeEndpoint -CurlExe $CurlExe -Url $PrimaryUrl -TimeoutSec $TimeoutSec
    $fallback = $null
    # 主端点能用就不打备用，省一次请求
    if (-not $primary.Ok -and $AllowFallback) {
        $fallback = Test-ProbeEndpoint -CurlExe $CurlExe -Url $FallbackUrl -TimeoutSec $TimeoutSec
    }
    return Select-ProbeEndpoint -Primary $primary -Fallback $fallback -AllowFallback:$AllowFallback
}

function Test-SpeedEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CurlExe,
        [Parameter(Mandatory)][string]$UrlTemplate,
        [ValidateRange(1024, 1048576)][int]$Bytes = 65536,
        [int]$TimeoutSec = 15
    )
    # 没有 {bytes} 占位符就无法指定要测多少字节，跳过预检而不是拿小文件误判
    if ($UrlTemplate -notmatch '\{bytes\}') {
        return [pscustomobject]@{
            Url = $UrlTemplate; Ok = $true; Skipped = $true; Http = ''; Bytes = 0
            Detail = '地址没有 {bytes} 占位符，跳过预检'
        }
    }
    $url = $UrlTemplate -replace '\{bytes\}', [string]$Bytes
    $r = Invoke-CurlProbe -CurlExe $CurlExe -Url $url -MaxTime $TimeoutSec
    $res = Test-DownloadResult -ExitCode $r.ExitCode -Http $r.Http -Bytes $r.Bytes -ExpectedBytes $Bytes
    return [pscustomobject]@{
        Url     = $url
        Ok      = [bool]$res.Ok
        Skipped = $false
        Http    = $r.Http
        Bytes   = [int]$r.Bytes
        Detail  = if ($res.Ok) { "HTTP $($r.Http)，$([int]$r.Bytes) 字节" } else { $res.Reason }
    }
}
