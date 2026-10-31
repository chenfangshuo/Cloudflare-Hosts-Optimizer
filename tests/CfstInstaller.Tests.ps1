#Requires -Version 7.0
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib\Probe.ps1')
    . (Join-Path $repoRoot 'lib\CfstInstaller.ps1')
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    function New-TestZip {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][hashtable]$Entries
        )
        $fs = [IO.File]::Create($Path)
        try {
            $zip = [IO.Compression.ZipArchive]::new($fs, [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($k in $Entries.Keys) {
                    $entry = $zip.CreateEntry($k)
                    $s = $entry.Open()
                    try { $s.Write($Entries[$k], 0, $Entries[$k].Length) } finally { $s.Dispose() }
                }
            } finally { $zip.Dispose() }
        } finally { $fs.Dispose() }
    }

    function New-MzBytes {
        param([int]$Size = 2048)
        $b = [byte[]]::new($Size)
        [Security.Cryptography.RandomNumberGenerator]::Fill($b)
        $b[0] = 0x4D; $b[1] = 0x5A
        return , $b
    }

    function New-IpBytes {
        param([string]$Text = "173.245.48.0/20`n104.16.0.0/13")
        return , [Text.Encoding]::ASCII.GetBytes($Text)
    }

    $script:ValidZipArgs = @{ MinZipBytes = 1; MaxZipBytes = 50MB; MaxExeBytes = 32MB; MaxIpBytes = 1MB; MaxTotalUncompressed = 64MB }
}

Describe 'Get-CfstAssetName' {
    It '按架构映射资产名' {
        Get-CfstAssetName -Architecture 'amd64' | Should -Be 'cfst_windows_amd64.zip'
        Get-CfstAssetName -Architecture 'x64' | Should -Be 'cfst_windows_amd64.zip'
        Get-CfstAssetName -Architecture 'ARM64' | Should -Be 'cfst_windows_arm64.zip'
        Get-CfstAssetName -Architecture 'x86' | Should -Be 'cfst_windows_386.zip'
    }

    It '未知架构报错' {
        { Get-CfstAssetName -Architecture 'mips' } | Should -Throw '*架构*'
    }
}

Describe 'Get-CfstDownloadUrl' {
    It '默认用 latest download' {
        Get-CfstDownloadUrl -Architecture 'amd64' | Should -Be 'https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/cfst_windows_amd64.zip'
    }

    It '指定版本时用固定 tag' {
        (Get-CfstDownloadUrl -Architecture 'amd64' -Version '2.3.5') | Should -Match '/releases/download/v2\.3\.5/cfst_windows_amd64\.zip$'
        (Get-CfstDownloadUrl -Architecture 'amd64' -Version 'v2.3.5') | Should -Match '/releases/download/v2\.3\.5/'
    }

    It '非法版本号报错' {
        { Get-CfstDownloadUrl -Architecture 'amd64' -Version '../evil' } | Should -Throw '*版本号*'
    }
}

Describe 'ConvertFrom-ProxyServer' {
    It '接受 host:port' {
        (ConvertFrom-ProxyServer -Value '127.0.0.1:7897').Url | Should -Be 'http://127.0.0.1:7897'
    }

    It '优先 https 键' {
        $r = ConvertFrom-ProxyServer -Value 'http=127.0.0.1:7897;https=127.0.0.1:7898'
        $r.Url | Should -Be 'http://127.0.0.1:7898'
    }

    It 'socks 转成 socks5h' {
        (ConvertFrom-ProxyServer -Value 'socks=127.0.0.1:1080').Url | Should -Be 'socks5h://127.0.0.1:1080'
        (ConvertFrom-ProxyServer -Value 'socks5h://127.0.0.1:1080').Url | Should -Be 'socks5h://127.0.0.1:1080'
    }

    It '支持 IPv6 写法' {
        (ConvertFrom-ProxyServer -Value '[::1]:7897').Url | Should -Be 'http://[::1]:7897'
    }

    It '带凭据时不返回地址' {
        $r = ConvertFrom-ProxyServer -Value 'user:pass@127.0.0.1:7897'
        $r.Url | Should -BeNullOrEmpty
        $r.HasCredentials | Should -BeTrue
        $r.Reason | Should -Match '凭据'
    }

    It '不支持的协议返回原因' {
        $r = ConvertFrom-ProxyServer -Value 'ftp=127.0.0.1:21'
        $r.Url | Should -BeNullOrEmpty
        $r.Reason | Should -Match '不支持'
    }

    It '空值和坏端口' {
        (ConvertFrom-ProxyServer -Value '').Reason | Should -Match '未配置'
        (ConvertFrom-ProxyServer -Value '127.0.0.1:0').Url | Should -BeNullOrEmpty
    }
}

Describe 'Get-SystemProxyUrl' {
    It '未启用时返回原因' {
        $r = Get-SystemProxyUrl -ProxyEnable 0 -ProxyServer '' -AutoConfigUrl ''
        $r.Enabled | Should -BeFalse
        $r.Reason | Should -Match '未启用'
    }

    It '启用且是简单格式' {
        $r = Get-SystemProxyUrl -ProxyEnable 1 -ProxyServer '127.0.0.1:7897' -AutoConfigUrl ''
        $r.Url | Should -Be 'http://127.0.0.1:7897'
    }

    It '只有 PAC 时明确说不支持' {
        $r = Get-SystemProxyUrl -ProxyEnable 1 -ProxyServer '' -AutoConfigUrl 'http://example.com/proxy.pac'
        $r.Url | Should -BeNullOrEmpty
        $r.Reason | Should -Match 'PAC'
    }

    It '带凭据的系统代理不返回地址' {
        $r = Get-SystemProxyUrl -ProxyEnable 1 -ProxyServer 'u:p@127.0.0.1:7897' -AutoConfigUrl ''
        $r.HasCredentials | Should -BeTrue
        $r.Url | Should -BeNullOrEmpty
    }
}

Describe 'Test-ZipEntryNamesSafe' {
    It '正常条目通过' {
        Test-ZipEntryNamesSafe -Names @('cfst.exe', 'ip.txt', 'docs/a.txt') | Should -BeTrue
    }

    It '拒绝穿越和绝对路径' {
        Test-ZipEntryNamesSafe -Names @('../evil.txt') | Should -BeFalse
        Test-ZipEntryNamesSafe -Names @('/etc/passwd') | Should -BeFalse
        Test-ZipEntryNamesSafe -Names @('C:\evil.txt') | Should -BeFalse
        Test-ZipEntryNamesSafe -Names @('\\server\share\x') | Should -BeFalse
    }

    It '拒绝空名和大小写重复' {
        Test-ZipEntryNamesSafe -Names @('') | Should -BeFalse
        Test-ZipEntryNamesSafe -Names @('cfst.exe', 'CFST.EXE') | Should -BeFalse
    }
}

Describe 'Expand-CfstArchive' {
    It '只解出 cfst.exe 和 ip.txt' {
        $zip = Join-Path $TestDrive 'good.zip'
        New-TestZip -Path $zip -Entries @{
            'cfst.exe' = (New-MzBytes)
            'ip.txt'   = (New-IpBytes)
            'ipv6.txt' = (New-IpBytes)
            'readme.txt' = [Text.Encoding]::ASCII.GetBytes('hello')
        }
        $dest = Join-Path $TestDrive 'cfst-ok'
        $r = Expand-CfstArchive -ZipPath $zip -Destination $dest @script:ValidZipArgs
        $r.Installed | Should -BeTrue
        Test-Path (Join-Path $dest 'cfst.exe') | Should -BeTrue
        Test-Path (Join-Path $dest 'ip.txt') | Should -BeTrue
        Test-Path (Join-Path $dest 'ipv6.txt') | Should -BeFalse
    }

    It '缺 ip.txt 时报结构错误' {
        $zip = Join-Path $TestDrive 'noip.zip'
        New-TestZip -Path $zip -Entries @{ 'cfst.exe' = (New-MzBytes) }
        { Expand-CfstArchive -ZipPath $zip -Destination (Join-Path $TestDrive 'x1') @script:ValidZipArgs } |
            Should -Throw '*结构*'
    }

    It '不是 zip 时报错' {
        $bad = Join-Path $TestDrive 'bad.zip'
        Set-Content -LiteralPath $bad -Value 'not a zip' -Encoding ascii
        { Expand-CfstArchive -ZipPath $bad -Destination (Join-Path $TestDrive 'x2') @script:ValidZipArgs } |
            Should -Throw '*PK*'
    }

    It '拒绝路径穿越条目' {
        $zip = Join-Path $TestDrive 'evil.zip'
        New-TestZip -Path $zip -Entries @{
            'cfst.exe'   = (New-MzBytes)
            'ip.txt'     = (New-IpBytes)
            '../evil.txt' = [Text.Encoding]::ASCII.GetBytes('x')
        }
        { Expand-CfstArchive -ZipPath $zip -Destination (Join-Path $TestDrive 'x3') @script:ValidZipArgs } |
            Should -Throw '*不安全*'
    }

    It 'exe 不是 MZ 时拒绝' {
        $zip = Join-Path $TestDrive 'nomz.zip'
        New-TestZip -Path $zip -Entries @{
            'cfst.exe' = [Text.Encoding]::ASCII.GetBytes('not an exe')
            'ip.txt'   = (New-IpBytes)
        }
        { Expand-CfstArchive -ZipPath $zip -Destination (Join-Path $TestDrive 'x4') @script:ValidZipArgs } |
            Should -Throw '*MZ*'
    }

    It 'ip.txt 没有 CIDR 时拒绝' {
        $zip = Join-Path $TestDrive 'noidr.zip'
        New-TestZip -Path $zip -Entries @{
            'cfst.exe' = (New-MzBytes)
            'ip.txt'   = [Text.Encoding]::ASCII.GetBytes('no ranges here')
        }
        { Expand-CfstArchive -ZipPath $zip -Destination (Join-Path $TestDrive 'x5') @script:ValidZipArgs } |
            Should -Throw '*CIDR*'
    }

    It '已存在且没有 -Force 时保留旧文件' {
        $dest = Join-Path $TestDrive 'existing'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dest 'cfst.exe') -Value 'OLD' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $dest 'ip.txt') -Value 'OLD' -Encoding ascii
        $zip = Join-Path $TestDrive 'good2.zip'
        New-TestZip -Path $zip -Entries @{ 'cfst.exe' = (New-MzBytes); 'ip.txt' = (New-IpBytes) }
        $r = Expand-CfstArchive -ZipPath $zip -Destination $dest @script:ValidZipArgs
        $r.Skipped | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $dest 'ip.txt') -Raw).Trim() | Should -Be 'OLD'
    }

    It '有 -Force 时覆盖' {
        $dest = Join-Path $TestDrive 'existing2'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dest 'cfst.exe') -Value 'OLD' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $dest 'ip.txt') -Value 'OLD' -Encoding ascii
        $zip = Join-Path $TestDrive 'good3.zip'
        New-TestZip -Path $zip -Entries @{ 'cfst.exe' = (New-MzBytes); 'ip.txt' = (New-IpBytes) }
        $r = Expand-CfstArchive -ZipPath $zip -Destination $dest -Force @script:ValidZipArgs
        $r.Installed | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $dest 'ip.txt') -Raw) | Should -Match '173\.245\.48\.0/20'
    }

    It '目标路径含空格和中文' {
        $zip = Join-Path $TestDrive 'good4.zip'
        New-TestZip -Path $zip -Entries @{ 'cfst.exe' = (New-MzBytes); 'ip.txt' = (New-IpBytes) }
        $dest = Join-Path $TestDrive '安装 目录'
        (Expand-CfstArchive -ZipPath $zip -Destination $dest @script:ValidZipArgs).Installed | Should -BeTrue
        Test-Path (Join-Path $dest 'cfst.exe') | Should -BeTrue
    }
}

Describe 'Install-CfstPackage -FromFile' {
    BeforeAll {
        # 这里走默认的 1MB 下限，所以用 >1MB 的随机内容；随机数据压缩比接近 1
        $script:Zip = Join-Path $TestDrive 'pkg.zip'
        New-TestZip -Path $script:Zip -Entries @{
            'cfst.exe' = (New-MzBytes -Size 1200000)
            'ip.txt'   = (New-IpBytes)
        }
    }

    It '从本地 zip 安装' {
        $dest = Join-Path $TestDrive 'pkg-ok'
        $r = Install-CfstPackage -Destination $dest -FromFile $script:Zip
        $r.Installed | Should -BeTrue
        $r.Sha256 | Should -Match '^[0-9a-f]{64}$'
        Test-Path (Join-Path $dest 'ip.txt') | Should -BeTrue
    }

    It '已安装时跳过' {
        $dest = Join-Path $TestDrive 'pkg-skip'
        $null = Install-CfstPackage -Destination $dest -FromFile $script:Zip
        $r = Install-CfstPackage -Destination $dest -FromFile $script:Zip
        $r.Skipped | Should -BeTrue
    }

    It 'FromFile 与代理互斥' {
        { Install-CfstPackage -Destination (Join-Path $TestDrive 'pkg-x') -FromFile $script:Zip -UseProxy } |
            Should -Throw '*不能与*'
    }

    It 'SHA256 不匹配时拒绝' {
        { Install-CfstPackage -Destination (Join-Path $TestDrive 'pkg-h') -FromFile $script:Zip -ExpectedSha256 ('0' * 64) } |
            Should -Throw '*SHA256*'
    }
}

Describe 'Get-CfstInstallState' {
    It '空目录 / 只有 exe / 完整' {
        $dest = Join-Path $TestDrive 'state'
        (Get-CfstInstallState -Destination $dest).Installed | Should -BeFalse
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dest 'cfst.exe') -Value 'MZ' -Encoding ascii
        $s = Get-CfstInstallState -Destination $dest
        $s.HasExe | Should -BeTrue
        $s.Installed | Should -BeFalse
        Set-Content -LiteralPath (Join-Path $dest 'ip.txt') -Value '1.1.1.0/24' -Encoding ascii
        (Get-CfstInstallState -Destination $dest).Installed | Should -BeTrue
    }
}
