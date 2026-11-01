#Requires -Version 7.0
<#
    域名规范化与校验。

    只做离线字符串处理，不发网络请求。主脚本和 Import-Domains.ps1 共用。
#>

function ConvertTo-NormalizedDomain {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value,
        # 严格模式：拒绝 URL、端口、路径、凭据（用于 domains.txt / -Domains）
        [switch]$Strict
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $s = $Value.Trim()

    # 控制字符 / 空白一律拒绝
    if ($s -match '[\x00-\x20\x7f]') { return $null }

    if ($Strict) {
        if ($s -match '://') { return $null }
        if ($s -match '[/?#@]') { return $null }
        if ($s -match ':\d+$') { return $null }
    }

    # 完整 URL：只取 Host
    if ($s -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        try { $uri = [uri]$s } catch { return $null }
        if (-not $uri.Host) { return $null }
        $s = $uri.Host
    } else {
        # 去掉 path / query / fragment
        $s = ($s -split '[/?#]')[0]
        # 去掉 userinfo
        if ($s.Contains('@')) { $s = $s.Substring($s.LastIndexOf('@') + 1) }
        # 去掉 :port
        if ($s -match '^(?<host>[^:]+):(?<port>\d+)$') { $s = $matches['host'] }
    }

    $s = $s.Trim().TrimEnd('.').ToLowerInvariant()
    if (-not $s) { return $null }

    # IP 字面量不是域名
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($s, [ref]$ip)) { return $null }

    # IDN -> Punycode（对已经是 ASCII 的域名是幂等的）
    try {
        $idn = [System.Globalization.IdnMapping]::new()
        $s = $idn.GetAscii($s).ToLowerInvariant()
    } catch {
        return $null
    }

    if ($s.Length -lt 3 -or $s.Length -gt 253) { return $null }

    $labels = $s -split '\.'
    if ($labels.Count -lt 2) { return $null }
    foreach ($label in $labels) {
        if ($label.Length -lt 1 -or $label.Length -gt 63) { return $null }
        # 允许 a-z 0-9 和连字符；首尾不能是连字符
        if ($label -notmatch '^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$') { return $null }
    }
    # 顶级域：普通字母后缀，或 IDN 的 punycode
    if ($labels[-1] -notmatch '^(?:[a-z]{2,}|xn--[a-z0-9-]+)$') { return $null }

    return $s
}

function Read-DomainsFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $result = [pscustomobject]@{
        Domains = @()
        Invalid = @()
        # 非法项的原始 token 可能夹带 URL 凭据，用户可见的地方只用 InvalidItems
        InvalidItems = @()
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    $domains = [System.Collections.Generic.List[string]]::new()
    $invalid = [System.Collections.Generic.List[string]]::new()
    $invalidItems = [System.Collections.Generic.List[object]]::new()

    $lineNo = 0
    foreach ($raw in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $lineNo++
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $token = ($line -split '\s+')[0]
        $domain = ConvertTo-NormalizedDomain -Value $token -Strict
        if ($domain) {
            if (-not $domains.Contains($domain)) { $domains.Add($domain) }
        } else {
            $invalid.Add($token)
            $invalidItems.Add([pscustomobject]@{
                    Line    = $lineNo
                    Preview = Get-SafeInputPreview -Value $token
                })
        }
    }

    $result.Domains = @($domains)
    $result.Invalid = @($invalid)
    $result.InvalidItems = @($invalidItems)
    return $result
}

function Merge-DomainLists {
    [CmdletBinding()]
    param(
        [string[]]$Existing = @(),
        [string[]]$New = @()
    )
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $merged = [System.Collections.Generic.List[string]]::new()
    $added = [System.Collections.Generic.List[string]]::new()

    foreach ($d in $Existing) {
        $n = ConvertTo-NormalizedDomain -Value $d -Strict
        if ($n -and $seen.Add($n)) { $merged.Add($n) }
    }
    foreach ($d in $New) {
        $n = ConvertTo-NormalizedDomain -Value $d -Strict
        if ($n -and $seen.Add($n)) {
            $merged.Add($n)
            $added.Add($n)
        }
    }
    return [pscustomobject]@{ Domains = @($merged); Added = @($added) }
}
