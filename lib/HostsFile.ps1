#Requires -Version 7.0
<#
    hosts 文档的解析、增量更新、备份与原子写入。

    设计目标：
      * 标记结构不合法时直接拒绝，绝不"尽力修复"。
      * 不认识的编码直接拒绝，避免把 GBK/UTF-16 当成 UTF-8 改写。
      * 验证失败的域名保留上一次的映射（增量更新），只有 -Prune 才删除。
      * 备份按文件名排序，不依赖 LastWriteTime。
#>

if (-not $script:BeginMarker) { $script:BeginMarker = '# >>> Cloudflare-Hosts-Optimizer BEGIN (auto-generated; -Rollback to undo) >>>' }
if (-not $script:EndMarker) { $script:EndMarker = '# <<< Cloudflare-Hosts-Optimizer END <<<' }
if (-not $script:LegacyTag) { $script:LegacyTag = '# [Cloudflare-Hosts-Optimizer] ' }

function Read-HostsDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "hosts 文件不存在：$Path" }
    $bytes = [IO.File]::ReadAllBytes($Path)

    # UTF-16 / NUL 字节：不支持，直接拒绝
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) {
        throw 'hosts 看起来是 UTF-16 编码，本工具只支持 ASCII / UTF-8。请先另存为 UTF-8 或 ASCII。'
    }
    foreach ($b in $bytes) {
        if ($b -eq 0) { throw 'hosts 含 NUL 字节，疑似 UTF-16 或二进制文件；请先另存为 UTF-8/ASCII。' }
    }

    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $allAscii = $true
    foreach ($b in $bytes) { if ($b -gt 127) { $allAscii = $false; break } }

    $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
    if ($hasBom) {
        $encoding = 'UTF8'
        try { $text = $strictUtf8.GetString($bytes, 3, $bytes.Length - 3) }
        catch { throw 'hosts 的 UTF-8 BOM 后存在非法字节，拒绝改写。' }
    } elseif ($allAscii) {
        $encoding = 'ASCII'
        $text = [Text.ASCIIEncoding]::new().GetString($bytes)
    } else {
        $encoding = 'UTF8'
        try { $text = $strictUtf8.GetString($bytes) }
        catch { throw 'hosts 含非 ASCII 字节，但不是合法 UTF-8（可能是 GBK/ANSI）。为避免损坏，拒绝改写。请另存为 UTF-8 或 ASCII 后重试。' }
    }

    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash

    return [pscustomobject]@{
        Path       = $Path
        Bytes      = $bytes
        Text       = $text
        Encoding   = $encoding
        HasBom     = $hasBom
        NewLine    = $nl
        OriginalHash = $hash
    }
}

function Get-HostsBlockInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines)

    $begin = [System.Collections.Generic.List[int]]::new()
    $end = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $t = $Lines[$i].Trim()
        if ($t -ceq $script:BeginMarker) { $begin.Add($i) }
        elseif ($t -ceq $script:EndMarker) { $end.Add($i) }
    }

    if ($begin.Count -eq 0 -and $end.Count -eq 0) {
        return [pscustomobject]@{ HasBlock = $false; Begin = -1; End = -1 }
    }
    if ($begin.Count -ne 1 -or $end.Count -ne 1) {
        throw "hosts 托管标记异常：BEGIN=$($begin.Count) 个，END=$($end.Count) 个。拒绝改写，请先手动修复。"
    }
    if ($begin[0] -ge $end[0]) {
        throw 'hosts 托管标记顺序错误：BEGIN 必须在 END 之前。拒绝改写。'
    }
    return [pscustomobject]@{ HasBlock = $true; Begin = $begin[0]; End = $end[0] }
}

function Get-HostsBlockMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory)]$BlockInfo
    )

    $map = [ordered]@{}
    if (-not $BlockInfo.HasBlock) { return $map }

    for ($i = $BlockInfo.Begin + 1; $i -lt $BlockInfo.End; $i++) {
        $t = $Lines[$i].Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        if ($t -notmatch '^(?<ip>\d{1,3}(?:\.\d{1,3}){3})\s+(?<host>\S+)\s*$') {
            throw "托管区块第 $($i + 1) 行格式非法：$t"
        }
        $ip = $matches['ip']
        $hostName = $matches['host'].ToLowerInvariant()
        if (-not $map.Contains($hostName)) { $map[$hostName] = [System.Collections.Generic.List[string]]::new() }
        if (-not $map[$hostName].Contains($ip)) { $map[$hostName].Add($ip) }
    }
    return $map
}

# 返回：Tagged（已注释的原条目）、Original（未注释的映射）、Conflicts（必须中止的情况）
function Get-HostsOutsideInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory)]$BlockInfo,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$ManagedSet
    )

    $tagged = @{}
    $original = @{}
    $conflicts = [System.Collections.Generic.List[object]]::new()

    # 识别其他工具的托管区块（例如 # S302 BEGIN ... / # S302 END ...），
    # 这些区块里的条目不属于本工具，拒绝接管。
    $foreignRanges = [System.Collections.Generic.List[object]]::new()
    $openBlocks = @{}
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $t = $Lines[$i].Trim()
        if ($t -match '^#\s*(?<tok>[A-Za-z0-9_-]+)\s+BEGIN\b') {
            $tok = $matches['tok']
            if (-not $openBlocks.ContainsKey($tok)) { $openBlocks[$tok] = $i }
        } elseif ($t -match '^#\s*(?<tok>[A-Za-z0-9_-]+)\s+END\b') {
            $tok = $matches['tok']
            if ($openBlocks.ContainsKey($tok)) {
                $foreignRanges.Add([pscustomobject]@{ Begin = $openBlocks[$tok]; End = $i; Token = $tok })
                $openBlocks.Remove($tok)
            }
        }
    }

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($BlockInfo.HasBlock -and $i -ge $BlockInfo.Begin -and $i -le $BlockInfo.End) { continue }
        $t = $Lines[$i].Trim()
        if (-not $t -or ($t.StartsWith('#') -and -not $t.StartsWith($script:LegacyTag))) { continue }

        $isTagged = $t.StartsWith($script:LegacyTag)
        $work = if ($isTagged) { $t.Substring($script:LegacyTag.Length).Trim() } else { $t }
        if (-not $work -or $work.StartsWith('#')) { continue }

        $parts = @($work -split '\s+')
        if ($parts.Count -lt 2) { continue }

        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse($parts[0], [ref]$ip)) { continue }

        # 主机名列表：遇到行内注释就停止
        $hosts = @()
        for ($j = 1; $j -lt $parts.Count; $j++) {
            if ($parts[$j].StartsWith('#')) { break }
            $hosts += $parts[$j]
        }
        if ($hosts.Count -eq 0) { continue }

        $normalized = @()
        foreach ($h in $hosts) {
            $n = $h.TrimEnd('.').ToLowerInvariant()
            if ($n) { $normalized += $n }
        }
        if ($normalized.Count -eq 0) { continue }
        # 已注释的原条目：无论该域名本次是否仍受管，都要记录，
        # 否则 Prune 时无法把它还原成未注释状态。
        if ($isTagged) {
            if ($normalized.Count -gt 1) {
                $conflicts.Add([pscustomobject]@{
                        Line = $i + 1; Reason = 'tagged-multi-alias'
                        Hosts = ($normalized -join ', ')
                    })
            } else {
                $tagged[$i] = [pscustomobject]@{ Host = $normalized[0]; Ip = $parts[0] }
            }
            continue
        }

        $managedHits = @($normalized | Where-Object { $ManagedSet.Contains($_) })
        if ($managedHits.Count -eq 0) { continue }

        $foreign = $foreignRanges | Where-Object { $i -ge $_.Begin -and $i -le $_.End } | Select-Object -First 1
        if ($foreign) {
            $conflicts.Add([pscustomobject]@{
                    Line = $i + 1; Reason = "foreign-block:$($foreign.Token)"
                    Hosts = ($normalized -join ', ')
                })
            continue
        }

        if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            $conflicts.Add([pscustomobject]@{
                    Line = $i + 1; Reason = 'ipv6-mapping'
                    Hosts = ($normalized -join ', ')
                })
            continue
        }
        if ($normalized.Count -gt 1) {
            $conflicts.Add([pscustomobject]@{
                    Line = $i + 1; Reason = 'multi-alias'
                    Hosts = ($normalized -join ', ')
                })
            continue
        }
        $original[$i] = [pscustomobject]@{ Host = $normalized[0]; Ip = $parts[0] }
    }

    return [pscustomobject]@{ Tagged = $tagged; Original = $original; Conflicts = @($conflicts) }
}

function Update-HostsDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][hashtable]$VerifiedMap,
        [Parameter(Mandatory)][string[]]$ManagedDomains,
        [AllowEmptyCollection()][string[]]$DropPreviousDomains = @(),
        [switch]$Prune
    )

    $lines = @($Document.Text -split "`r?`n")
    $blockInfo = Get-HostsBlockInfo -Lines $lines
    $previous = Get-HostsBlockMap -Lines $lines -BlockInfo $blockInfo

    $managedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $ManagedDomains) { [void]$managedSet.Add($d) }

    $outside = Get-HostsOutsideInfo -Lines $lines -BlockInfo $blockInfo -ManagedSet $managedSet
    if ($outside.Conflicts.Count -gt 0) {
        $details = ($outside.Conflicts | ForEach-Object {
                "第 $($_.Line) 行 [$($_.Reason)]：$($_.Hosts)"
            }) -join '; '
        throw "hosts 中存在需要人工处理的映射，已中止且未修改：$details"
    }

    # 增量合并：成功 -> 更新；失败 -> 保留 previous；不在输入中 -> 默认保留
    $dropSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($x in $DropPreviousDomains) { [void]$dropSet.Add($x) }

    $final = [ordered]@{}
    foreach ($pair in $previous.GetEnumerator()) {
        if ($dropSet.Contains($pair.Key)) { continue }
        if (-not $Prune -or $managedSet.Contains($pair.Key)) {
            $final[$pair.Key] = @($pair.Value)
        }
    }
    foreach ($pair in $VerifiedMap.GetEnumerator()) {
        $ips = @($pair.Value | Where-Object { $_ })
        if ($ips.Count -gt 0) { $final[$pair.Key] = $ips }
    }

    # 被移除的托管域名如果还在区块外有条目（工具注释过的旧条目或用户手工行），
    # 删除区块行后它们仍会生效。这里只生成告警，不删除用户数据。
    $warnings = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $dropSet) {
        if ($final.Contains($d)) { continue }
        foreach ($e in $outside.Tagged.GetEnumerator()) {
            if ($e.Value.Host -ieq $d) {
                $warnings.Add([pscustomobject]@{ Domain = $d; Line = $e.Key + 1; Ip = $e.Value.Ip; Kind = 'restored' })
            }
        }
        foreach ($e in $outside.Original.GetEnumerator()) {
            if ($e.Value.Host -ieq $d) {
                $warnings.Add([pscustomobject]@{ Domain = $d; Line = $e.Key + 1; Ip = $e.Value.Ip; Kind = 'manual' })
            }
        }
    }

    # 没有任何新结果、也没有历史映射：保持文件原样（不因空白/换行规范化而写入）
    if ($final.Count -eq 0 -and -not $Prune -and $VerifiedMap.Count -eq 0 -and $previous.Count -eq 0) {
        return [pscustomobject]@{
            Text = $Document.Text; Changed = $false
            FinalMap = [ordered]@{}; Conflicts = @(); Warnings = @($warnings)
        }
    }

    # 输出顺序：先按 ManagedDomains，再保留历史里的额外域名
    $order = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $ManagedDomains) {
        if ($final.Contains($d) -and -not $order.Contains($d)) { $order.Add($d) }
    }
    foreach ($d in $final.Keys) {
        if (-not $order.Contains($d)) { $order.Add($d) }
    }

    $out = [System.Collections.Generic.List[string]]::new()
    $skip = [System.Collections.Generic.HashSet[int]]::new()
    if ($blockInfo.HasBlock) {
        for ($i = $blockInfo.Begin; $i -le $blockInfo.End; $i++) { [void]$skip.Add($i) }
        # 区块前的一个空行是我们加的，一并去掉，避免重复运行时空行增长
        if ($blockInfo.Begin -gt 0 -and $lines[$blockInfo.Begin - 1].Trim() -eq '') {
            [void]$skip.Add($blockInfo.Begin - 1)
        }
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($skip.Contains($i)) { continue }
        $t = $lines[$i].Trim()

        if ($outside.Tagged.ContainsKey($i)) {
            $hostName = $outside.Tagged[$i].Host
            $work = $t.Substring($script:LegacyTag.Length).Trim()
            if ($final.Contains($hostName)) { $out.Add($script:LegacyTag + $work) }
            else { $out.Add($work) }
            continue
        }

        if ($outside.Original.ContainsKey($i)) {
            $hostName = $outside.Original[$i].Host
            if ($final.Contains($hostName)) { $out.Add($script:LegacyTag + $t) }
            else { $out.Add($lines[$i]) }
            continue
        }

        $out.Add($lines[$i])
    }

    while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }

    if ($order.Count -gt 0) {
        $out.Add('')
        $out.Add($script:BeginMarker)
        foreach ($d in $order) {
            foreach ($ip in @($final[$d])) {
                $out.Add("$ip`t$d")
            }
        }
        $out.Add($script:EndMarker)
        $out.Add('')
    }

    $newText = ($out -join $Document.NewLine)
    if (-not $newText.EndsWith($Document.NewLine)) { $newText += $Document.NewLine }

    $resultMap = [ordered]@{}
    foreach ($d in $order) { $resultMap[$d] = @($final[$d]) }

    return [pscustomobject]@{
        Text      = $newText
        Changed   = ($newText -cne $Document.Text)
        FinalMap  = $resultMap
        Conflicts = @()
        Warnings  = @($warnings)
    }
}

function Get-HostsBackupDir {
    [CmdletBinding()]
    param(
        [string]$HostsPath,
        [string]$FallbackRoot
    )

    $systemHosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $isSystem = $true
    if ($HostsPath) {
        try { $isSystem = ([IO.Path]::GetFullPath($HostsPath) -ieq [IO.Path]::GetFullPath($systemHosts)) } catch { $isSystem = $true }
    }

    # 非系统 hosts 使用按目标路径哈希隔离的子目录，避免沙箱备份被系统 hosts 回滚选中
    $targetId = $null
    if ($HostsPath -and -not $isSystem) {
        $normalized = [IO.Path]::GetFullPath($HostsPath).ToLowerInvariant()
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($normalized))).ToLowerInvariant()
        $targetId = $hash.Substring(0, 16)
    }

    $base = $null
    $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ($programData) {
        $candidate = Join-Path $programData 'Cloudflare-Hosts-Optimizer\backup'
        try {
            if (-not (Test-Path -LiteralPath $candidate)) {
                New-Item -ItemType Directory -Force -Path $candidate | Out-Null
                try {
                    & icacls $candidate /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)R' 2>$null | Out-Null
                } catch { }
            }
            $base = $candidate
        } catch { }
    }
    if (-not $base) {
        $root = if ($FallbackRoot) { $FallbackRoot } elseif ($script:RepoRoot) { $script:RepoRoot } else { $PSScriptRoot }
        $base = Join-Path $root 'backup'
    }

    $dir = if ($targetId) { Join-Path $base "targets\$targetId" } else { $base }
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        if ($targetId) {
            try {
                & icacls $dir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)R' 2>$null | Out-Null
            } catch { }
        }
    }
    return $dir
}

function Backup-HostsDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$BackupDir,
        [string]$Version = '0.0.0',
        [int]$Keep = 10
    )

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $name = "hosts-$stamp-$id.bak"
    $path = Join-Path $BackupDir $name

    # 原样保存字节，不做任何编码转换
    [IO.File]::WriteAllBytes($path, $Document.Bytes)

    $manifest = [pscustomobject]@{
        createdAt = (Get-Date).ToString('o')
        version   = $Version
        hostsPath = $Document.Path
        preHash   = $Document.OriginalHash
        postHash  = $null
        domains   = @()
    }
    $manifestPath = "$path.json"
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8

    # 首次接管快照，不参与轮换
    $initial = Get-ChildItem -LiteralPath $BackupDir -Filter 'hosts-initial-*.bak' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $initial) {
        Copy-Item -LiteralPath $path -Destination (Join-Path $BackupDir "hosts-initial-$stamp.bak") -Force
    }

    # 只保留最近 N 份普通备份
    Get-ChildItem -LiteralPath $BackupDir -Filter 'hosts-2*.bak' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -Skip $Keep |
        Remove-Item -Force -ErrorAction SilentlyContinue

    return [pscustomobject]@{ Path = $path; ManifestPath = $manifestPath; Name = $name }
}

function Write-HostsDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)]$Update,
        [Parameter(Mandatory)][string]$BackupDir,
        [string]$Version = '0.0.0'
    )

    if (-not $Update.Changed) {
        return [pscustomobject]@{ Changed = $false; Backup = $null }
    }

    $mutex = [Threading.Mutex]::new($false, 'Global\Cloudflare-Hosts-Optimizer')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw '另一个 Cloudflare-Hosts-Optimizer 实例正在运行，已中止。' }

        # 提交前确认文件没有被其他程序改动
        $currentHash = (Get-FileHash -LiteralPath $Document.Path -Algorithm SHA256).Hash
        if ($currentHash -ne $Document.OriginalHash) {
            throw 'hosts 在本次运行期间被其他程序修改，已中止且未写入。请重试。'
        }

        $backup = Backup-HostsDocument -Document $Document -BackupDir $BackupDir -Version $Version

        $enc = if ($Document.Encoding -eq 'UTF8') { [Text.UTF8Encoding]::new($Document.HasBom) } else { [Text.ASCIIEncoding]::new() }
        $bytes = $enc.GetBytes($Update.Text)

        $dir = Split-Path -Parent $Document.Path
        $temp = Join-Path $dir ('.Cloudflare-Hosts-Optimizer.' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllBytes($temp, $bytes)
            # 读回校验
            $readBack = [IO.File]::ReadAllBytes($temp)
            if ([Convert]::ToBase64String($readBack) -ne [Convert]::ToBase64String($bytes)) {
                throw '临时文件读回校验失败。'
            }
            [IO.File]::Replace($temp, $Document.Path, [NullString]::Value)
        } catch {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
            throw
        } finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }

        $newHash = (Get-FileHash -LiteralPath $Document.Path -Algorithm SHA256).Hash
        $expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if ($newHash -ne $expectedHash) {
            # 内容不一致，自动还原
            Copy-Item -LiteralPath $backup.Path -Destination $Document.Path -Force
            throw '写入后校验失败，已自动从备份还原。'
        }

        $manifest = Get-Content -LiteralPath $backup.ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        $manifest.postHash = $newHash
        $manifest.domains = @($Update.FinalMap.Keys)
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backup.ManifestPath -Encoding utf8

        return [pscustomobject]@{ Changed = $true; Backup = $backup.Path; NewHash = $newHash }
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-HostsRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostsPath,
        [Parameter(Mandatory)][string]$BackupDir,
        [string]$LegacyBackupDir,
        # 指定要恢复的备份文件；不指定则用最近一次
        [string]$BackupPath,
        [switch]$Force
    )

    $systemHosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $isSystem = $true
    try { $isSystem = ([IO.Path]::GetFullPath($HostsPath) -ieq [IO.Path]::GetFullPath($systemHosts)) } catch { $isSystem = $true }

    $dirs = @($BackupDir)
    if ($isSystem -and $LegacyBackupDir -and (Test-Path -LiteralPath $LegacyBackupDir)) { $dirs += $LegacyBackupDir }

    $all = @(foreach ($d in $dirs) {
            if (-not (Test-Path -LiteralPath $d)) { continue }
            Get-ChildItem -LiteralPath $d -Filter 'hosts-*.bak' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike 'hosts-initial-*' }
        })

    # 按 manifest 的 hostsPath 过滤，确保沙箱备份不会被恢复到另一个目标
    $valid = @()
    foreach ($bak in $all) {
        $manifestPath = "$($bak.FullName).json"
        if (Test-Path -LiteralPath $manifestPath) {
            try {
                $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
                if ($m.hostsPath) {
                    $same = $false
                    try { $same = ([IO.Path]::GetFullPath($m.hostsPath) -ieq [IO.Path]::GetFullPath($HostsPath)) } catch { $same = $false }
                    if (-not $same) { continue }
                }
                $valid += $bak
            } catch { continue }
        } else {
            # 旧版无 manifest 的备份：只允许系统 hosts 从 legacy 目录使用
            $isLegacy = $LegacyBackupDir -and (Test-Path -LiteralPath $LegacyBackupDir) -and
                ([IO.Path]::GetFullPath($bak.DirectoryName) -ieq [IO.Path]::GetFullPath($LegacyBackupDir))
            if ($isLegacy -and -not $isSystem) { continue }
            $valid += $bak
        }
    }

    $baks = @($valid | Sort-Object Name -Descending)

    if ($BackupPath) {
        if (Test-Path -LiteralPath $BackupPath -PathType Container) {
            $names = if ($baks.Count -gt 0) { ($baks | ForEach-Object { "  $($_.FullName)" }) -join "`n" } else { '（该目标的备份目录里没有可用备份）' }
            throw "指定的路径是目录，需要用具体的 .bak 文件。可用备份：`n$names"
        }
        if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
            throw "指定的备份不存在：$BackupPath"
        }
        $latest = Get-Item -LiteralPath $BackupPath
        $manifestPath = "$($latest.FullName).json"
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            throw "该备份缺少 manifest，无法确认它属于哪个 hosts 目标，已拒绝：$($latest.FullName)"
        }
        $sm = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        $sameTarget = $false
        if ($sm.hostsPath) {
            try { $sameTarget = ([IO.Path]::GetFullPath($sm.hostsPath) -ieq [IO.Path]::GetFullPath($HostsPath)) } catch { $sameTarget = $false }
        }
        if (-not $sameTarget) {
            throw "该备份的目标是 '$($sm.hostsPath)'，不是当前 hosts '$HostsPath'，已拒绝。"
        }
    } else {
        if ($baks.Count -eq 0) { throw "没有找到匹配当前 hosts 目标的备份文件：$($dirs -join ', ')" }
        $latest = $baks[0]
        $manifestPath = "$($latest.FullName).json"
        if (Test-Path -LiteralPath $manifestPath) {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
            if ($manifest.postHash) {
                $currentHash = (Get-FileHash -LiteralPath $HostsPath -Algorithm SHA256).Hash
                if ($currentHash -ne $manifest.postHash -and -not $Force) {
                    throw 'hosts 在最后一次写入后被其他程序修改过。为避免覆盖这些改动，已拒绝回滚；确认要覆盖请加 -Force。'
                }
            }
        }
    }

    $dir = Split-Path -Parent $HostsPath
    $temp = Join-Path $dir ('.Cloudflare-Hosts-Optimizer-rollback.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temp, [IO.File]::ReadAllBytes($latest.FullName))
        [IO.File]::Replace($temp, $HostsPath, [NullString]::Value)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }

    return [pscustomobject]@{ Restored = $latest.FullName; RestoredAt = $latest.CreationTime }
}

function Clear-DnsCache {
    [CmdletBinding()]
    param()
    $output = & ipconfig /flushdns 2>&1
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ Ok = $false; Output = ($output -join ' ') }
    }
    return [pscustomobject]@{ Ok = $true; Output = '' }
}
