#Requires -Version 7.0
<#
    -Doctor 只读自检用到的函数。

    边界：
      * 不写 hosts、不访问目标站点；联网检查只打 Cloudflare 的公共端点
        （由 lib/Endpoint.ps1 的 Test-ProbeEndpoint / Test-SpeedEndpoint 完成）。
      * 除 Read-ColoCache / Test-ProbeEndpoint / Test-SpeedEndpoint 外都是纯函数或本机查询，
        可以在 Pester 里离线测。
#>

function New-DoctorCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'FAIL', 'SKIP')][string]$Status,
        [AllowEmptyString()][string]$Detail = ''
    )
    [pscustomobject]@{ Group = $Group; Name = $Name; Status = $Status; Detail = $Detail }
}

function Get-DoctorExitCode {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Checks = @())
    if (@($Checks | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) { return 1 }
    return 0
}

# 每项两行：状态 + 名称，缩进显示详情。不按字符数对齐，中英文混排才不会错位。
function Format-DoctorReport {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Checks = @())
    $mark = @{ OK = '[ OK ]'; WARN = '[WARN]'; FAIL = '[FAIL]'; SKIP = '[SKIP]' }
    $lines = [System.Collections.Generic.List[string]]::new()
    # 按加入顺序分组，保持「环境 -> hosts -> 域名 -> ...」的逻辑顺序
    $groups = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $Checks) { if (-not $groups.Contains($c.Group)) { $groups.Add($c.Group) } }
    foreach ($name in $groups) {
        $lines.Add('')
        $lines.Add("== $name ==")
        foreach ($c in @($Checks | Where-Object { $_.Group -eq $name })) {
            $lines.Add(("{0} {1}" -f $mark[$c.Status], $c.Name))
            if ($c.Detail) { $lines.Add("       $($c.Detail)") }
        }
    }
    $ok = @($Checks | Where-Object Status -eq 'OK').Count
    $warn = @($Checks | Where-Object Status -eq 'WARN').Count
    $fail = @($Checks | Where-Object Status -eq 'FAIL').Count
    $skip = @($Checks | Where-Object Status -eq 'SKIP').Count
    $lines.Add('')
    $summary = "总结：$ok 项通过，$warn 项警告，$fail 项失败，$skip 项跳过。"
    if ($fail -gt 0) { $summary += ' 失败项会让正常运行中止，先按上面的提示处理。' }
    $lines.Add($summary)
    return @($lines)
}

function ConvertTo-Ipv4Int64 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Ip)
    $a = $null
    if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$a)) { return $null }
    if ($a.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }
    $b = $a.GetAddressBytes()
    return ([long]$b[0] -shl 24) -bor ([long]$b[1] -shl 16) -bor ([long]$b[2] -shl 8) -bor [long]$b[3]
}

function ConvertFrom-Ipv4Int64 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][long]$Value)
    return '{0}.{1}.{2}.{3}' -f (($Value -shr 24) -band 255), (($Value -shr 16) -band 255),
        (($Value -shr 8) -band 255), ($Value -band 255)
}

# 把网段展开成覆盖到的 /24 集合（用 /24 序号表示），用于比较两套列表的覆盖差异。
function Get-Cidr24Set {
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Ranges = @())
    $set = [System.Collections.Generic.HashSet[long]]::new()
    foreach ($r in $Ranges) {
        $p = $r -split '/'
        if ($p.Count -ne 2) { continue }
        $ip = ConvertTo-Ipv4Int64 -Ip $p[0]
        $len = 0
        if ($null -eq $ip -or -not [int]::TryParse($p[1], [ref]$len)) { continue }
        if ($len -lt 0 -or $len -gt 32) { continue }
        # 比 /24 更细的网段只算它所在的那个 /24
        $effective = [math]::Min($len, 24)
        $base = $ip -band 0xFFFFFF00L
        $count = [int][math]::Pow(2, 24 - $effective)
        for ($i = 0; $i -lt $count; $i++) { [void]$set.Add($base + [long]($i * 256)) }
    }
    # 前置逗号：HashSet 若直接输出会被枚举成一个个整数，调用方就拿不到 .Contains
    return , $set
}

# Builtin 有、Other 没有的 /24（缺多少），以及 Other 多出来的。
function Get-Cidr24Gap {
    [CmdletBinding()]
    param(
        [string[]]$Builtin,
        [string[]]$Other,
        [ValidateRange(0, 20)][int]$MaxExamples = 3
    )
    $a = Get-Cidr24Set -Ranges $Builtin
    $b = Get-Cidr24Set -Ranges $Other
    $missing = @($a | Where-Object { -not $b.Contains($_) } | Sort-Object)
    $extra = @($b | Where-Object { -not $a.Contains($_) } | Sort-Object)
    return [pscustomobject]@{
        MissingFromOther = $missing.Count
        MissingExamples  = @($missing | Select-Object -First $MaxExamples | ForEach-Object { (ConvertFrom-Ipv4Int64 -Value $_) + '/24' })
        ExtraInOther     = $extra.Count
        ExtraExamples    = @($extra | Select-Object -First $MaxExamples | ForEach-Object { (ConvertFrom-Ipv4Int64 -Value $_) + '/24' })
    }
}

# 返回 hosts 的结构状态；结构问题通过 Error 返回，由调用方标 FAIL。
function Get-HostsDoctorInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostsPath)
    $result = [pscustomobject]@{
        Exists       = $false
        Encoding     = ''
        HasBlock     = $false
        ManagedCount = 0
        Conflicts    = @()
        Error        = ''
    }
    if (-not (Test-Path -LiteralPath $HostsPath)) {
        $result.Error = "文件不存在：$HostsPath"
        return $result
    }
    $result.Exists = $true
    try {
        $doc = Read-HostsDocument -Path $HostsPath
        $result.Encoding = if ($doc.HasBom) { "$($doc.Encoding) (BOM)" } else { $doc.Encoding }
        $lines = @($doc.Text -split "`r?`n")
        $block = Get-HostsBlockInfo -Lines $lines
        $result.HasBlock = [bool]$block.HasBlock
        $map = Get-HostsBlockMap -Lines $lines -BlockInfo $block
        $result.ManagedCount = @($map.Keys).Count

        $managed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $map.Keys) { [void]$managed.Add($k) }
        $outside = Get-HostsOutsideInfo -Lines $lines -BlockInfo $block -ManagedSet $managed
        $result.Conflicts = @($outside.Conflicts)
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function Get-BackupDoctorInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupDir,
        # 只有管理员才测写入：这个目录的 ACL 是管理员可写、普通用户只读，
        # 非管理员测出"不可写"是正常状态，不该报警。
        [switch]$TestWritable
    )
    $result = [pscustomobject]@{ Dir = $BackupDir; Exists = $false; Writable = $null; Newest = ''; Count = 0 }
    if (-not (Test-Path -LiteralPath $BackupDir)) { return $result }
    $result.Exists = $true
    if ($TestWritable) {
        try {
            $probe = Join-Path $BackupDir ('.doctor-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($probe, 'probe')
            Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
            $result.Writable = $true
        } catch {
            $result.Writable = $false
        }
    }
    $baks = @(Get-ChildItem -LiteralPath $BackupDir -Filter 'hosts-*.bak' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending)
    $result.Count = $baks.Count
    if ($baks.Count -gt 0) {
        $result.Newest = '{0}（{1:yyyy-MM-dd HH:mm}）' -f $baks[0].Name, $baks[0].LastWriteTime
    }
    return $result
}

# 比较 CFST 的 ip.txt 与内置网段；版本用 -h 读取（-v 会联网查更新）。
function Get-CfstDoctorInfo {
    [CmdletBinding()]
    param(
        [string]$CfstPath,
        [string]$Root,
        [string[]]$BuiltinRanges
    )
    $result = [pscustomobject]@{
        Found = $false; Path = ''; Version = ''; IpFile = ''; CidrCount = 0
        MissingFromIpFile = 0; MissingExamples = @(); ExtraInIpFile = 0; ExtraExamples = @()
        Error = ''
    }
    try { $exe = Find-Cfst -Explicit $CfstPath -Root $Root }
    catch { $result.Error = $_.Exception.Message; return $result }
    if (-not $exe) { return $result }
    $result.Found = $true
    $result.Path = $exe
    $result.Version = Get-CfstVersion -Exe $exe

    $ipFile = Join-Path (Split-Path -Parent $exe) 'ip.txt'
    $result.IpFile = $ipFile
    if (Test-Path -LiteralPath $ipFile) {
        $ranges = @(Get-Content -LiteralPath $ipFile -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$' })
        $result.CidrCount = $ranges.Count
        if ($BuiltinRanges -and $ranges.Count -gt 0) {
            $gap = Get-Cidr24Gap -Builtin $BuiltinRanges -Other $ranges
            $result.MissingFromIpFile = $gap.MissingFromOther
            $result.MissingExamples = $gap.MissingExamples
            $result.ExtraInIpFile = $gap.ExtraInOther
            $result.ExtraExamples = $gap.ExtraExamples
        }
    }
    return $result
}

function Get-ScheduledTaskDoctorInfo {
    [CmdletBinding()]
    param([string]$NamePattern = 'Cloudflare-Hosts-Optimizer*')
    # 用对象包一层：直接返回空数组时，函数输出会被折叠成 $null，和「模块缺失」区分不开
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Available = $false; Tasks = @() }
    }
    $tasks = @(Get-ScheduledTask -TaskName $NamePattern -ErrorAction SilentlyContinue)
    $rows = foreach ($t in $tasks) {
        $info = $null
        try { $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop } catch { }
        $exec = ''
        $argText = ''
        try {
            $act = @($t.Actions | Select-Object -First 1)
            if ($act.Count -gt 0) { $exec = [string]$act[0].Execute; $argText = [string]$act[0].Arguments }
        } catch { }
        # 任务注册后移动过目录时，任务仍指向旧路径，会静默失效
        $m = [regex]::Match($argText, '-File\s+"?([^"\s]+)"?')
        $scriptPath = if ($m.Success) { $m.Groups[1].Value } else { '' }
        [pscustomobject]@{
            TaskName     = $t.TaskName
            State        = [string]$t.State
            NextRun      = if ($info -and $info.NextRunTime) { $info.NextRunTime.ToString('yyyy-MM-dd HH:mm') } else { '' }
            # 从未运行时 Task Scheduler 返回 1999-11-30 这个哨兵值，不要当成真实的上次运行
            LastRun      = if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -ge 2000) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { '' }
            LastResult   = if ($info) { $info.LastTaskResult } else { $null }
            Execute      = $exec
            ScriptPath   = $scriptPath
            ScriptExists = if ($scriptPath) { Test-Path -LiteralPath $scriptPath } else { $null }
        }
    }
    return [pscustomobject]@{ Available = $true; Tasks = @($rows) }
}
