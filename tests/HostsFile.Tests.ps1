#Requires -Version 7.0
<#
    hosts 解析/增量更新/写入/回滚的离线测试。

    不访问网络，不碰真实 hosts；所有文件都在 $TestDrive 里。
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:RepoRoot = $repoRoot
    . (Join-Path $repoRoot 'lib\Domains.ps1')
    . (Join-Path $repoRoot 'lib\HostsFile.ps1')

    $script:AllDomains = @('cf.example.net', 'example.org')

    function New-HostsFixture {
        param([string]$Path)
        $lines = @(
            '127.0.0.1 localhost'
            '0.0.0.0 ads.example.com'
            ''
            '# user entries'
            '203.0.113.10 cf.example.net'
            '203.0.113.11 example.org'
        )
        [IO.File]::WriteAllText($Path, (($lines -join "`r`n") + "`r`n"), [Text.ASCIIEncoding]::new())
    }

    function New-Doc {
        param([string]$Path)
        New-HostsFixture -Path $Path
        Read-HostsDocument -Path $Path
    }
}

Describe 'Read-HostsDocument' {
    It '接受纯 ASCII' {
        $tmp = Join-Path $TestDrive 'ascii.txt'
        New-HostsFixture $tmp
        $doc = Read-HostsDocument -Path $tmp
        $doc.Encoding | Should -Be 'ASCII'
        $doc.HasBom | Should -BeFalse
        $doc.Text | Should -Match '127\.0\.0\.1 localhost'
    }

    It '保留 UTF-8 BOM' {
        $tmp = Join-Path $TestDrive 'bom.txt'
        $bytes = [byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("127.0.0.1 localhost`r`n")
        [IO.File]::WriteAllBytes($tmp, $bytes)
        $doc = Read-HostsDocument -Path $tmp
        $doc.HasBom | Should -BeTrue
        $doc.Encoding | Should -Be 'UTF8'
        $doc.Text | Should -Not -Match "^﻿"
    }

    It '拒绝 GBK/ANSI' {
        $tmp = Join-Path $TestDrive 'gbk.txt'
        [IO.File]::WriteAllBytes($tmp, [byte[]](0x23, 0x20, 0xD6, 0xD0, 0xCE, 0xC4, 0x0D, 0x0A))
        { Read-HostsDocument -Path $tmp } | Should -Throw '*GBK*'
    }

    It '拒绝 UTF-16' {
        $tmp = Join-Path $TestDrive 'utf16.txt'
        [IO.File]::WriteAllBytes($tmp, [byte[]](0xFF, 0xFE, 0x31, 0x00, 0x0D, 0x00, 0x0A, 0x00))
        { Read-HostsDocument -Path $tmp } | Should -Throw '*UTF-16*'
    }
}

Describe '标记结构校验' {
    It '缺 END 时拒绝' {
        $tmp = Join-Path $TestDrive 'noend.txt'
        [IO.File]::WriteAllText($tmp, "127.0.0.1 localhost`r`n$($script:BeginMarker)`r`n10.0.0.1 cf.example.net`r`n", [Text.ASCIIEncoding]::new())
        $doc = Read-HostsDocument -Path $tmp
        { Get-HostsBlockInfo -Lines @($doc.Text -split "`r?`n") } | Should -Throw '*BEGIN=1*'
    }

    It '重复 BEGIN 时拒绝' {
        $tmp = Join-Path $TestDrive 'dup.txt'
        $text = "$($script:BeginMarker)`r`n$($script:BeginMarker)`r`n$($script:EndMarker)`r`n"
        [IO.File]::WriteAllText($tmp, $text, [Text.ASCIIEncoding]::new())
        $doc = Read-HostsDocument -Path $tmp
        { Get-HostsBlockInfo -Lines @($doc.Text -split "`r?`n") } | Should -Throw '*BEGIN=2*'
    }

    It '孤立 END 时拒绝' {
        $tmp = Join-Path $TestDrive 'stray.txt'
        [IO.File]::WriteAllText($tmp, "$($script:EndMarker)`r`n", [Text.ASCIIEncoding]::new())
        $doc = Read-HostsDocument -Path $tmp
        { Get-HostsBlockInfo -Lines @($doc.Text -split "`r?`n") } | Should -Throw '*BEGIN=0*'
    }
}

Describe 'Update-HostsDocument' {
    It '写入新区块并注释旧条目' {
        $doc = New-Doc (Join-Path $TestDrive 'u1.txt')
        $u = Update-HostsDocument -Document $doc -VerifiedMap @{ 'cf.example.net' = @('10.0.0.1') } -ManagedDomains $script:AllDomains
        $u.Changed | Should -BeTrue
        $u.Text | Should -Match "10\.0\.0\.1`tcf\.example\.net"
        $u.Text | Should -Match ([regex]::Escape('# [pt-cf-optimize] 203.0.113.10 cf.example.net'))
        $u.Text | Should -Match '0\.0\.0\.0 ads\.example\.com'
    }

    It '重复运行幂等' {
        $tmp = Join-Path $TestDrive 'u2.txt'
        $doc = New-Doc $tmp
        $map = @{ 'cf.example.net' = @('10.0.0.1') }
        $u1 = Update-HostsDocument -Document $doc -VerifiedMap $map -ManagedDomains $script:AllDomains
        [IO.File]::WriteAllText($tmp, $u1.Text, [Text.ASCIIEncoding]::new())
        $doc2 = Read-HostsDocument -Path $tmp
        $u2 = Update-HostsDocument -Document $doc2 -VerifiedMap $map -ManagedDomains $script:AllDomains
        $u2.Changed | Should -BeFalse
    }

    It '部分失败保留此前的映射' {
        $tmp = Join-Path $TestDrive 'u3.txt'
        $doc = New-Doc $tmp
        $first = Update-HostsDocument -Document $doc -VerifiedMap @{
            'cf.example.net' = @('10.0.0.1')
            'example.org'    = @('10.0.0.2')
        } -ManagedDomains $script:AllDomains
        [IO.File]::WriteAllText($tmp, $first.Text, [Text.ASCIIEncoding]::new())
        $doc2 = Read-HostsDocument -Path $tmp
        # 本次 example.org 未通过验证（不在 map 里），应保留 10.0.0.2
        $second = Update-HostsDocument -Document $doc2 -VerifiedMap @{ 'cf.example.net' = @('10.0.0.9') } -ManagedDomains $script:AllDomains
        $second.FinalMap.Contains('example.org') | Should -BeTrue
        $second.Text | Should -Match "10\.0\.0\.2`texample\.org"
        $second.Text | Should -Match "10\.0\.0\.9`tcf\.example\.net"
    }

    It 'Prune 删除不再管理的域名并还原旧条目' {
        $tmp = Join-Path $TestDrive 'u4.txt'
        $doc = New-Doc $tmp
        $first = Update-HostsDocument -Document $doc -VerifiedMap @{
            'cf.example.net' = @('10.0.0.1')
            'example.org'    = @('10.0.0.2')
        } -ManagedDomains $script:AllDomains
        [IO.File]::WriteAllText($tmp, $first.Text, [Text.ASCIIEncoding]::new())
        $doc2 = Read-HostsDocument -Path $tmp
        $u = Update-HostsDocument -Document $doc2 -VerifiedMap @{ 'cf.example.net' = @('10.0.0.9') } -ManagedDomains @('cf.example.net') -Prune
        $u.Text | Should -Not -Match '10\.0\.0\.2'
        $u.Text | Should -Match '(?m)^203\.0\.113\.11 example\.org'
    }

    It '没有新结果且没有历史映射时不写' {
        $doc = New-Doc (Join-Path $TestDrive 'u5.txt')
        $u = Update-HostsDocument -Document $doc -VerifiedMap @{} -ManagedDomains $script:AllDomains
        $u.Changed | Should -BeFalse
    }

    It '多别名行拒绝' {
        $tmp = Join-Path $TestDrive 'u6.txt'
        [IO.File]::WriteAllText($tmp, "1.2.3.4 other.example cf.example.net`r`n", [Text.ASCIIEncoding]::new())
        $doc = Read-HostsDocument -Path $tmp
        { Update-HostsDocument -Document $doc -VerifiedMap @{} -ManagedDomains $script:AllDomains } |
            Should -Throw '*multi-alias*'
    }

    It 'IPv6 映射拒绝' {
        $tmp = Join-Path $TestDrive 'u7.txt'
        [IO.File]::WriteAllText($tmp, "::1 cf.example.net`r`n", [Text.ASCIIEncoding]::new())
        $doc = Read-HostsDocument -Path $tmp
        { Update-HostsDocument -Document $doc -VerifiedMap @{} -ManagedDomains $script:AllDomains } |
            Should -Throw '*ipv6-mapping*'
    }

    It '其他工具的托管区块拒绝接管' {
        $tmp = Join-Path $TestDrive 'u8.txt'
        $text = "# S302 BEGIN abc`r`n203.0.113.50 cf.example.net`r`n# S302 END abc`r`n"
        [IO.File]::WriteAllText($tmp, $text, [Text.ASCIIEncoding]::new())
        $doc = Read-HostsDocument -Path $tmp
        { Update-HostsDocument -Document $doc -VerifiedMap @{} -ManagedDomains $script:AllDomains } |
            Should -Throw '*foreign-block:S302*'
    }

    It 'DropPreviousDomains 丢弃指定旧映射并还原旧条目' {
        $tmp = Join-Path $TestDrive 'u10.txt'
        $doc = New-Doc $tmp
        $first = Update-HostsDocument -Document $doc -VerifiedMap @{
            'cf.example.net' = @('10.0.0.1')
            'example.org'    = @('10.0.0.2')
        } -ManagedDomains $script:AllDomains
        [IO.File]::WriteAllText($tmp, $first.Text, [Text.ASCIIEncoding]::new())
        $doc2 = Read-HostsDocument -Path $tmp
        $second = Update-HostsDocument -Document $doc2 -VerifiedMap @{ 'cf.example.net' = @('10.0.0.9') } `
            -ManagedDomains $script:AllDomains -DropPreviousDomains @('example.org')
        $second.Text | Should -Not -Match '10\.0\.0\.2'
        $second.Text | Should -Match '(?m)^203\.0\.113\.11 example\.org'
    }

    It '保留 CRLF' {
        $doc = New-Doc (Join-Path $TestDrive 'u9.txt')
        $u = Update-HostsDocument -Document $doc -VerifiedMap @{ 'cf.example.net' = @('10.0.0.1') } -ManagedDomains $script:AllDomains
        $u.Text | Should -Match "`r`n"
        ([regex]::Matches($u.Text, "(?<!`r)`n")).Count | Should -Be 0
    }
}

Describe '写入与回滚' {
    It '备份、原子写入、回滚' {
        $tmp = Join-Path $TestDrive 'w1.txt'
        New-HostsFixture $tmp
        $doc = Read-HostsDocument -Path $tmp
        $u = Update-HostsDocument -Document $doc -VerifiedMap @{ 'cf.example.net' = @('10.0.0.1') } -ManagedDomains $script:AllDomains
        $backupDir = Join-Path $TestDrive 'backup-w1'
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

        $w = Write-HostsDocument -Document $doc -Update $u -BackupDir $backupDir -Version 'test'
        $w.Changed | Should -BeTrue
        (Get-Content $tmp -Raw) | Should -Match '10\.0\.0\.1'

        $r = Invoke-HostsRollback -HostsPath $tmp -BackupDir $backupDir
        (Get-Content $tmp -Raw) | Should -Match '203\.0\.113\.10 cf\.example\.net'
        (Get-Content $tmp -Raw) | Should -Not -Match '10\.0\.0\.1'
    }

    It '回滚按文件名选最近，而不是 LastWriteTime' {
        $tmp = Join-Path $TestDrive 'w2.txt'
        [IO.File]::WriteAllText($tmp, "current`r`n", [Text.ASCIIEncoding]::new())
        $backupDir = Join-Path $TestDrive 'backup-w2'
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        $old = Join-Path $backupDir 'hosts-20260101-000000-aaaaaaaa.bak'
        $new = Join-Path $backupDir 'hosts-20260201-000000-bbbbbbbb.bak'
        [IO.File]::WriteAllText($old, "old`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText($new, "new`r`n", [Text.ASCIIEncoding]::new())
        # 故意把新备份的 LastWriteTime 设得更早
        (Get-Item $new).LastWriteTime = (Get-Date).AddYears(-1)

        Invoke-HostsRollback -HostsPath $tmp -BackupDir $backupDir | Out-Null
        (Get-Content $tmp -Raw).Trim() | Should -Be 'new'
    }

    It '回滚只使用匹配 hostsPath 的备份' {
        $hostsA = Join-Path $TestDrive 'hosts-iso-a.txt'
        $hostsB = Join-Path $TestDrive 'hosts-iso-b.txt'
        [IO.File]::WriteAllText($hostsA, "current-a`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText($hostsB, "current-b`r`n", [Text.ASCIIEncoding]::new())
        $dir = Join-Path $TestDrive 'backup-iso'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $bakA = Join-Path $dir 'hosts-20260101-000000-aaaaaaaa.bak'
        $bakB = Join-Path $dir 'hosts-20260201-000000-bbbbbbbb.bak'
        [IO.File]::WriteAllText($bakA, "backup-a`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText($bakB, "backup-b`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText("$bakA.json", (@{ hostsPath = $hostsA } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText("$bakB.json", (@{ hostsPath = $hostsB } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

        Invoke-HostsRollback -HostsPath $hostsB -BackupDir $dir | Out-Null
        (Get-Content $hostsB -Raw).Trim() | Should -Be 'backup-b'
        (Get-Content $hostsA -Raw).Trim() | Should -Be 'current-a'
    }

    It '内容无变化时不写、不产生备份' {
        $tmp = Join-Path $TestDrive 'w3.txt'
        New-HostsFixture $tmp
        $doc = Read-HostsDocument -Path $tmp
        $u = Update-HostsDocument -Document $doc -VerifiedMap @{} -ManagedDomains $script:AllDomains
        $backupDir = Join-Path $TestDrive 'backup-w3'
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        $w = Write-HostsDocument -Document $doc -Update $u -BackupDir $backupDir -Version 'test'
        $w.Changed | Should -BeFalse
        @(Get-ChildItem $backupDir -Filter 'hosts-*.bak').Count | Should -Be 0
    }
}
