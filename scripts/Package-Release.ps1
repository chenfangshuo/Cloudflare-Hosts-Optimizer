#Requires -Version 7.0
<#
.SYNOPSIS
    生成发布 zip 和 SHA256。只包含 git 已跟踪的文件，不会带上 domains.txt、cfst/、
    backup/、plan.json 或 dist/。

.EXAMPLE
    pwsh -NoProfile -File .\scripts\Package-Release.ps1 -Version 0.3.5
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

    $name = "pt-cf-optimize-$Version.zip"
    $zip = Join-Path $OutDir $name
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }

    git archive --format=zip -o $zip HEAD
    if ($LASTEXITCODE -ne 0) { throw "git archive 失败（exit $LASTEXITCODE）" }

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
