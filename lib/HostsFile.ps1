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

# ---------------------------------------------------------------------------
# 备份来源可信度
#
# 系统 hosts 的自动回滚只信本工具在 ProgramData 下创建/加固的备份目录：
#   * 备份目录 owner 必须是 SYSTEM/Administrators/TrustedInstaller，且普通用户没有
#     写/删除/改权限；
#   * 应用根只要求 owner 受信且父目录不能被普通用户删除/替换（ProgramData 默认允许
#     用户建自己的子目录，不能因此判死）；
#   * 从应用根到备份目录的每一级都不能是 ReparsePoint；
#   * 已存在但不可信的目录直接失败，不做“修复后信任”；
#   * 旧文件即使后来 ACL 变好，也不能证明内容历史，来源检查不过就跳过。
# 仓库 backup、任意其他路径对系统 hosts 一律不可信，只能显式人工恢复。
# ---------------------------------------------------------------------------

$script:TrustedSids = @(
    'S-1-5-18',        # NT AUTHORITY\SYSTEM
    'S-1-5-32-544',    # BUILTIN\Administrators
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'  # TrustedInstaller
)

function Get-AclSidString {
    [CmdletBinding()]
    param($Identity)
    if ($null -eq $Identity) { return '' }
    if ($Identity -is [Security.Principal.SecurityIdentifier]) { return $Identity.Value }
    $text = [string]$Identity
    if ($text -match '^S-\d-\d+(-\d+)+$') { return $text }
    try {
        return ([Security.Principal.NTAccount]$text).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch {
        return ''
    }
}

# 纯函数：只根据“所有者 SID + 访问规则”判断，不碰文件系统。
# mask 只用具体权限位；GENERIC_ALL/GENERIC_WRITE 高位单独判断。
# -Ancestor 用于父目录：只拦删除/删除子项/改权限/取得所有权，允许普通用户建自己的子目录。
function Test-AclTrusted {
    [CmdletBinding()]
    param(
        $Acl,
        [switch]$Ancestor
    )
    if (-not $Acl) { return $false }
    try {
        $owner = Get-AclSidString -Identity $Acl.Owner
        if (-not $owner -or $owner -notin $script:TrustedSids) { return $false }

        $mask = if ($Ancestor) {
            [Security.AccessControl.FileSystemRights]'Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
        } else {
            [Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteAttributes, WriteExtendedAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
        }
        foreach ($rule in @($Acl.Access)) {
            if ($null -ne $rule.AccessControlType -and $rule.AccessControlType -ne 'Allow') { continue }
            if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }

            $rights = [int]$rule.FileSystemRights
            $specific = ($rights -band [int]$mask) -ne 0
            $genericAll = ($rights -band 0x10000000) -ne 0
            $genericWrite = ($rights -band 0x40000000) -ne 0
            $dangerous = if ($Ancestor) { $genericAll } else { $genericAll -or $genericWrite }
            if (-not ($specific -or $dangerous)) { continue }

            $sid = Get-AclSidString -Identity $rule.IdentityReference
            if (-not $sid -or $sid -notin $script:TrustedSids) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Get-BackupRoot {
    [CmdletBinding()]
    param()
    $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if (-not $programData) { return '' }
    return (Join-Path $programData 'Cloudflare-Hosts-Optimizer')
}

# 目录可信：路径边界 + 逐级 ReparsePoint + 应用根/备份目录 ACL + ProgramData 父目录检查。
function Test-BackupPathTrusted {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$AppRoot
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $app = if ($AppRoot) { $AppRoot } else { Get-BackupRoot }
    if (-not $app) { return $false }
    try {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $appFull = [IO.Path]::GetFullPath($app).TrimEnd('\')
    } catch { return $false }
    if (-not ($full -ieq $appFull -or $full.StartsWith($appFull + '\', [StringComparison]::OrdinalIgnoreCase))) {
        return $false
    }

    # 从目标逐级向上走到应用根，拒绝任何 ReparsePoint
    $current = $full
    while ($current) {
        try { $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop } catch { return $false }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        if ($current -ieq $appFull) { break }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { return $false }
        $current = $parent
    }

    # 应用根：owner 受信 + 父目录删除/改权限检查（不要求普通用户不能建子目录）
    try {
        if (-not (Test-AclTrusted -Acl (Get-Acl -LiteralPath $appFull -ErrorAction Stop) -Ancestor)) { return $false }
    } catch { return $false }

    # 备份目录本身：owner 受信，且非受信 SID 没有任何写/删除/改权限
    if ($full -ine $appFull) {
        try {
            if (-not (Test-AclTrusted -Acl (Get-Acl -LiteralPath $full -ErrorAction Stop))) { return $false }
        } catch { return $false }
    }

    # %ProgramData% 本身不能被普通用户删除/替换其子项
    $appParent = Split-Path -Parent $appFull
    if ($appParent) {
        try {
            if (-not (Test-AclTrusted -Acl (Get-Acl -LiteralPath $appParent -ErrorAction Stop) -Ancestor)) { return $false }
        } catch { return $false }
    }
    return $true
}

# 单个候选文件：owner + 写类 ACE + ReparsePoint；不追父链（目录已单独检查）。
function Test-BackupFileTrusted {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        return (Test-AclTrusted -Acl (Get-Acl -LiteralPath $Path -ErrorAction Stop))
    } catch {
        return $false
    }
}

# 系统 hosts 的自动挑选只保留可信目录；沙箱不做限制。
function Select-TrustedBackupDirs {
    [CmdletBinding()]
    param(
        [string[]]$Dirs,
        [bool]$IsSystem = $true
    )
    $trusted = @()
    $untrusted = @()
    foreach ($d in @($Dirs)) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        if (-not $IsSystem -or (Test-BackupPathTrusted -Path $d)) {
            $trusted += $d
        } else {
            $untrusted += $d
        }
    }
    return [pscustomobject]@{ Trusted = @($trusted); Untrusted = @($untrusted) }
}

# 纯函数：计算备份位置。系统 hosts 只有 ProgramData，沙箱只有仓库 targets；没有 fallback。
function Get-HostsBackupPlan {
    [CmdletBinding()]
    param(
        [string]$HostsPath,
        [string]$FallbackRoot,
        [string[]]$BaseCandidates
    )
    $isSystem = $true
    if ($HostsPath) { $isSystem = Test-SystemHostsPath -Path $HostsPath }

    $targetId = $null
    if ($HostsPath -and -not $isSystem) {
        try {
            $normalized = [IO.Path]::GetFullPath($HostsPath).ToLowerInvariant()
            $targetId = (Get-Sha256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes($normalized))).Substring(0, 16).ToLowerInvariant()
        } catch { $targetId = $null }
    }

    $root = if ($FallbackRoot) { $FallbackRoot } elseif ($script:RepoRoot) { $script:RepoRoot } else { $PSScriptRoot }
    $appRoot = Get-BackupRoot
    $programDataBase = if ($appRoot) { Join-Path $appRoot 'backup' } else { '' }

    if ($BaseCandidates) {
        $bases = @($BaseCandidates)
    } elseif ($isSystem) {
        $bases = @($programDataBase) | Where-Object { $_ }
    } else {
        $bases = @((Join-Path $root 'backup'))
    }

    $dirs = @(foreach ($base in @($bases)) {
            if (-not $base) { continue }
            $dir = if ($targetId) { Join-Path $base "targets\$targetId" } else { $base }
            [pscustomobject]@{ Base = $base; Dir = $dir }
        })
    return [pscustomobject]@{
        IsSystem        = $isSystem
        TargetId        = $targetId
        AppRoot         = $appRoot
        ProgramDataBase = $programDataBase
        Bases           = @($bases)
        Dirs            = @($dirs)
    }
}

# 准备唯一一个备份目录：新目录创建并加固；已存在目录只复查，不可信直接失败。
function Initialize-HostsBackupDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    $entries = @($Plan.Dirs)
    if ($entries.Count -eq 0) { throw '无法准备备份目录：没有可用位置。' }
    $entry = $entries[0]
    $isProgramData = ($Plan.ProgramDataBase -and $entry.Base -ieq $Plan.ProgramDataBase)

    if ($Plan.IsSystem) {
        if (Test-Path -LiteralPath $Plan.AppRoot) {
            if (-not (Test-BackupPathTrusted -Path $Plan.AppRoot)) {
                throw "备份根目录不可信：$($Plan.AppRoot)。请删除或修复该目录（owner 必须是 Administrators/SYSTEM），或改用沙箱 -HostsPath。"
            }
        } else {
            New-Item -ItemType Directory -Force -Path $Plan.AppRoot -ErrorAction Stop | Out-Null
            & icacls $Plan.AppRoot /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)R' 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "无法加固备份根目录：$($Plan.AppRoot)" }
            if (-not (Test-BackupPathTrusted -Path $Plan.AppRoot)) {
                throw "备份根目录加固后仍不可信：$($Plan.AppRoot)"
            }
        }
    }

    if (-not (Test-Path -LiteralPath $entry.Dir)) {
        New-Item -ItemType Directory -Force -Path $entry.Dir -ErrorAction Stop | Out-Null
    }
    if ($isProgramData) {
        & icacls $entry.Dir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)R' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "无法加固备份目录：$($entry.Dir)" }
    }

    $probe = Join-Path $entry.Dir ('.cfo-write-test-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($probe, 'ok')
    } catch {
        throw "备份目录不可写：$($entry.Dir)（$($_.Exception.Message)）"
    } finally {
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    }

    if ($Plan.IsSystem -and -not (Test-BackupPathTrusted -Path $entry.Dir)) {
        throw "备份目录加固后仍不可信：$($entry.Dir)"
    }
    return $entry.Dir
}

function Get-HostsBackupDir {
    [CmdletBinding()]
    param(
        [string]$HostsPath,
        [string]$FallbackRoot,
        [string[]]$BaseCandidates
    )
    $plan = Get-HostsBackupPlan -HostsPath $HostsPath -FallbackRoot $FallbackRoot -BaseCandidates $BaseCandidates
    return (Initialize-HostsBackupDirectory -Plan $plan)
}

function Get-HostsBackupDirs {
    [CmdletBinding()]
    param(
        [string]$HostsPath,
        [string]$FallbackRoot,
        [string[]]$BaseCandidates
    )
    $plan = Get-HostsBackupPlan -HostsPath $HostsPath -FallbackRoot $FallbackRoot -BaseCandidates $BaseCandidates
    return @($plan.Dirs | Where-Object { Test-Path -LiteralPath $_.Dir } | ForEach-Object { $_.Dir })
}

# 读 JSON；文件不存在或解析失败返回 $null，由调用方决定是跳过还是报错。
function Read-JsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# 原子写 JSON：先写同目录临时文件，再 Replace/Move，避免就地截断留下半个文件
function Write-JsonFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object,
        [int]$Depth = 5
    )
    $dir = Split-Path -Parent $Path
    if (-not $dir) { $dir = '.' }
    $temp = Join-Path $dir ('.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $Object | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $temp -Encoding utf8
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temp, $Path, [NullString]::Value)
        } else {
            Move-Item -LiteralPath $temp -Destination $Path -Force
        }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Backup-HostsDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$BackupDir,
        [string]$Version = '0.0.0',
        [int]$Keep = 10,
        # 这次事务准备写入的内容哈希；Replace 成功后才会把 state 改成 committed
        [string]$IntendedHash
    )

    # 带毫秒：同一秒内发生两次提交时，文件名排序仍能反映先后
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $name = "hosts-$stamp-$id.bak"
    $path = Join-Path $BackupDir $name

    # 原样保存字节，不做任何编码转换
    [IO.File]::WriteAllBytes($path, $Document.Bytes)

    # 两阶段提交：这里只登记 pending。intendedHash 不是“已完成”的证明，
    # 回滚时只有在当前 hosts 正好等于它时才把它当作已替换。
    $manifest = [pscustomobject]@{
        createdAt    = (Get-Date).ToString('o')
        version      = $Version
        hostsPath    = $Document.Path
        preHash      = $Document.OriginalHash
        intendedHash = $IntendedHash
        postHash     = $null
        state        = 'pending'
        committedAt  = ''
    }
    $manifestPath = "$path.json"
    Write-JsonFileAtomic -Path $manifestPath -Object $manifest

    # 首次接管快照，不参与轮换
    $initial = Get-ChildItem -LiteralPath $BackupDir -Filter 'hosts-initial-*.bak' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $initial) {
        Copy-Item -LiteralPath $path -Destination (Join-Path $BackupDir "hosts-initial-$stamp.bak") -Force
    }

    # 只保留最近 N 份普通备份；清单跟着备份一起删，避免 .json 无限堆积
    Get-ChildItem -LiteralPath $BackupDir -Filter 'hosts-2*.bak' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -Skip $Keep |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$($_.FullName).json" -Force -ErrorAction SilentlyContinue
        }

    return [pscustomobject]@{ Path = $path; ManifestPath = $manifestPath; Name = $name }
}

# 写入和回滚共用同一把全局互斥锁；返回一个状态对象交给 Exit-GlobalMutex。
function Enter-GlobalMutex {
    [CmdletBinding()]
    param()
    $m = [Threading.Mutex]::new($false, 'Global\Cloudflare-Hosts-Optimizer')
    $acquired = $false
    try { $acquired = $m.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) {
        $m.Dispose()
        throw '另一个 Cloudflare-Hosts-Optimizer 实例正在运行，已中止。'
    }
    return [pscustomobject]@{ Mutex = $m; Acquired = $true }
}

function Exit-GlobalMutex {
    [CmdletBinding()]
    param($State)
    if (-not $State) { return }
    try { if ($State.Acquired) { $State.Mutex.ReleaseMutex() } } catch { }
    try { $State.Mutex.Dispose() } catch { }
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

    $mutexState = Enter-GlobalMutex
    try {
        # 提交前确认文件没有被其他程序改动
        $currentHash = (Get-FileHash -LiteralPath $Document.Path -Algorithm SHA256).Hash
        if ($currentHash -ne $Document.OriginalHash) {
            throw 'hosts 在本次运行期间被其他程序修改，已中止且未写入。请重试。'
        }

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

        # 两阶段提交：备份 + pending 记录先落盘，Replace 成功后才升级成 committed。
        # intendedHash 只描述“准备写入什么”，不能提前当成已完成。
        $expectedHash = Get-Sha256Hex -Bytes $bytes
        $backup = Backup-HostsDocument -Document $Document -BackupDir $BackupDir -Version $Version `
            -IntendedHash $expectedHash

        $dir = Split-Path -Parent $Document.Path
        $temp = Join-Path $dir ('.Cloudflare-Hosts-Optimizer.' + [guid]::NewGuid().ToString('N') + '.tmp')
        $replaced = $false
        try {
            [IO.File]::WriteAllBytes($temp, $bytes)
            # 读回校验
            $readBack = [IO.File]::ReadAllBytes($temp)
            if ([Convert]::ToBase64String($readBack) -ne [Convert]::ToBase64String($bytes)) {
                throw '临时文件读回校验失败。'
            }
            [IO.File]::Replace($temp, $Document.Path, [NullString]::Value)
            $replaced = $true
        } catch {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
            if (-not $replaced) {
                # 替换没有发生：把这次备份标成 aborted（尽力而为），不要让回滚把它当成候选
                try {
                    $m0 = Read-JsonFile -Path $backup.ManifestPath
                    $m0.state = 'aborted'
                    $m0.intendedHash = $null
                    Write-JsonFileAtomic -Path $backup.ManifestPath -Object $m0
                } catch { }
            }
            throw
        } finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }

        # 到这里 File.Replace 已经成功：hosts 就是新内容，后面任何失败都不能再报“未提交”。
        $warning = ''
        $newHash = $null
        $verified = $false
        try {
            $newHash = (Get-FileHash -LiteralPath $Document.Path -Algorithm SHA256).Hash
            $verified = ($newHash -eq $expectedHash)
        } catch {
            $warning = "hosts 已替换，但读回校验失败（$(Protect-ErrorMessage -Text $_.Exception.Message)）；无法确认最终内容。"
        }

        if ($newHash -and -not $verified) {
            # 内容不一致：自动还原，并把这次备份标成 aborted
            Copy-Item -LiteralPath $backup.Path -Destination $Document.Path -Force
            try {
                $m1 = Read-JsonFile -Path $backup.ManifestPath
                $m1.state = 'aborted'
                $m1.postHash = $null
                $m1.intendedHash = $null
                Write-JsonFileAtomic -Path $backup.ManifestPath -Object $m1
            } catch { }
            throw '写入后校验失败，已自动从备份还原。'
        }

        # 完成标记写失败不影响“已经提交”这个事实：manifest 仍是 pending，
        # 回滚会按“当前内容 == intendedHash”把它恢复成已完成。
        try {
            $manifest = Read-JsonFile -Path $backup.ManifestPath
            if (-not $manifest) { throw '备份清单无法读取。' }
            $manifest.state = 'committed'
            $manifest.postHash = if ($newHash) { $newHash } else { $null }
            $manifest.committedAt = (Get-Date).ToString('o')
            Write-JsonFileAtomic -Path $backup.ManifestPath -Object $manifest
        } catch {
            $note = "hosts 已写入，但提交标记未能落盘（$(Protect-ErrorMessage -Text $_.Exception.Message)）；回滚时会按当前内容识别这次提交。"
            $warning = if ($warning) { "$warning $note" } else { $note }
        }

        # 提交时间必须在事务锁内、替换之后取，才是“这次替换真正完成”的时间
        return [pscustomobject]@{
            Changed = $true; Backup = $backup.Path; NewHash = $newHash
            CommittedAt = (Get-Date); Verified = $verified; Warning = $warning
        }
    } finally {
        Exit-GlobalMutex -State $mutexState
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

function Invoke-HostsRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostsPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$BackupDir,
        # 指定要恢复的备份文件；不指定则用最近一次
        [string]$BackupPath,
        [switch]$Force,
        # 显式允许使用不可信目录/文件里的备份：只用于人工恢复，必须配合 -RollbackFrom
        [switch]$AllowUntrustedBackup
    )

    $mutexState = Enter-GlobalMutex
    try {
    # 这个开关只授权“用户点名的那一份”，不能变成“在所有不可信目录里自动挑最新”
    if ($AllowUntrustedBackup -and -not $BackupPath) {
        throw '-AllowUntrustedBackup 必须同时指定 -RollbackFrom <备份文件>，不能用于自动挑选备份。'
    }

    $isSystem = Test-SystemHostsPath -Path $HostsPath

    $rawDirs = @($BackupDir)

    # 系统 hosts 只从“管理员/SYSTEM 独占写权限”的目录里自动挑选备份。
    # 非系统 hosts（沙箱）没有提权面，不做这个限制。
    # 自动扫描永远只扫可信目录；-AllowUntrustedBackup 只放宽“用户点名的那一份文件”，
    # 不能让其他不可信清单进入候选、更不能用它们的 postHash 充当覆盖保护
    $dirFilter = Select-TrustedBackupDirs -Dirs $rawDirs -IsSystem $isSystem
    $dirs = @($dirFilter.Trusted)
    $untrustedDirs = @($dirFilter.Untrusted)

    $all = @(foreach ($d in $dirs) {
            Get-ChildItem -LiteralPath $d -Filter 'hosts-*.bak' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike 'hosts-initial-*' }
        })

    # 候选：manifest 必须同时有 hostsPath（匹配当前目标）和 preHash。
    # 来源检查必须在读取/排序/覆盖保护之前：guard 也可能来自一份没被选中的 manifest，
    # pending 恢复也会采纳未选中的清单。系统 hosts 对 .bak 和 .json 都做轻量文件检查。
    $candidates = @()
    foreach ($bak in $all) {
        $manifestPath = "$($bak.FullName).json"
        if ($isSystem) {
            if (-not (Test-BackupFileTrusted -Path $bak.FullName)) { continue }
            if (Test-Path -LiteralPath $manifestPath) {
                if (-not (Test-BackupFileTrusted -Path $manifestPath)) { continue }
            }
        }
        if (-not (Test-Path -LiteralPath $manifestPath)) { continue }
        try {
            $m = Read-JsonFile -Path $manifestPath
            if (-not $m.hostsPath -or -not $m.preHash) { continue }
            if (-not (Test-SamePath -Left $m.hostsPath -Right $HostsPath)) { continue }
            # 缺 createdAt 的旧 manifest：退回文件名里的时间，而不是 MinValue。
            $sortAt = ConvertTo-BackupTimestamp -Value $m.createdAt
            if (-not $sortAt) { $sortAt = ConvertTo-BackupTimestampFromName -Name $bak.Name }
            # 新格式显式带 state；旧格式没有 state，仍按“有 postHash 就是已完成”判定
            $state = ([string]$m.state).ToLowerInvariant()
            if (-not $state) { $state = if ($m.postHash) { 'committed' } else { 'pending' } }
            # 替换根本没发生的记录（aborted）不是候选，不能拿来恢复
            if ($state -eq 'aborted') { continue }
            $candidates += [pscustomobject]@{
                File = $bak; Manifest = $m; State = $state
                Committed = ($state -eq 'committed')
                SortAt = $sortAt; SortName = $bak.Name
            }
        } catch { continue }
    }

    # 同一秒内的多次提交，文件名里的 GUID 是随机的；优先按 manifest 的 createdAt 排序，
    # 没有 createdAt（旧格式/无 manifest）才退回文件名。
    $sortKeys = @(
        @{ Expression = { if ($_.SortAt) { $_.SortAt } else { [datetime]::MinValue } }; Descending = $true }
        @{ Expression = { $_.SortName }; Descending = $true }
    )
    # 当前 hosts 的哈希既用于挑选，也用于后面的“无变化”判断
    $currentHash = (Get-FileHash -LiteralPath $HostsPath -Algorithm SHA256).Hash

    # 两阶段提交的恢复：Replace 已经发生、但完成标记没写成的 pending 记录，
    # 只要当前内容正好是它声明的 intendedHash，就按“已完成”参与挑选。
    foreach ($c in $candidates) {
        if ($c.Committed) { continue }
        if (-not $c.Manifest) { continue }
        $intended = [string]$c.Manifest.intendedHash
        if ($intended -and $currentHash -eq $intended) {
            $c.Committed = $true
            $c | Add-Member -NotePropertyName RecoveredAt -NotePropertyValue (Get-Date) -Force
            $c.Manifest | Add-Member -NotePropertyName postHash -NotePropertyValue $intended -Force
        }
    }

    # 恢复必须落盘：只在内存里改，下一次自动回滚会把它当成 pending 不匹配，
    # 转而去选更早的已完成事务，重复点回滚就变成逐版本撤销。
    foreach ($c in @($candidates | Where-Object { $_.PSObject.Properties['RecoveredAt'] })) {
        try {
            $m = $c.Manifest
            # 旧清单可能没有这些字段，用 Add-Member -Force 补齐
            $m | Add-Member -NotePropertyName state -NotePropertyValue 'committed' -Force
            $m | Add-Member -NotePropertyName postHash -NotePropertyValue ([string]$m.intendedHash) -Force
            Write-JsonFileAtomic -Path "$($c.File.FullName).json" -Object $m
        } catch {
            throw "无法把恢复后的提交状态写回备份清单，已中止回滚（hosts 未修改）：$($_.Exception.Message)"
        }
    }

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
        # 显式恢复也要先确认点名文件的来源；-AllowUntrustedBackup 才放宽这一份
        if ($isSystem -and -not $AllowUntrustedBackup) {
            if (-not (Test-BackupFileTrusted -Path $file.FullName)) {
                throw "该备份可被普通用户改写，无法确认来源，已拒绝：$($file.FullName)。确认内容可信后可用 -AllowUntrustedBackup 显式恢复。"
            }
            if (-not (Test-BackupFileTrusted -Path $manifestPath)) {
                throw "该备份的 manifest 可被普通用户改写，无法确认来源，已拒绝：$manifestPath"
            }
        }
        $m = Read-JsonFile -Path $manifestPath
        if (-not $m) { throw "该备份的 manifest 无法读取，已拒绝：$manifestPath" }
        $sameTarget = $false
        if ($m.hostsPath) {
            $sameTarget = Test-SamePath -Left $m.hostsPath -Right $HostsPath
        }
        if (-not $sameTarget) {
            throw "该备份的目标是 '$($m.hostsPath)'，不是当前 hosts '$HostsPath'，已拒绝。"
        }
        if (-not $m.preHash) {
            throw "该备份的 manifest 缺少 preHash，无法确认内容完整，已拒绝：$($file.FullName)"
        }
        $selected = [pscustomobject]@{ File = $file; Manifest = $m; Committed = [bool]$m.postHash }
    } else {
        if ($byName.Count -eq 0) {
            $hint = if ($untrustedDirs.Count -gt 0) {
                "。以下备份目录可被普通用户改写，已按来源不可信跳过：$($untrustedDirs -join ', ')。确认内容可信后再用 -RollbackFrom <文件> -AllowUntrustedBackup。"
            } else { '' }
            throw "没有找到匹配当前 hosts 目标的备份文件：$($dirs -join ', ')$hint"
        }
        # 优先最新的已完成事务；没有已完成事务时才退回最新的未完成备份
        $selected = if ($committed.Count -gt 0) { $committed[0] } else { $byName[0] }
    }

    # 选中后再复查一次文件来源：扫描与使用之间文件仍可能被替换
    if ($isSystem -and -not $AllowUntrustedBackup) {
        if (-not (Test-BackupFileTrusted -Path $selected.File.FullName)) {
            throw "该备份可被普通用户改写，无法确认来源，已拒绝：$($selected.File.FullName)。确认内容可信后可用 -RollbackFrom <文件> -AllowUntrustedBackup 显式恢复。"
        }
        $selectedManifest = "$($selected.File.FullName).json"
        if ((Test-Path -LiteralPath $selectedManifest) -and -not (Test-BackupFileTrusted -Path $selectedManifest)) {
            throw "该备份的 manifest 可被普通用户改写，无法确认来源，已拒绝：$selectedManifest"
        }
    }

    # 备份内容必须与 preHash 一致：损坏/被替换的备份永远不能用来覆盖 hosts（-Force 也不行）
    $backupBytes = [IO.File]::ReadAllBytes($selected.File.FullName)
    $backupHash = Get-Sha256Hex -Bytes $backupBytes
    if ($selected.Manifest -and $backupHash -ne [string]$selected.Manifest.preHash) {
        throw "备份内容与 manifest 不一致（可能已损坏或被替换），已拒绝：$($selected.File.FullName)"
    }

    # 当前内容已经等于备份内容：无变化成功，不重复替换
    if ($currentHash -eq $backupHash) {
        return [pscustomobject]@{
            Restored = $selected.File.FullName; RestoredAt = $selected.File.CreationTime
            Unchanged = $true; CommittedAt = $null
        }
    }

    # 覆盖保护：用“最新已完成事务的 postHash”比对当前文件，而不是所选备份自己的
    # postHash。-Force 只绕过这一步；目标归属和备份完整性已经在上面检查过。
    # 覆盖保护参考“最新已完成事务”的内容哈希。读回失败的事务 postHash 为空，
    # 但它的 intendedHash 就是这次实际装进去的内容，可以作为 guard；否则正常回滚会被迫加 -Force。
    $guard = $null
    if ($committed.Count -gt 0) {
        $guard = [string]$committed[0].Manifest.postHash
        if (-not $guard) { $guard = [string]$committed[0].Manifest.intendedHash }
    } elseif ($selected.Manifest) {
        $guard = [string]$selected.Manifest.postHash
        if (-not $guard) { $guard = [string]$selected.Manifest.intendedHash }
    }

    $allowed = [bool]$Force
    if (-not $allowed -and $guard -and $currentHash -eq $guard) { $allowed = $true }
    # 回滚过一次之后再回滚同一份备份会命中上面的“无变化”分支，不需要额外判断 preHash
    if (-not $allowed) {
        if (-not $guard) {
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
    } finally {
        Exit-GlobalMutex -State $mutexState
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
