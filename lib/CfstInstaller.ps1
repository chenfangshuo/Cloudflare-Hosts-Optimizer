#Requires -Version 7.0
<#
    CFST 的下载与安装。

    边界：
      * 只从官方 GitHub Release（或用户提供的本地 zip）取包；不内置第三方镜像。
      * 只解出根级 cfst.exe 与 ip.txt，其余条目（ipv6.txt、bat、说明文件）忽略。
      * 解包前后逐项校验：zip 头、条目名、大小、压缩比、MZ 头、ip.txt 里的 CIDR。
      * 上游没有发布 checksum/签名，SHA256 只用于记录和比对，不代表已验证安全。
      * 下载方式：直连（清代理环境变量）或显式系统代理；不静默切换。
#>

$script:CfstRepo = 'XIU2/CloudflareSpeedTest'
$script:CfstLanzouUrl = 'https://xiu.lanzoub.com/b0742hkxe'

function Get-CfstSourceLinks {
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        GitHub = "https://github.com/$($script:CfstRepo)/releases"
        Lanzou = $script:CfstLanzouUrl
        Repo   = "https://github.com/$($script:CfstRepo)"
    }
}

function Get-CfstArchitecture {
    [CmdletBinding()]
    param()
    $arch = ''
    try { $arch = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture }
    catch { $arch = [string]$env:PROCESSOR_ARCHITECTURE }
    switch ($arch.ToUpperInvariant()) {
        'X64' { return 'amd64' }
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        'X86' { return '386' }
        '386' { return '386' }
    }
    throw "不支持的 CPU 架构：$arch"
}

function Get-CfstAssetName {
    [CmdletBinding()]
    param([string]$Architecture)
    $a = if ($Architecture) { $Architecture.Trim().ToLowerInvariant() } else { Get-CfstArchitecture }
    switch ($a) {
        'amd64' { return 'cfst_windows_amd64.zip' }
        'x64' { return 'cfst_windows_amd64.zip' }
        'arm64' { return 'cfst_windows_arm64.zip' }
        'x86' { return 'cfst_windows_386.zip' }
        '386' { return 'cfst_windows_386.zip' }
        'i386' { return 'cfst_windows_386.zip' }
    }
    throw "不支持的 CPU 架构：$Architecture"
}

function Get-CfstDownloadUrl {
    [CmdletBinding()]
    param(
        [string]$Architecture,
        [string]$Version
    )
    $asset = Get-CfstAssetName -Architecture $Architecture
    if ($asset -notmatch '^[A-Za-z0-9_.\-]+$') { throw "资产名不合法：$asset" }
    if ($Version) {
        $v = $Version.Trim()
        if ($v -match '^\d') { $v = "v$v" }
        if ($v -notmatch '^v[0-9][0-9A-Za-z.\-]*$') { throw "版本号格式不正确：$Version" }
        return "https://github.com/$($script:CfstRepo)/releases/download/$v/$asset"
    }
    return "https://github.com/$($script:CfstRepo)/releases/latest/download/$asset"
}

# 解析 WinINET 的 ProxyServer 值。支持 host:port、http=...;https=...、socks=...
function ConvertFrom-ProxyServer {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value = '')
    $result = [pscustomobject]@{ Url = ''; Scheme = ''; Reason = ''; HasCredentials = $false }
    $v = if ($Value) { $Value.Trim() } else { '' }
    if (-not $v) { $result.Reason = '未配置代理服务器'; return $result }

    $candidate = $v
    $schemeHint = 'http'
    if ($v.Contains('=')) {
        $entries = [ordered]@{}
        foreach ($part in ($v -split ';')) {
            $p = $part.Trim()
            if (-not $p) { continue }
            $i = $p.IndexOf('=')
            if ($i -le 0) { continue }
            $k = $p.Substring(0, $i).Trim().ToLowerInvariant()
            $val = $p.Substring($i + 1).Trim()
            if ($val -and -not $entries.Contains($k)) { $entries[$k] = $val }
        }
        $picked = ''
        foreach ($k in @('https', 'http', 'socks5h', 'socks5', 'socks')) {
            if ($entries.Contains($k)) {
                $picked = $entries[$k]
                if ($k -like 'socks*') { $schemeHint = 'socks5h' }
                break
            }
        }
        if (-not $picked) {
            $result.Reason = '代理协议不支持（只支持 HTTP/HTTPS/SOCKS5）'
            return $result
        }
        $candidate = $picked
    }

    if ($candidate -notmatch '^[A-Za-z][A-Za-z0-9+.\-]*://') { $candidate = "${schemeHint}://$candidate" }
    $uri = $null
    if (-not [uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri)) {
        $result.Reason = '代理地址格式不正确'
        return $result
    }
    $scheme = $uri.Scheme.ToLowerInvariant()
    if ($scheme -notin @('http', 'https', 'socks5', 'socks5h')) {
        $result.Reason = "代理协议不支持：$scheme"
        return $result
    }
    if (-not $uri.Host) { $result.Reason = '代理地址缺少主机名'; return $result }
    if ($uri.Port -lt 1 -or $uri.Port -gt 65535) { $result.Reason = '代理端口不正确'; return $result }
    if ($uri.UserInfo) {
        $result.HasCredentials = $true
        $result.Reason = '代理地址带凭据，请用 -Proxy 显式指定或改用本地 zip'
        return $result
    }
    $result.Url = $candidate
    $result.Scheme = $scheme
    return $result
}

# 读 HKCU 的 WinINET 代理设置。测试时可直接传 ProxyEnable/ProxyServer/AutoConfigUrl。
function Get-SystemProxyUrl {
    [CmdletBinding()]
    param(
        [string]$RegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
        [System.Nullable[int]]$ProxyEnable,
        [AllowEmptyString()][string]$ProxyServer,
        [AllowEmptyString()][string]$AutoConfigUrl
    )
    $bound = $PSBoundParameters
    if (-not $bound.ContainsKey('ProxyEnable') -or -not $bound.ContainsKey('ProxyServer') -or -not $bound.ContainsKey('AutoConfigUrl')) {
        $key = $null
        try { $key = Get-ItemProperty -Path $RegistryPath -ErrorAction Stop } catch { $key = $null }
        if (-not $bound.ContainsKey('ProxyEnable')) { $ProxyEnable = if ($key) { [int]$key.ProxyEnable } else { 0 } }
        if (-not $bound.ContainsKey('ProxyServer')) { $ProxyServer = if ($key) { [string]$key.ProxyServer } else { '' } }
        if (-not $bound.ContainsKey('AutoConfigUrl')) { $AutoConfigUrl = if ($key) { [string]$key.AutoConfigURL } else { '' } }
    }
    $result = [pscustomobject]@{ Enabled = ($ProxyEnable -eq 1); Url = ''; Reason = ''; HasCredentials = $false }
    if (-not $result.Enabled) { $result.Reason = '未启用 WinINET 系统代理'; return $result }
    if (-not $ProxyServer) {
        $result.Reason = if ($AutoConfigUrl) {
            '系统使用 PAC 自动配置，本工具不支持；请用 -Proxy 或本地 zip'
        } else {
            '系统代理已启用，但没有配置代理服务器'
        }
        return $result
    }
    $parsed = ConvertFrom-ProxyServer -Value $ProxyServer
    $result.Url = $parsed.Url
    $result.Reason = $parsed.Reason
    $result.HasCredentials = $parsed.HasCredentials
    return $result
}

function Test-ZipEntryNamesSafe {
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Names = @())
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $Names) {
        if ([string]::IsNullOrWhiteSpace($n)) { return $false }
        if ($n -match '[\x00-\x1F]') { return $false }
        if ($n.StartsWith('/') -or $n.StartsWith('\')) { return $false }
        if ($n.StartsWith('\\')) { return $false }
        if ($n -match '^[A-Za-z]:') { return $false }
        if (($n -split '[\\/]') -contains '..') { return $false }
        if (-not $seen.Add($n)) { return $false }
    }
    return $true
}

function Test-CfstExecutableFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $fs = [IO.File]::OpenRead($Path)
    try {
        if ($fs.Length -lt 2) { return $false }
        $b = [byte[]]::new(2)
        [void]$fs.Read($b, 0, 2)
        return ($b[0] -eq 0x4D -and $b[1] -eq 0x5A)
    } finally {
        $fs.Dispose()
    }
}

# 校验单个 IPv4 CIDR：四段 0–255，前缀 0–32
function Test-Ipv4Cidr {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text = '')
    $m = [regex]::Match($Text.Trim(), '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$')
    if (-not $m.Success) { return $false }
    for ($i = 1; $i -le 4; $i++) {
        if ([int]$m.Groups[$i].Value -gt 255) { return $false }
    }
    $prefix = [int]$m.Groups[5].Value
    return ($prefix -ge 0 -and $prefix -le 32)
}

function Test-CfstIpListFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $count = 0
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        # 任何一条非注释行不合法就整体拒绝，不能靠“有一行能匹配”通过
        if (-not (Test-Ipv4Cidr -Text $t)) { return $false }
        $count++
    }
    return ($count -gt 0)
}

# 只解根级 cfst.exe 和 ip.txt；校验通过后才移进目标目录。
function Expand-CfstArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Force,
        [long]$MinZipBytes = 1MB,
        [long]$MaxZipBytes = 50MB,
        [long]$MaxExeBytes = 32MB,
        [long]$MaxIpBytes = 1MB
    )
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw "找不到 zip：$ZipPath" }
    $info = Get-Item -LiteralPath $ZipPath
    if ($info.Length -lt $MinZipBytes) { throw "zip 太小（$($info.Length) 字节），不像是 CFST 发布包。" }
    if ($info.Length -gt $MaxZipBytes) { throw "zip 太大（$($info.Length) 字节），拒绝处理。" }

    $head = [byte[]]::new(4)
    $fs = [IO.File]::OpenRead($ZipPath)
    try { [void]$fs.Read($head, 0, 4) } finally { $fs.Dispose() }
    if (-not ($head[0] -eq 0x50 -and $head[1] -eq 0x4B -and $head[2] -eq 0x03 -and $head[3] -eq 0x04)) {
        throw '文件不是 zip（缺少 PK 头）。'
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = $null
    try {
        try { $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath) }
        catch { throw "无法读取 zip：$($_.Exception.Message)" }

        $entries = @($archive.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
        if (-not (Test-ZipEntryNamesSafe -Names @($entries | ForEach-Object FullName))) {
            throw 'zip 中存在不安全的条目名（绝对路径或 ..），拒绝解压。'
        }
        $exeEntries = @($entries | Where-Object { $_.FullName -ieq 'cfst.exe' })
        $ipEntries = @($entries | Where-Object { $_.FullName -ieq 'ip.txt' })
        if ($exeEntries.Count -ne 1 -or $ipEntries.Count -ne 1) {
            throw 'zip 结构不符合预期：需要根级 cfst.exe 和 ip.txt 各一个。请手动解压后把这两个文件放进 cfst 目录。'
        }
        $exeEntry = $exeEntries[0]
        $ipEntry = $ipEntries[0]
        if ($exeEntry.Length -lt 1 -or $exeEntry.Length -gt $MaxExeBytes) { throw "cfst.exe 大小异常：$($exeEntry.Length) 字节。" }
        if ($ipEntry.Length -lt 1 -or $ipEntry.Length -gt $MaxIpBytes) { throw "ip.txt 大小异常：$($ipEntry.Length) 字节。" }
        foreach ($e in @($exeEntry, $ipEntry)) {
            if ($e.CompressedLength -gt 0 -and ($e.Length / $e.CompressedLength) -gt 100) {
                throw "条目 $($e.FullName) 压缩比异常，拒绝解压。"
            }
        }

        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('cfo-cfst-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $tmpExe = Join-Path $tmp 'cfst.exe'
            $tmpIp = Join-Path $tmp 'ip.txt'
            [IO.Compression.ZipFileExtensions]::ExtractToFile($exeEntry, $tmpExe, $true)
            [IO.Compression.ZipFileExtensions]::ExtractToFile($ipEntry, $tmpIp, $true)
            if (-not (Test-CfstExecutableFile -Path $tmpExe)) {
                throw '解出来的 cfst.exe 不是有效的 Windows 可执行文件（缺少 MZ 头）。'
            }
            if (-not (Test-CfstIpListFile -Path $tmpIp)) {
                throw '解出来的 ip.txt 里没有合法的 CIDR 网段。'
            }

            if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
            $destExe = Join-Path $Destination 'cfst.exe'
            $destIp = Join-Path $Destination 'ip.txt'
            if (-not $Force -and (Test-Path -LiteralPath $destExe) -and (Test-Path -LiteralPath $destIp)) {
                return [pscustomobject]@{
                    Installed = $false; Skipped = $true; Exe = $destExe; IpFile = $destIp
                    Reason = '目标已存在，未覆盖（加 -Force 覆盖）'
                }
            }
            Move-Item -LiteralPath $tmpExe -Destination $destExe -Force
            Move-Item -LiteralPath $tmpIp -Destination $destIp -Force
            return [pscustomobject]@{ Installed = $true; Skipped = $false; Exe = $destExe; IpFile = $destIp; Reason = '' }
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    } finally {
        if ($archive) { $archive.Dispose() }
    }
}

function Get-CfstInstallState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Destination,
        [switch]$WithVersion
    )
    $exe = Join-Path $Destination 'cfst.exe'
    $ip = Join-Path $Destination 'ip.txt'
    $hasExe = Test-Path -LiteralPath $exe -PathType Leaf
    $hasIp = Test-Path -LiteralPath $ip -PathType Leaf
    $ver = ''
    if ($WithVersion -and $hasExe -and (Get-Command Get-CfstVersion -ErrorAction SilentlyContinue)) {
        $ver = Get-CfstVersion -Exe $exe
    }
    [pscustomobject]@{
        Dir = $Destination; Exe = $exe; IpFile = $ip
        HasExe = $hasExe; HasIp = $hasIp; Installed = ($hasExe -and $hasIp); Version = $ver
    }
}

# 下载 zip。直连时清空代理环境变量；代理时清 NO_PROXY，显式 --proxy。
function Invoke-CfstDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][string]$CurlExe,
        [string]$ProxyUrl,
        [int]$TimeoutSec = 180
    )
    $headerFile = "$OutFile.headers"
    $names = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    try {
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $null) }
        $curlArgs = @(
            '-q', '-sS', '--fail', '-L', '--max-redirs', '5',
            '--proto', '=https', '--proto-redir', '=https', '--tlsv1.2',
            '--connect-timeout', '10', '--max-time', [string]$TimeoutSec,
            '--retry', '2', '--retry-delay', '2', '--retry-connrefused',
            '--max-filesize', '52428800',
            '-o', $OutFile, '-D', $headerFile,
            '-w', '|@@|%{http_code}|%{size_download}|%{url_effective}'
        )
        if ($ProxyUrl) { $curlArgs += @('--proxy', $ProxyUrl) }
        else { $curlArgs += @('--noproxy', '*') }
        $curlArgs += $Url

        $raw = & $CurlExe @curlArgs 2>&1
        $exit = $LASTEXITCODE
        $text = ($raw -join "`n")
        $p = ($text -split '\|@@\|')[-1] -split '\|'
        $http = if ($p.Count -ge 1) { [string]$p[0] } else { '' }
        $size = if ($p.Count -ge 2) { [long]$p[1] } else { 0 }
        $finalUrl = if ($p.Count -ge 3) { [string]$p[2] } else { '' }
        if ($exit -ne 0) { throw "下载失败（curl 退出码 $exit）。" }
        if ($http -notin @('200', '206')) { throw "下载失败（HTTP $http）。" }
        if ($size -lt 1MB) { throw "下载内容太小（$size 字节），不像是 CFST 发布包。" }

        $uri = $null
        if (-not [uri]::TryCreate($finalUrl, [UriKind]::Absolute, [ref]$uri)) { throw '下载结束后拿不到最终地址。' }
        if ($uri.Scheme -ne 'https') { throw "最终地址不是 https：$($uri.Scheme)" }
        if ($uri.Host -ne 'github.com' -and -not $uri.Host.EndsWith('.githubusercontent.com')) {
            throw "最终地址不在 GitHub 域内：$($uri.Host)"
        }

        $version = ''
        if (Test-Path -LiteralPath $headerFile) {
            $loc = Select-String -LiteralPath $headerFile -Pattern '^\s*location:\s*https://github\.com/[^/]+/[^/]+/releases/download/(v[^/\s]+)/' -AllMatches
            if ($loc -and $loc.Matches.Count -gt 0) { $version = $loc.Matches[-1].Groups[1].Value }
        }
        [pscustomobject]@{ Path = $OutFile; Bytes = $size; Http = $http; FinalUrl = $finalUrl; Version = $version }
    } finally {
        if (Test-Path -LiteralPath $headerFile) { Remove-Item -LiteralPath $headerFile -Force -ErrorAction SilentlyContinue }
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    }
}

function Install-CfstPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Destination,
        [string]$FromFile,
        [switch]$UseProxy,
        [string]$Proxy,
        [switch]$Force,
        [string]$Version,
        [string]$ExpectedSha256,
        [string]$CurlExe
    )
    if ($FromFile -and ($UseProxy -or $Proxy)) { throw '-FromFile 不能与 -UseProxy/-Proxy 同时使用。' }

    $state = Get-CfstInstallState -Destination $Destination
    if ($state.Installed -and -not $Force) {
        $ver = if (Get-Command Get-CfstVersion -ErrorAction SilentlyContinue) { Get-CfstVersion -Exe $state.Exe } else { '' }
        return [pscustomobject]@{
            Installed = $true; Skipped = $true; Source = 'existing'
            Zip = ''; Sha256 = ''; Version = $ver; State = $state
        }
    }

    $zip = $FromFile
    $source = 'file'
    $downloadVersion = $Version
    $tmpZip = $null

    if (-not $zip) {
        $proxyUrl = ''
        if ($Proxy) {
            $parsed = ConvertFrom-ProxyServer -Value $Proxy
            if (-not $parsed.Url) { throw "代理地址不可用：$($parsed.Reason)" }
            $proxyUrl = $parsed.Url
        } elseif ($UseProxy) {
            $sys = Get-SystemProxyUrl
            if (-not $sys.Url) { throw "系统代理不可用：$($sys.Reason)" }
            $proxyUrl = $sys.Url
        }
        if (-not $CurlExe) { $CurlExe = Get-CurlExe }

        $url = Get-CfstDownloadUrl -Version $Version
        $tmpZip = Join-Path ([IO.Path]::GetTempPath()) ('cfo-cfst-' + [guid]::NewGuid().ToString('N') + '.zip')
        $download = Invoke-CfstDownload -Url $url -OutFile $tmpZip -CurlExe $CurlExe -ProxyUrl $proxyUrl
        $zip = $tmpZip
        $source = if ($proxyUrl) { "proxy:$proxyUrl" } else { 'direct' }
        if (-not $downloadVersion) { $downloadVersion = $download.Version }
    } elseif (-not (Test-Path -LiteralPath $zip -PathType Leaf)) {
        throw "找不到 zip：$zip"
    }

    try {
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($ExpectedSha256 -and $hash -ne $ExpectedSha256.Trim().ToLowerInvariant()) {
            throw "SHA256 不匹配：期望 $ExpectedSha256，实际 $hash。"
        }
        $expand = Expand-CfstArchive -ZipPath $zip -Destination $Destination -Force:$Force
        $state2 = Get-CfstInstallState -Destination $Destination
        $ver = ''
        if (Test-Path -LiteralPath $state2.Exe) { $ver = Get-CfstVersion -Exe $state2.Exe }
        if (-not $ver) { $ver = $downloadVersion }
        return [pscustomobject]@{
            Installed = $expand.Installed; Skipped = $expand.Skipped; Source = $source
            Zip = $zip; Sha256 = $hash; Version = $ver; State = $state2; Reason = $expand.Reason
        }
    } finally {
        if ($tmpZip -and (Test-Path -LiteralPath $tmpZip)) {
            Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
        }
    }
}
