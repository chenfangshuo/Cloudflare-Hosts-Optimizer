#Requires -Version 7.0
<#
.SYNOPSIS
    生成发布 zip 和 SHA256。只包含 git 已跟踪的文件，不会带上 domains.txt、cfst/、
    backup/、plan.json 或 dist/；.gitattributes 里 export-ignore 的开发文件（.github/、
    tests/、scripts/、CONTRIBUTING.md 等）也不会进包。

    归档统一放在顶层 Cloudflare-Hosts-Optimizer\ 目录下，解压后是单个文件夹。

.EXAMPLE
    pwsh -NoProfile -File .\scripts\Package-Release.ps1 -Version 0.3.9
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

Push-Location $root
try {
    $dirty = @(git status --porcelain)
    if ($dirty.Count -gt 0) {
        throw "工作区不干净，先提交再打包：`n$($dirty -join "`n")"
    }
    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }

    $name = "Cloudflare-Hosts-Optimizer-$Version.zip"
    $zip = Join-Path $OutDir $name
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }

    $prefix = 'Cloudflare-Hosts-Optimizer/'
    git archive --format=zip --prefix=$prefix -o $zip HEAD
    if ($LASTEXITCODE -ne 0) { throw "git archive 失败（exit $LASTEXITCODE）" }

    # 顶层必须只有一个目录，否则解压出来又是散文件
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entries = @($archive.Entries | ForEach-Object FullName)
        $outside = @($entries | Where-Object { -not $_.StartsWith($prefix) })
        if ($outside.Count -gt 0) { throw "zip 顶层结构不正确：$($outside[0])" }
        if ($entries -notcontains "${prefix}Cloudflare-Hosts-Optimizer.ps1") {
            throw 'zip 中缺少 Cloudflare-Hosts-Optimizer.ps1。'
        }
    } finally {
        $archive.Dispose()
    }

    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    $sum = "$zip.sha256"
    "$hash  $name" | Out-File -LiteralPath $sum -Encoding ascii

    [pscustomobject]@{
        Zip          = $zip
        Sha256       = $hash
        ChecksumFile = $sum
    } | Format-List
} finally {
    Pop-Location
}
