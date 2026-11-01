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

# 兼容 PowerShell 7.0（.NET Core 3.1）：不要用 SHA256.HashData / Convert.ToHexString。
# 返回值与 Get-FileHash 一致，都是大写十六进制。
function Get-Sha256Hex {
    [CmdletBinding()]
    param([AllowEmptyCollection()][byte[]]$Bytes = @())
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToUpperInvariant()
    } finally {
        $sha.Dispose()
    }
}

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
    # 哈希必须来自刚读到的字节快照，不能重新读文件——两次读取之间文件可能被改
    $hash = Get-Sha256Hex -Bytes $bytes

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
        $hash = (Get-Sha256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes($normalized))).ToLowerInvariant()
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

    # 带毫秒：同一秒内发生两次提交时，文件名排序仍能反映先后
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
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
        return [pscustomobject]@{ Changed = $false; Backup = $null; CommittedAt = $null }
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
        $payload = $enc.GetBytes($Update.Text)
        if ($Document.Encoding -eq 'UTF8' -and $Document.HasBom) {
            # GetBytes 不会自动带 BOM，必须显式拼上前导字节
            $preamble = $enc.GetPreamble()
            $bytes = [byte[]]::new($preamble.Length + $payload.Length)
            [Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
            [Array]::Copy($payload, 0, $bytes, $preamble.Length, $payload.Length)
        } else {
            $bytes = $payload
        }

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
        $expectedHash = Get-Sha256Hex -Bytes $bytes
        if ($newHash -ne $expectedHash) {
            # 内容不一致，自动还原
            Copy-Item -LiteralPath $backup.Path -Destination $Document.Path -Force
            throw '写入后校验失败，已自动从备份还原。'
        }

        $manifest = Get-Content -LiteralPath $backup.ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        $manifest.postHash = $newHash
        $manifest.domains = @($Update.FinalMap.Keys)
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backup.ManifestPath -Encoding utf8

        # 提交时间必须在事务锁内、读写校验之后取，才是“这次替换真正完成”的时间
        return [pscustomobject]@{
            Changed = $true; Backup = $backup.Path; NewHash = $newHash; CommittedAt = (Get-Date)
        }
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# manifest 的 createdAt 是 ISO 8601（含偏移）。解析失败返回 $null，退回按文件名排序。
# 注意：PowerShell 7.5+ 的 ConvertFrom-Json 会把它直接转成 DateTime；转回字符串会丢毫秒，
# 所以 DateTime 要原样使用。
function ConvertTo-BackupTimestamp {
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }
    $text = [string]$Value
    if (-not $text) { return $null }
    try {
        return [datetime]::Parse($text, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
    } catch { return $null }
}

# 从备份文件名解析时间（hosts-yyyyMMdd-HHmmss[fff]-...）；解析失败返回 $null。
function ConvertTo-BackupTimestampFromName {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Name = '')
    if (-not $Name) { return $null }
    $m = [regex]::Match($Name, '^hosts-(\d{8})-(\d{6,9})-')
    if (-not $m.Success) { return $null }
    $stamp = $m.Groups[1].Value + '-' + $m.Groups[2].Value
    $format = if ($m.Groups[2].Value.Length -eq 9) { 'yyyyMMdd-HHmmssfff' } else { 'yyyyMMdd-HHmmss' }
    try {
        return [datetime]::ParseExact($stamp, $format,
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
    } catch { return $null }
}

function Invoke-HostsRollbackLocked {
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

    # 候选：manifest 必须同时有 hostsPath（匹配当前目标）和 preHash；
    # 无 manifest 的旧备份只允许“legacy 目录 + 系统 hosts”。
    $candidates = @()
    foreach ($bak in $all) {
        $manifestPath = "$($bak.FullName).json"
        if (Test-Path -LiteralPath $manifestPath) {
            try {
                $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
                if (-not $m.hostsPath -or -not $m.preHash) { continue }
                $same = $false
                try { $same = ([IO.Path]::GetFullPath($m.hostsPath) -ieq [IO.Path]::GetFullPath($HostsPath)) } catch { $same = $false }
                if (-not $same) { continue }
                # 缺 createdAt 的旧 manifest：退回文件名里的时间，而不是 MinValue，
                # 否则它会排到所有带时间的备份后面（R6）。
                $sortAt = ConvertTo-BackupTimestamp -Value $m.createdAt
                if (-not $sortAt) { $sortAt = ConvertTo-BackupTimestampFromName -Name $bak.Name }
                $candidates += [pscustomobject]@{
                    File = $bak; Manifest = $m; Committed = [bool]$m.postHash; Legacy = $false
                    SortAt = $sortAt; SortName = $bak.Name
                }
            } catch { continue }
        } else {
            $isLegacy = $LegacyBackupDir -and (Test-Path -LiteralPath $LegacyBackupDir) -and
                ([IO.Path]::GetFullPath($bak.DirectoryName) -ieq [IO.Path]::GetFullPath($LegacyBackupDir))
            if (-not ($isLegacy -and $isSystem)) { continue }
            $candidates += [pscustomobject]@{
                File = $bak; Manifest = $null; Committed = $false; Legacy = $true
                SortAt = (ConvertTo-BackupTimestampFromName -Name $bak.Name); SortName = $bak.Name
            }
        }
    }

    # 同一秒内的多次提交，文件名里的 GUID 是随机的；优先按 manifest 的 createdAt 排序，
    # 没有 createdAt（旧格式/无 manifest）才退回文件名。
    $sortKeys = @(
        @{ Expression = { if ($_.SortAt) { $_.SortAt } else { [datetime]::MinValue } }; Descending = $true }
        @{ Expression = { $_.SortName }; Descending = $true }
    )
    $byName = @($candidates | Sort-Object -Property $sortKeys)
    $committed = @($candidates | Where-Object { $_.Committed } | Sort-Object -Property $sortKeys)

    if ($BackupPath) {
        if (Test-Path -LiteralPath $BackupPath -PathType Container) {
            $names = if ($byName.Count -gt 0) { ($byName | ForEach-Object { "  $($_.File.FullName)" }) -join "`n" } else { '（该目标的备份目录里没有可用备份）' }
            throw "指定的路径是目录，需要用具体的 .bak 文件。可用备份：`n$names"
        }
        if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
            throw "指定的备份不存在：$BackupPath"
        }
        $file = Get-Item -LiteralPath $BackupPath
        $manifestPath = "$($file.FullName).json"
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            throw "该备份缺少 manifest，无法确认它属于哪个 hosts 目标，已拒绝：$($file.FullName)"
        }
        $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        $sameTarget = $false
        if ($m.hostsPath) {
            try { $sameTarget = ([IO.Path]::GetFullPath($m.hostsPath) -ieq [IO.Path]::GetFullPath($HostsPath)) } catch { $sameTarget = $false }
        }
        if (-not $sameTarget) {
            throw "该备份的目标是 '$($m.hostsPath)'，不是当前 hosts '$HostsPath'，已拒绝。"
        }
        if (-not $m.preHash) {
            throw "该备份的 manifest 缺少 preHash，无法确认内容完整，已拒绝：$($file.FullName)"
        }
        $selected = [pscustomobject]@{ File = $file; Manifest = $m; Committed = [bool]$m.postHash; Legacy = $false }
    } else {
        if ($byName.Count -eq 0) { throw "没有找到匹配当前 hosts 目标的备份文件：$($dirs -join ', ')" }
        # 优先最新的已完成事务；没有已完成事务时才退回最新的未完成备份
        $selected = if ($committed.Count -gt 0) { $committed[0] } else { $byName[0] }
    }

    # 备份内容必须与 preHash 一致：损坏/被替换的备份永远不能用来覆盖 hosts（-Force 也不行）
    $backupBytes = [IO.File]::ReadAllBytes($selected.File.FullName)
    $backupHash = Get-Sha256Hex -Bytes $backupBytes
    if ($selected.Manifest -and $backupHash -ne [string]$selected.Manifest.preHash) {
        throw "备份内容与 manifest 不一致（可能已损坏或被替换），已拒绝：$($selected.File.FullName)"
    }

    $currentHash = (Get-FileHash -LiteralPath $HostsPath -Algorithm SHA256).Hash

    # 当前内容已经等于备份内容：无变化成功，不重复替换
    if ($currentHash -eq $backupHash) {
        return [pscustomobject]@{
            Restored = $selected.File.FullName; RestoredAt = $selected.File.CreationTime
            Unchanged = $true; CommittedAt = $null
        }
    }

    # 覆盖保护：用“最新已完成事务的 postHash”比对当前文件，而不是所选备份自己的
    # postHash。-Force 只绕过这一步；目标归属和备份完整性已经在上面检查过。
    $guard = $null
    if ($committed.Count -gt 0) { $guard = [string]$committed[0].Manifest.postHash }
    elseif ($selected.Manifest -and $selected.Manifest.postHash) { $guard = [string]$selected.Manifest.postHash }

    $allowed = [bool]$Force
    if (-not $allowed -and $guard -and $currentHash -eq $guard) { $allowed = $true }
    # 回滚过一次之后再回滚同一份备份会命中上面的“无变化”分支，不需要额外判断 preHash
    if (-not $allowed) {
        if ($selected.Legacy -or -not $guard) {
            throw '无法确认当前 hosts 是否被改过（没有可参考的已完成事务）。确认要覆盖请加 -Force。'
        }
        throw 'hosts 在最后一次成功写入后被其他程序修改过。为避免覆盖这些改动，已拒绝回滚；确认要覆盖请加 -Force。'
    }

    $dir = Split-Path -Parent $HostsPath
    $temp = Join-Path $dir ('.Cloudflare-Hosts-Optimizer-rollback.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temp, $backupBytes)
        if ((Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($temp))) -ne $backupHash) {
            throw '回滚临时文件校验失败，已中止。'
        }
        [IO.File]::Replace($temp, $HostsPath, [NullString]::Value)
        $afterHash = (Get-FileHash -LiteralPath $HostsPath -Algorithm SHA256).Hash
        if ($afterHash -ne $backupHash) {
            throw '恢复后校验失败，请检查 hosts。'
        }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }

    return [pscustomobject]@{
        Restored = $selected.File.FullName; RestoredAt = $selected.File.CreationTime
        Unchanged = $false; CommittedAt = (Get-Date)
    }
}

# 回滚与写入共用同一个全局互斥锁，避免“检查后又被另一个实例提交”的窗口
function Invoke-HostsRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostsPath,
        [Parameter(Mandatory)][string]$BackupDir,
        [string]$LegacyBackupDir,
        [string]$BackupPath,
        [switch]$Force
    )
    $mutex = [Threading.Mutex]::new($false, 'Global\Cloudflare-Hosts-Optimizer')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw '另一个 Cloudflare-Hosts-Optimizer 实例正在运行，已中止。' }
        return Invoke-HostsRollbackLocked @PSBoundParameters
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
    }
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
