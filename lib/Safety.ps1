#Requires -Version 7.0
<#
    输入/输出安全：路径碰撞检测与敏感文本脱敏。

    路径碰撞：报告、计划、缓存、摘要这些“旁路输出”如果和 hosts、域名文件或回滚源指向
    同一个文件，就会绕开 hosts 事务保护直接覆盖它们。这里用 Win32 文件身份
    （卷序列号 + FileIndex）比较，能识别大小写、相对路径、硬链接和符号链接；
    只使用 Win32 P/Invoke，不依赖 .NET 5/6 才有的 ResolveLinkTarget。

    文本脱敏：非法输入的错误消息不能把用户贴进来的完整 URL（可能带 passkey）写进
    控制台或报告。预览只保留 scheme://host 或纯主机名，其余一律 <已隐藏>。
#>

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------

# 相对路径要按 PowerShell 的当前位置解析。[IO.Path]::GetFullPath 用的是进程工作目录，
# 在 Set-Location 之后可能和 $PWD 不一致。
function Resolve-InputPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    $base = ''
    try { $base = (Get-Location).ProviderPath } catch { $base = [Environment]::CurrentDirectory }
    if ($base) { return (Join-Path $base $Path) }
    return $Path
}

function Get-NormalizedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath((Resolve-InputPath -Path $Path))
    # 只去掉末尾分隔符；C:\ 这种根路径必须保留，否则会变成驱动器相对路径 C:
    if ($full.Length -gt 3 -and ($full.EndsWith('\') -or $full.EndsWith('/'))) {
        $full = $full.TrimEnd('\', '/')
    }
    return $full.ToLowerInvariant()
}

function Get-SystemHostsPath {
    [CmdletBinding()]
    param()
    return (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')
}

# 只做规范化词法比较（大小写、相对路径、末尾分隔符）；用于 manifest 目标等非安全判定。
# 安全判定（输出碰撞、系统 hosts 识别）必须用 Test-PathCollision。
function Test-SamePath {
    [CmdletBinding()]
    param([string]$Left, [string]$Right)
    if (-not $Left -or -not $Right) { return $false }
    try { return ((Get-NormalizedPath -Path $Left) -ceq (Get-NormalizedPath -Path $Right)) } catch { return $false }
}

# 系统 hosts 判定：路径存在时先比文件身份，识别指向系统 hosts 的符号链接/硬链接；
# 查不到身份时保守按系统 hosts 处理。
function Test-SystemHostsPath {
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) { return $false }
    $system = Get-SystemHostsPath
    $r = Test-PathCollision -Left $Path -Right $system
    if ($r.Collision -or $r.Uncertain) { return $true }
    return (Test-SamePath -Left $Path -Right $system)
}

# 返回 "卷序列号:FileIndexHighFileIndexLow"，失败返回 $null。
# 打开失败的常见原因：路径不存在、被独占、ACL 拒绝。
function Get-Win32FileIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not ('CfoFileIdentity' -as [type])) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class CfoFileIdentity
{
    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFileW(
        string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes,
        uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle hFile, out BY_HANDLE_FILE_INFORMATION lpFileInformation);

    public static string Get(string path)
    {
        // 0 表示只查询元数据；7 = 允许其他进程读写删；3 = OPEN_EXISTING；
        // 0x02000000 = FILE_FLAG_BACKUP_SEMANTICS，目录也能打开。
        using (SafeFileHandle h = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero))
        {
            if (h.IsInvalid) { return null; }
            BY_HANDLE_FILE_INFORMATION info;
            if (!GetFileInformationByHandle(h, out info)) { return null; }
            return info.VolumeSerialNumber.ToString("X8") + ":" +
                   info.FileIndexHigh.ToString("X8") + info.FileIndexLow.ToString("X8");
        }
    }
}
'@ -ErrorAction Stop
        } catch {
            return $null
        }
    }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        # 统一成扩展长度路径，避免 260 字符限制；UNC 必须用 \\?\UNC\ 前缀
        if ($full.StartsWith('\\?\')) {
            $target = $full
        } elseif ($full.StartsWith('\\')) {
            $target = '\\?\UNC\' + $full.Substring(2)
        } else {
            $target = '\\?\' + $full
        }
        return [CfoFileIdentity]::Get($target)
    } catch {
        return $null
    }
}

# 结果里 Collision 表示“确认是同一文件”；Uncertain 表示两边都存在但查不到身份，
# 调用方应当拒绝（不能把查不到当成“不同”）。
function Test-PathCollision {
    [CmdletBinding()]
    param(
        [string]$Left,
        [string]$Right
    )
    $result = [pscustomobject]@{ Collision = $false; Uncertain = $false }
    if (-not $Left -or -not $Right) { return $result }

    try {
        $leftFull = Resolve-InputPath -Path $Left
        $rightFull = Resolve-InputPath -Path $Right
        if ((Get-NormalizedPath -Path $leftFull) -ceq (Get-NormalizedPath -Path $rightFull)) {
            $result.Collision = $true
            return $result
        }
    } catch {
        # 路径本身非法（比如含控制字符），交给上层的参数校验处理
        return $result
    }

    $leftExists = [IO.File]::Exists($leftFull) -or [IO.Directory]::Exists($leftFull)
    $rightExists = [IO.File]::Exists($rightFull) -or [IO.Directory]::Exists($rightFull)
    if (-not ($leftExists -and $rightExists)) { return $result }

    $leftId = Get-Win32FileIdentity -Path $leftFull
    $rightId = Get-Win32FileIdentity -Path $rightFull
    if ($leftId -and $rightId) {
        $result.Collision = ($leftId -ceq $rightId)
        return $result
    }
    $result.Uncertain = $true
    return $result
}

# 受保护输入的完整集合：**系统 hosts 永远在内**，再加上本次实际使用的目标。
# 自定义 -HostsPath 不能让系统 hosts 从保护集合里消失——报告误指系统 hosts 同样会覆盖它。
function Get-ProtectedInputPaths {
    [CmdletBinding()]
    param(
        [string]$HostsPath,
        [string]$DomainsFile,
        [string]$RollbackFrom
    )
    $list = @((Get-SystemHostsPath))
    if ($HostsPath) { $list += $HostsPath }
    if ($DomainsFile) { $list += $DomainsFile }
    if ($RollbackFrom) { $list += $RollbackFrom }
    return @($list)
}

# 返回 $null 表示安全；否则返回一句可以直接展示的错误。
function Assert-OutputPathSafe {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [string[]]$InputPaths = @(),
        [string[]]$OtherOutputs = @()
    )
    if (-not $Path) { return $null }

    foreach ($input in @($InputPaths)) {
        if (-not $input) { continue }
        $r = Test-PathCollision -Left $Path -Right $input
        if ($r.Collision) {
            return "输出路径与输入文件是同一个文件，已拒绝：$Path"
        }
        if ($r.Uncertain) {
            return "无法确认输出路径「$Path」与输入「$input」是否为同一文件，已拒绝。请换一个输出路径。"
        }
    }

    foreach ($other in @($OtherOutputs)) {
        if (-not $other) { continue }
        # 输出之间也必须比文件身份，不能只比字符串：两个不同的写法/硬链接同样是同一个文件
        $r = Test-PathCollision -Left $Path -Right $other
        if ($r.Collision) {
            return "多个输出指向同一个文件，已拒绝：$Path"
        }
        if ($r.Uncertain) {
            return "无法确认两个输出「$Path」和「$other」是否为同一文件，已拒绝。"
        }
    }
    return $null
}

# 一组输出之间、输出与输入之间都不能指向同一个文件。
# 按槽位排除自己，不能按“值相等”过滤（两个输出相同时会被全部滤掉）。
function Get-OutputPathConflicts {
    [CmdletBinding()]
    param(
        [string[]]$Outputs = @(),
        [string[]]$InputPaths = @()
    )
    $list = @($Outputs)
    $conflicts = @()
    for ($i = 0; $i -lt $list.Count; $i++) {
        if (-not $list[$i]) { continue }
        $others = @()
        for ($j = 0; $j -lt $list.Count; $j++) {
            if ($j -ne $i -and $list[$j]) { $others += $list[$j] }
        }
        $c = Assert-OutputPathSafe -Path $list[$i] -InputPaths $InputPaths -OtherOutputs $others
        if ($c) { $conflicts += $c }
    }
    return @($conflicts)
}

# ---------------------------------------------------------------------------
# 文本
# ---------------------------------------------------------------------------

# 只用于“用户输入的单个条目”：合法域名原样显示，URL 只保留 scheme://host，
# 其它（含 userinfo、查询串、路径、控制字符）一律隐藏——绝不回退成截取原文。
function Get-SafeInputPreview {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    if ($Value -match '[\x00-\x1F\x7F]') { return '<已隐藏>' }

    $text = $Value.Trim()
    $uri = $null
    if ([Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri)) {
        if ($uri.Scheme -in @('http', 'https')) {
            if (-not $uri.Host) { return '<已隐藏>' }
            return ('{0}://{1}' -f $uri.Scheme, $uri.Host)
        }
        # 其它 scheme（ftp://、file:// 等）不属于本工具的合法输入
        return '<已隐藏>'
    }

    # 纯主机名形态（ASCII 标签）。不是这个形状就隐藏，避免把凭据截一段出来。
    if ($text -match '^(?=.{1,253}\.?$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$') {
        return $text
    }
    return '<已隐藏>'
}

# 异常消息可能包含 URL 凭据；去掉 userinfo、凭据类查询参数和控制字符，
# 但保留 IO 错误本身的原因文本。
function Protect-ErrorMessage {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = [regex]::Replace($Text, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    # scheme://user:pass@host → scheme://<redacted>@host
    $t = [regex]::Replace($t, '(?i)\b([a-z][a-z0-9+.-]*://)[^\s/?#@]+@', '$1<redacted>@')
    # 没有 scheme 的 user:pass@host
    $t = [regex]::Replace($t, '(?i)\b[^\s/?#@:]+:[^\s/?#@]+@(?=[A-Za-z0-9])', '<redacted>@')
    # 凭据类查询/表单参数
    $t = [regex]::Replace($t, '(?i)\b(passkey|passphrase|password|pwd|token|secret|apikey|api_key|auth|signature|sig|code)=([^&\s''"]*)', '$1=<redacted>')
    return $t
}
