#Requires -Version 7.0
<#
.SYNOPSIS
    从本地来源提取域名候选，供 Cloudflare-Hosts-Optimizer.ps1 使用。

.DESCRIPTION
    支持四种来源：
      Depiler      PT-Depiler 备份 ZIP 的 metadata.json（只读 sites.url；可选 siteHostMap）
      ProxyBypass  Windows 系统代理的 ProxyOverride 列表
      Text         文本文件里的 URL / 主机名
      Clipboard    剪贴板里的 URL / 主机名

    导入阶段不访问网络，只输出主机名；绝不读取 cookies.json / userInfo.json，
    也不输出 passkey、完整 URL 或站点名称。

.PARAMETER Source
    Depiler | ProxyBypass | Text | Clipboard

.PARAMETER Path
    Depiler 备份 ZIP，或 Text 文本文件。

.PARAMETER OutFile
    输出文件，默认 .\domains.imported.txt。默认不覆盖 domains.txt。

.PARAMETER IncludeAlternates
    Depiler：同时导入 siteHostMap 中的备用/CDN 主机名。

.PARAMETER IncludeOffline
    Depiler：包含 isOffline 的站点。

.PARAMETER Merge
    把新增域名合并到 domains.txt（或 -MergeTarget），保留原有注释和条目。

.PARAMETER MergeTarget
    与 -Merge 配合，默认 .\domains.txt。

.EXAMPLE
    .\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip'

.EXAMPLE
    .\Import-Domains.ps1 -Source ProxyBypass

.EXAMPLE
    .\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip' -IncludeAlternates -Merge
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Depiler', 'ProxyBypass', 'Text', 'Clipboard')]
    [string]$Source,

    [string]$Path,
    [string]$OutFile = 'domains.imported.txt',
    [switch]$IncludeAlternates,
    [switch]$IncludeOffline,
    [switch]$Merge,
    [string]$MergeTarget,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

. (Join-Path $Root 'lib\Domains.ps1')
. (Join-Path $Root 'lib\Import.ps1')

function Fail {
    param([string]$Message, [int]$Code = 2)
    Write-Host "错误：$Message" -ForegroundColor Red
    exit $Code
}

try {
    $result = switch ($Source) {
        'Depiler' {
            if (-not $Path) { throw '使用 -Source Depiler 时必须提供 -Path <备份.zip>' }
            Get-DepilerDomains -ZipPath $Path -WithAlternates:$IncludeAlternates -WithOffline:$IncludeOffline
        }
        'ProxyBypass' { Get-ProxyBypassDomains }
        'Text' {
            if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { throw "找不到文本文件：$Path" }
            Get-TextDomains -Text (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
        }
        'Clipboard' {
            $txt = Get-Clipboard -Raw -ErrorAction SilentlyContinue
            if (-not $txt) { throw '剪贴板为空。' }
            Get-TextDomains -Text $txt
        }
    }
} catch {
    Fail $_.Exception.Message 3
}

if (-not $result -or $result.Domains.Count -eq 0) { Fail '没有提取到任何域名。' 3 }

if ($Merge) {
    $target = if ($MergeTarget) { $MergeTarget } else { Join-Path $Root 'domains.txt' }
    $m = Merge-IntoDomainsFile -Target $target -NewDomains $result.Domains -SourceName $Source
    Write-Host "来源：$Source" -ForegroundColor Cyan
    Write-Host "说明：$($result.Note)" -ForegroundColor DarkGray
    Write-Host "提取：$($result.Domains.Count) 个域名" -ForegroundColor Gray
    Write-Host "合并：新增 $($m.Added) 个 -> $($m.Target)" -ForegroundColor Green
    if ($m.Backup) { Write-Host "备份：$($m.Backup)" -ForegroundColor DarkGray }
    exit 0
}

$outPath = if ([IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path (Get-Location).Path $OutFile }
if ((Resolve-Path -LiteralPath $outPath -ErrorAction SilentlyContinue) -and
    ([IO.Path]::GetFileName($outPath) -ieq 'domains.txt') -and -not $Force) {
    Fail '拒绝直接覆盖 domains.txt。请先输出到 domains.imported.txt 人工检查，或使用 -Merge。'
}

Write-DomainsFile -FilePath $outPath -SourceName $Source -Domains $result.Domains -Note $result.Note
Write-Host "来源：$Source" -ForegroundColor Cyan
Write-Host "说明：$($result.Note)" -ForegroundColor DarkGray
Write-Host "提取：$($result.Domains.Count) 个域名" -ForegroundColor Gray
Write-Host "输出：$outPath" -ForegroundColor Green
exit 0
