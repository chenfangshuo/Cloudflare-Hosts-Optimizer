#Requires -Version 7.0
<#
.SYNOPSIS
    下载并安装 CloudflareSpeedTest（cfst.exe + ip.txt）到本目录的 cfst\。

.DESCRIPTION
    CFST 是第三方 GPL-3.0 软件，本项目不包含也不修改它，只从官方 GitHub Release 下载。
    直连失败时可以用 -UseProxy 走系统代理，或者用浏览器从蓝奏云下载 zip 后 -FromFile。

    只接受 zip：本地 zip 也会做和下载包相同的校验（结构、大小、MZ 头、CIDR）。

.PARAMETER Destination
    安装目录，默认脚本旁的 cfst\。

.PARAMETER FromFile
    用本地 zip 安装，不联网。

.PARAMETER UseProxy
    通过 WinINET 系统代理下载（Clash 的“系统代理”就写在这里）。

.PARAMETER Proxy
    显式指定代理，例如 http://127.0.0.1:7897 或 socks5h://127.0.0.1:7897。

.PARAMETER Force
    覆盖已经安装的 cfst.exe / ip.txt。

.PARAMETER Version
    下载指定版本（如 2.3.5），默认最新。

.PARAMETER ExpectedSha256
    可选：校验下载 zip 的 SHA256。

.EXAMPLE
    .\Install-Cfst.ps1

.EXAMPLE
    .\Install-Cfst.ps1 -UseProxy

.EXAMPLE
    .\Install-Cfst.ps1 -FromFile .\cfst_windows_amd64.zip -Force
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [string]$FromFile,
    [switch]$UseProxy,
    [string]$Proxy,
    [switch]$Force,
    [string]$Version,
    [string]$ExpectedSha256
)

$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

. (Join-Path $Root 'lib\Probe.ps1')
. (Join-Path $Root 'lib\CfstInstaller.ps1')

function Say {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

if (-not $Destination) { $Destination = Join-Path $Root 'cfst' }
if ($FromFile -and ($UseProxy -or $Proxy)) {
    Say '错误：-FromFile 不能与 -UseProxy/-Proxy 同时使用。' 'Red'
    exit 2
}
if ($Proxy) {
    $parsed = ConvertFrom-ProxyServer -Value $Proxy
    if (-not $parsed.Url) {
        Say "错误：代理地址不可用：$($parsed.Reason)" 'Red'
        exit 2
    }
}

$links = Get-CfstSourceLinks
Say ''
Say 'Cloudflare-Hosts-Optimizer · CFST 安装器' 'Cyan'
Say 'CFST 是第三方 GPL-3.0 软件，本项目不包含也不修改它；只从官方仓库下载。' 'DarkGray'
Say "官方仓库：$($links.Repo)" 'DarkGray'
Say ''

try {
    $result = Install-CfstPackage -Destination $Destination -FromFile $FromFile -UseProxy:$UseProxy `
        -Proxy $Proxy -Force:$Force -Version $Version -ExpectedSha256 $ExpectedSha256
} catch {
    Say "错误：$($_.Exception.Message)" 'Red'
    Say ''
    Say '还可以这样：' 'Yellow'
    Say '  1) 走系统代理：.\Install-Cfst.ps1 -UseProxy' 'Gray'
    Say "  2) 浏览器打开 $($links.Lanzou) 下载 zip，再执行 .\Install-Cfst.ps1 -FromFile <zip>" 'Gray'
    exit 1
}

if ($result.Skipped) {
    Say "已安装 CFST$(if ($result.Version) { " v$($result.Version)" })，未覆盖。要覆盖请加 -Force。" 'Green'
    Say "位置：$($result.State.Exe)" 'DarkGray'
    exit 0
}

Say "已安装 CFST$(if ($result.Version) { " v$($result.Version)" })" 'Green'
Say "cfst.exe：$($result.State.Exe)" 'Gray'
Say "ip.txt：$($result.State.IpFile)" 'Gray'
Say "来源：$($result.Source)" 'DarkGray'
Say "SHA256：$($result.Sha256)" 'DarkGray'
Say '上游没有提供校验值或签名，这个 SHA256 仅供记录和比对，不代表已验证安全。' 'DarkGray'
exit 0
