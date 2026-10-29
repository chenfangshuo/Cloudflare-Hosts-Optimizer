#Requires -Version 7.0
<#
    域名导入的纯逻辑：PT-Depiler 备份、代理旁路、文本提取、输出/合并。

    只做本地解析，不发网络请求。绝不读取 cookies.json / userInfo.json。
#>

function Read-ZipTextEntry {
    param($Zip, [string]$Name)
    $entry = $Zip.GetEntry($Name)
    if (-not $entry) { return $null }
    $reader = [IO.StreamReader]::new($entry.Open())
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Get-DepilerDomains {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [switch]$WithAlternates,
        [switch]$WithOffline
    )

    if (-not (Test-Path -LiteralPath $ZipPath)) { throw "找不到备份文件：$ZipPath" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ZipPath).Path)
    try {
        # 只读取 metadata.json；cookies.json / userInfo.json 等一律不打开
        $metaEntries = @($zip.Entries | Where-Object { $_.FullName -ceq 'metadata.json' })
        if ($metaEntries.Count -eq 0) {
            throw '备份里没有 metadata.json。请确认这是 PT-Depiler 的完整备份。'
        }
        if ($metaEntries.Count -gt 1) {
            throw '备份中存在多个同名 metadata.json，拒绝处理。'
        }
        if ($metaEntries[0].Length -gt 8MB) {
            throw 'metadata.json 解压后超过 8MB，拒绝处理。'
        }

        $json = Read-ZipTextEntry -Zip $zip -Name 'metadata.json'
        if (-not $json) {
            throw '备份里没有 metadata.json。请确认这是 PT-Depiler 的完整备份。'
        }
        try { $meta = $json | ConvertFrom-Json }
        catch { throw 'metadata.json 不是明文 JSON。请在 PT-Depiler 里关闭备份加密后重新导出。' }

        $domains = [System.Collections.Generic.List[string]]::new()
        $offline = 0
        $siteCount = 0
        $offlineIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        $siteNodes = @()
        if ($meta.sites) {
            if ($meta.sites -is [System.Collections.IEnumerable] -and $meta.sites -isnot [string]) {
                $siteNodes = @($meta.sites)
            } else {
                foreach ($pair in $meta.sites.PSObject.Properties) {
                    $siteNodes += $pair.Value
                    if ($pair.Value.isOffline -eq $true) { [void]$offlineIds.Add($pair.Name) }
                }
            }
        }
        foreach ($s in $siteNodes) {
            if (-not $s) { continue }
            $siteCount++
            if ($s.isOffline -eq $true) {
                $offline++
                if (-not $WithOffline) { continue }
            }
            if ($s.url -is [string]) {
                $d = ConvertTo-NormalizedDomain -Value $s.url
                if ($d) { $domains.Add($d) }
            }
        }

        $alternates = 0
        if ($WithAlternates -and $meta.siteHostMap) {
            foreach ($prop in $meta.siteHostMap.PSObject.Properties) {
                if (-not $WithOffline -and $prop.Value -and $offlineIds.Contains([string]$prop.Value)) { continue }
                $d = ConvertTo-NormalizedDomain -Value $prop.Name
                if ($d) { $domains.Add($d); $alternates++ }
            }
        }

        return [pscustomobject]@{
            Domains = @($domains | Select-Object -Unique)
            Note    = "站点 $siteCount 个；离线跳过 $offline 个；备用主机名 $alternates 条"
        }
    } finally {
        $zip.Dispose()
    }
}

function Get-ProxyBypassDomains {
    [CmdletBinding()]
    param()
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $v = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    if (-not $v -or -not $v.ProxyOverride) {
        return [pscustomobject]@{ Domains = @(); Note = '系统代理旁路列表为空' }
    }
    $domains = [System.Collections.Generic.List[string]]::new()
    foreach ($raw in ([string]$v.ProxyOverride -split ';')) {
        $e = $raw.Trim()
        if (-not $e -or $e -eq '<local>' -or $e.Contains('*')) { continue }
        $ip = $null
        if ([System.Net.IPAddress]::TryParse($e, [ref]$ip)) { continue }
        $d = ConvertTo-NormalizedDomain -Value $e
        if ($d) { $domains.Add($d) }
    }
    return [pscustomobject]@{
        Domains = @($domains | Select-Object -Unique)
        Note    = '来自 ProxyOverride；可能包含非 PT 域名，请人工筛选'
    }
}

function Get-TextDomains {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $found = [System.Collections.Generic.List[string]]::new()
    $urlPattern = 'https?://[^\s''"<>]+'

    # 先提取完整 URL，再把 URL 从文本里挖掉，避免把路径里的 index.php 当成主机名
    foreach ($m in [regex]::Matches($Text, $urlPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $d = ConvertTo-NormalizedDomain -Value $m.Value.TrimEnd('.', ',', ';', ')', ']')
        if ($d) { $found.Add($d) }
    }
    $stripped = [regex]::Replace($Text, $urlPattern, ' ', [Text.RegularExpressions.RegexOptions]::IgnoreCase)

    foreach ($m in [regex]::Matches($stripped, '(?<![@\w.-])(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}(?![@\w.-])')) {
        $d = ConvertTo-NormalizedDomain -Value $m.Value
        if ($d) { $found.Add($d) }
    }
    return [pscustomobject]@{
        Domains = @($found | Select-Object -Unique)
        Note    = '从文本中提取'
    }
}

function Write-DomainsFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$SourceName,
        [AllowEmptyCollection()][string[]]$Domains = @(),
        [string]$Note = ''
    )
    $dir = Split-Path -Parent $FilePath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $lines = @(
        "# 来源: $SourceName",
        "# 生成时间: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))",
        "# 数量: $($Domains.Count)",
        "# 说明: $Note",
        '# 请人工检查后再合并到 domains.txt',
        ''
    ) + @($Domains)
    [IO.File]::WriteAllText($FilePath, (($lines -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($false))
}

function Merge-IntoDomainsFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$NewDomains,
        [string]$SourceName = 'import'
    )

    if (-not (Test-Path -LiteralPath $Target)) {
        Write-DomainsFile -FilePath $Target -SourceName $SourceName -Domains $NewDomains -Note '新建文件'
        return [pscustomobject]@{ Added = $NewDomains.Count; Target = $Target; Backup = $null }
    }

    $existing = Read-DomainsFile -Path $Target
    $merge = Merge-DomainLists -Existing $existing.Domains -New $NewDomains
    if ($merge.Added.Count -eq 0) {
        return [pscustomobject]@{ Added = 0; Target = $Target; Backup = $null }
    }

    $backup = "$Target.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $Target -Destination $backup -Force

    $text = [IO.File]::ReadAllText($Target, [Text.Encoding]::UTF8)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    if ($text.Length -gt 0 -and -not $text.EndsWith($nl)) { $text += $nl }
    $text += "$nl# imported from $SourceName at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')$nl"
    $text += (($merge.Added -join $nl) + $nl)

    $dir = Split-Path -Parent $Target
    $temp = Join-Path $dir ('.domains.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, $text, [Text.UTF8Encoding]::new($false))
        [IO.File]::Replace($temp, $Target, [NullString]::Value)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{ Added = $merge.Added.Count; Target = $Target; Backup = $backup }
}
