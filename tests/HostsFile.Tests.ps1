#Requires -Version 7.0
<#
    hosts 解析/增量更新/写入/回滚的离线测试。

    不访问网络，不碰真实 hosts；所有文件都在 $TestDrive 里。
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:RepoRoot = $repoRoot
    . (Join-Path $repoRoot 'lib\Safety.ps1')
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
        $u.Text | Should -Match ([regex]::Escape("$($script:LegacyTag)203.0.113.10 cf.example.net"))
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
        # 区块外的旧条目会被恢复，并作为告警返回（hosts 仍指向它）
        $second.Warnings | Should -HaveCount 1
        $second.Warnings[0].Domain | Should -Be 'example.org'
        $second.Warnings[0].Ip | Should -Be '203.0.113.11'
        $second.Warnings[0].Kind | Should -Be 'restored'
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
        $w.CommittedAt | Should -Not -BeNullOrEmpty
        (Get-Content $tmp -Raw) | Should -Match '10\.0\.0\.1'

        $r = Invoke-HostsRollback -HostsPath $tmp -BackupDir $backupDir
        $r.CommittedAt | Should -Not -BeNullOrEmpty
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
        $post = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($tmp))
        foreach ($f in @($old, $new)) {
            $mf = @{
                hostsPath = $tmp
                preHash   = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($f))
                postHash  = if ($f -eq $new) { $post } else { Get-Sha256Hex -Bytes ([Text.Encoding]::ASCII.GetBytes('old-post')) }
            }
            [IO.File]::WriteAllText("$f.json", ($mf | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        }
        # 故意把新备份的 LastWriteTime 设得更早
        (Get-Item $new).LastWriteTime = (Get-Date).AddYears(-1)

        Invoke-HostsRollback -HostsPath $tmp -BackupDir $backupDir | Out-Null
        (Get-Content $tmp -Raw).Trim() | Should -Be 'new'
    }

    It '同一秒内的提交按 manifest 时间选最新，不按随机 GUID' {
        $tmp = Join-Path $TestDrive 'w2b.txt'
        [IO.File]::WriteAllText($tmp, "v2`r`n", [Text.ASCIIEncoding]::new())
        $dir = Join-Path $TestDrive 'backup-w2b'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        # 名字里的 GUID 排序与实际先后相反：先写的那份名字更大
        $older = Join-Path $dir 'hosts-20260101-000000-ffffffff.bak'
        $newer = Join-Path $dir 'hosts-20260101-000000-00000000.bak'
        [IO.File]::WriteAllText($older, "v0`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText($newer, "v1`r`n", [Text.ASCIIEncoding]::new())
        $currentHash = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($tmp))
        $manifests = @(
            @{ File = $older; Data = @{
                    hostsPath = $tmp
                    preHash   = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($older))
                    postHash  = Get-Sha256Hex -Bytes ([Text.Encoding]::ASCII.GetBytes("v1`r`n"))
                    createdAt = '2026-01-01T10:00:00.1000000+08:00'
                } }
            @{ File = $newer; Data = @{
                    hostsPath = $tmp
                    preHash   = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($newer))
                    postHash  = $currentHash
                    createdAt = '2026-01-01T10:00:00.9000000+08:00'
                } }
        )
        foreach ($m in $manifests) {
            [IO.File]::WriteAllText("$($m.File).json", ($m.Data | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        }

        Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir | Out-Null
        (Get-Content $tmp -Raw).Trim() | Should -Be 'v1'
    }

    It '缺 createdAt 的较新备份按文件名时间参与排序（R6）' {
        $tmp = Join-Path $TestDrive 'w2c.txt'
        [IO.File]::WriteAllText($tmp, "v2`r`n", [Text.ASCIIEncoding]::new())
        $dir = Join-Path $TestDrive 'backup-w2c'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        # 较早的备份有 createdAt；较新的备份缺该字段，只能靠文件名判断
        $older = Join-Path $dir 'hosts-20260101-000000-aaaaaaaa.bak'
        $newer = Join-Path $dir 'hosts-20260201-000000-bbbbbbbb.bak'
        [IO.File]::WriteAllText($older, "v0`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText($newer, "v1`r`n", [Text.ASCIIEncoding]::new())
        $currentHash = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($tmp))
        $olderManifest = @{
            hostsPath = $tmp
            preHash   = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($older))
            postHash  = Get-Sha256Hex -Bytes ([Text.Encoding]::ASCII.GetBytes("v1`r`n"))
            createdAt = '2026-01-01T00:00:00.1000000+08:00'
        }
        $newerManifest = @{
            hostsPath = $tmp
            preHash   = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($newer))
            postHash  = $currentHash
        }
        [IO.File]::WriteAllText("$older.json", ($olderManifest | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText("$newer.json", ($newerManifest | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

        Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir | Out-Null
        (Get-Content $tmp -Raw).Trim() | Should -Be 'v1'
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
        [IO.File]::WriteAllText("$bakA.json", (@{
                    hostsPath = $hostsA
                    preHash   = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($bakA))
                    postHash  = Get-Sha256Hex -Bytes ([Text.Encoding]::ASCII.GetBytes('a-post'))
                } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText("$bakB.json", (@{
                    hostsPath = $hostsB
                    preHash   = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($bakB))
                    postHash  = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($hostsB))
                } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

        Invoke-HostsRollback -HostsPath $hostsB -BackupDir $dir | Out-Null
        (Get-Content $hostsB -Raw).Trim() | Should -Be 'backup-b'
        (Get-Content $hostsA -Raw).Trim() | Should -Be 'current-a'
    }

    It '可以指定较早的备份回滚' {
        $tmp = Join-Path $TestDrive 'hosts-pick.txt'
        [IO.File]::WriteAllText($tmp, "current`r`n", [Text.ASCIIEncoding]::new())
        $dir = Join-Path $TestDrive 'backup-pick'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $old = Join-Path $dir 'hosts-20260101-000000-aaaaaaaa.bak'
        $new = Join-Path $dir 'hosts-20260201-000000-bbbbbbbb.bak'
        [IO.File]::WriteAllText($old, "old`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText($new, "new`r`n", [Text.ASCIIEncoding]::new())
        $post = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($tmp))
        foreach ($f in @($old, $new)) {
            $mf = @{
                hostsPath = $tmp
                preHash   = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($f))
                postHash  = if ($f -eq $new) { $post } else { Get-Sha256Hex -Bytes ([Text.Encoding]::ASCII.GetBytes('old-post')) }
            }
            [IO.File]::WriteAllText("$f.json", ($mf | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        }

        Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir -BackupPath $old | Out-Null
        (Get-Content $tmp -Raw).Trim() | Should -Be 'old'
    }

    It '指定目录而不是备份文件时报错并列出可用备份' {
        $tmp = Join-Path $TestDrive 'hosts-dir.txt'
        [IO.File]::WriteAllText($tmp, "current`r`n", [Text.ASCIIEncoding]::new())
        $dir = Join-Path $TestDrive 'backup-dir'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $bak = Join-Path $dir 'hosts-20260101-000000-cccccccc.bak'
        [IO.File]::WriteAllText($bak, "x`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText("$bak.json", (@{ hostsPath = $tmp } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

        { Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir -BackupPath $dir } | Should -Throw '*可用备份*'
        (Get-Content $tmp -Raw).Trim() | Should -Be 'current'
    }

    It '拒绝没有 manifest 或目标不匹配的指定备份' {
        $tmp = Join-Path $TestDrive 'hosts-nomf.txt'
        [IO.File]::WriteAllText($tmp, "current`r`n", [Text.ASCIIEncoding]::new())
        $dir = Join-Path $TestDrive 'backup-nomf'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $bare = Join-Path $dir 'hosts-20260101-000000-dddddddd.bak'
        $other = Join-Path $dir 'hosts-20260201-000000-eeeeeeee.bak'
        [IO.File]::WriteAllText($bare, "bare`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText($other, "other`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText("$other.json", (@{ hostsPath = (Join-Path $TestDrive 'other-hosts.txt') } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

        { Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir -BackupPath $bare } | Should -Throw '*缺少 manifest*'
        { Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir -BackupPath $other } | Should -Throw '*不是当前 hosts*'
        (Get-Content $tmp -Raw).Trim() | Should -Be 'current'
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

Describe '事务与回滚校验（评审修复）' {
    It 'OriginalHash 来自读取时的字节快照' {
        $tmp = Join-Path $TestDrive 'snap.txt'
        New-HostsFixture $tmp
        $doc = Read-HostsDocument -Path $tmp
        $doc.OriginalHash | Should -Be (Get-Sha256Hex -Bytes $doc.Bytes)
        Add-Content -LiteralPath $tmp -Value '# changed after read' -Encoding ascii
        $doc.OriginalHash | Should -Be (Get-Sha256Hex -Bytes $doc.Bytes)
        $doc.OriginalHash | Should -Not -Be (Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($tmp)))
    }

    It 'UTF-8 BOM 在写入后保留' {
        $tmp = Join-Path $TestDrive 'bom-write.txt'
        $lines = "127.0.0.1 localhost`r`n203.0.113.10 cf.example.net`r`n"
        $bytes = [byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes($lines)
        [IO.File]::WriteAllBytes($tmp, $bytes)
        $doc = Read-HostsDocument -Path $tmp
        $u = Update-HostsDocument -Document $doc -VerifiedMap @{ 'cf.example.net' = @('10.0.0.1') } -ManagedDomains $script:AllDomains
        $backupDir = Join-Path $TestDrive 'backup-bom'
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        $null = Write-HostsDocument -Document $doc -Update $u -BackupDir $backupDir -Version 'test'
        $after = [IO.File]::ReadAllBytes($tmp)
        $after[0] | Should -Be 0xEF
        $after[1] | Should -Be 0xBB
        $after[2] | Should -Be 0xBF
    }

    It '备份内容与 preHash 不一致时拒绝回滚' {
        $tmp = Join-Path $TestDrive 'rb-corrupt.txt'
        [IO.File]::WriteAllText($tmp, "current`r`n", [Text.ASCIIEncoding]::new())
        $dir = Join-Path $TestDrive 'backup-corrupt'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $bak = Join-Path $dir 'hosts-20260101-000000-aaaaaaaa.bak'
        [IO.File]::WriteAllText($bak, "good`r`n", [Text.ASCIIEncoding]::new())
        $pre = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($bak))
        [IO.File]::WriteAllText($bak, "corrupted`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText("$bak.json", (@{ hostsPath = $tmp; preHash = $pre } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        { Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir } | Should -Throw '*不一致*'
        (Get-Content $tmp -Raw).Trim() | Should -Be 'current'
    }

    It '-BackupPath 时也检查 postHash，-Force 才覆盖' {
        $tmp = Join-Path $TestDrive 'rb-post.txt'
        [IO.File]::WriteAllText($tmp, "changed`r`n", [Text.ASCIIEncoding]::new())
        $dir = Join-Path $TestDrive 'backup-post'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $bak = Join-Path $dir 'hosts-20260101-000000-bbbbbbbb.bak'
        [IO.File]::WriteAllText($bak, "restored`r`n", [Text.ASCIIEncoding]::new())
        $mf = @{
            hostsPath = $tmp
            preHash   = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($bak))
            postHash  = Get-Sha256Hex -Bytes ([Text.Encoding]::ASCII.GetBytes("something else`r`n"))
        }
        [IO.File]::WriteAllText("$bak.json", ($mf | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        { Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir -BackupPath $bak } | Should -Throw '*修改过*'
        Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir -BackupPath $bak -Force | Out-Null
        (Get-Content $tmp -Raw).Trim() | Should -Be 'restored'
    }

    It 'manifest 缺少 preHash 的备份被拒绝' {
        $tmp = Join-Path $TestDrive 'rb-nopre.txt'
        [IO.File]::WriteAllText($tmp, "current`r`n", [Text.ASCIIEncoding]::new())
        $dir = Join-Path $TestDrive 'backup-nopre'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $bak = Join-Path $dir 'hosts-20260101-000000-cccccccc.bak'
        [IO.File]::WriteAllText($bak, "x`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText("$bak.json", (@{ hostsPath = $tmp } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        { Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir -BackupPath $bak } | Should -Throw '*preHash*'
    }
}

Describe '回滚异常组合（v0.5.4）' {
    It '较新未完成事务不会挡住较早已完成事务' {
        $tmp = Join-Path $TestDrive 'rb-pref.txt'
        [IO.File]::WriteAllText($tmp, "current`r`n", [Text.ASCIIEncoding]::new())
        $dir = Join-Path $TestDrive 'backup-pref'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $older = Join-Path $dir 'hosts-20260101-000000-aaaaaaaa.bak'
        $newer = Join-Path $dir 'hosts-20260201-000000-bbbbbbbb.bak'
        [IO.File]::WriteAllText($older, "older`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText($newer, "newer`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText("$older.json", (@{
                    hostsPath = $tmp
                    preHash   = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($older))
                    postHash  = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($tmp))
                } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText("$newer.json", (@{
                    hostsPath = $tmp
                    preHash   = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($newer))
                } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

        $r = Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir
        $r.Restored | Should -Be $older
        (Get-Content $tmp -Raw).Trim() | Should -Be 'older'
    }

    It '未完成事务且当前文件被改 → 拒绝，-Force 才恢复' {
        $tmp = Join-Path $TestDrive 'rb-uncommitted.txt'
        [IO.File]::WriteAllText($tmp, "changed`r`n", [Text.ASCIIEncoding]::new())
        $dir = Join-Path $TestDrive 'backup-uncommitted'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $bak = Join-Path $dir 'hosts-20260101-000000-dddddddd.bak'
        [IO.File]::WriteAllText($bak, "restore`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText("$bak.json", (@{
                    hostsPath = $tmp
                    preHash   = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($bak))
                } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

        { Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir } | Should -Throw '*无法确认*'
        (Get-Content $tmp -Raw).Trim() | Should -Be 'changed'
        Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir -Force | Out-Null
        (Get-Content $tmp -Raw).Trim() | Should -Be 'restore'
    }

    It '当前内容等于备份时是无变化成功' {
        $tmp = Join-Path $TestDrive 'rb-same.txt'
        [IO.File]::WriteAllText($tmp, "same`r`n", [Text.ASCIIEncoding]::new())
        $dir = Join-Path $TestDrive 'backup-same'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $bak = Join-Path $dir 'hosts-20260101-000000-eeeeeeee.bak'
        [IO.File]::WriteAllText($bak, "same`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText("$bak.json", (@{
                    hostsPath = $tmp
                    preHash   = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($bak))
                    postHash  = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($tmp))
                } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

        $r = Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir
        $r.Unchanged | Should -BeTrue
        $r.CommittedAt | Should -BeNullOrEmpty
    }

    It '-Force 不能绕过损坏的备份' {
        $tmp = Join-Path $TestDrive 'rb-force-corrupt.txt'
        [IO.File]::WriteAllText($tmp, "current`r`n", [Text.ASCIIEncoding]::new())
        $dir = Join-Path $TestDrive 'backup-force-corrupt'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $bak = Join-Path $dir 'hosts-20260101-000000-ffffffff.bak'
        [IO.File]::WriteAllText($bak, "good`r`n", [Text.ASCIIEncoding]::new())
        $pre = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($bak))
        [IO.File]::WriteAllText($bak, "corrupted`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText("$bak.json", (@{
                    hostsPath = $tmp
                    preHash   = $pre
                    postHash  = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($tmp))
                } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

        { Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir -Force } | Should -Throw '*不一致*'
    }

    It '另一实例持锁时回滚被拒绝，释放后可重试' {
        $tmp = Join-Path $TestDrive 'rb-lock.txt'
        [IO.File]::WriteAllText($tmp, "current`r`n", [Text.ASCIIEncoding]::new())
        $dir = Join-Path $TestDrive 'backup-lock'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $bak = Join-Path $dir 'hosts-20260101-000000-abababab.bak'
        [IO.File]::WriteAllText($bak, "restore`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText("$bak.json", (@{
                    hostsPath = $tmp
                    preHash   = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($bak))
                    postHash  = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($tmp))
                } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

        $state = [hashtable]::Synchronized(@{ Ready = $false; Release = $false })
        $job = Start-ThreadJob -ArgumentList $state -ScriptBlock {
            param($s)
            $m = [Threading.Mutex]::new($false, 'Global\Cloudflare-Hosts-Optimizer')
            [void]$m.WaitOne()
            $s.Ready = $true
            while (-not $s.Release) { Start-Sleep -Milliseconds 50 }
            $m.ReleaseMutex()
        }
        $deadline = (Get-Date).AddSeconds(5)
        while (-not $state.Ready -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 20 }
        $state.Ready | Should -BeTrue
        { Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir } | Should -Throw '*另一个*'
        $state.Release = $true
        $null = Wait-Job $job -Timeout 5
        Remove-Job $job -Force

        $r = Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir
        $r.Unchanged | Should -BeFalse
        (Get-Content $tmp -Raw).Trim() | Should -Be 'restore'
    }
}

Describe 'F03 备份来源可信度' {
    BeforeAll {
        function New-TestAcl {
            param([string]$OwnerSid, [object[]]$Rules = @())
            $acl = [System.Security.AccessControl.DirectorySecurity]::new()
            $acl.SetOwner([System.Security.Principal.SecurityIdentifier]::new($OwnerSid))
            foreach ($r in $Rules) { $acl.AddAccessRule($r) }
            return $acl
        }
        function New-TestRule {
            param(
                [string]$Sid,
                [string]$Rights,
                [string]$Type = 'Allow',
                [string]$Inheritance = 'None',
                [string]$Propagation = 'None'
            )
            $rightsValue = if ($Rights -match '^\d+$') {
                [System.Security.AccessControl.FileSystemRights][int]$Rights
            } else {
                [System.Security.AccessControl.FileSystemRights]$Rights
            }
            return [System.Security.AccessControl.FileSystemAccessRule]::new(
                [System.Security.Principal.SecurityIdentifier]::new($Sid),
                $rightsValue,
                [System.Security.AccessControl.InheritanceFlags]$Inheritance,
                [System.Security.AccessControl.PropagationFlags]$Propagation,
                [System.Security.AccessControl.AccessControlType]$Type)
        }
    }

    It '所有者是 Administrators 且只有管理员可写时可信' {
        $rules = @(
            (New-TestRule -Sid 'S-1-5-18' -Rights 'FullControl'),
            (New-TestRule -Sid 'S-1-5-32-544' -Rights 'FullControl'),
            (New-TestRule -Sid 'S-1-5-32-545' -Rights 'ReadAndExecute')
        )
        Test-AclEntries -OwnerSid 'S-1-5-32-544' -Rules $rules | Should -BeTrue
    }

    It '普通用户有写权限时不可信' {
        $rules = @(New-TestRule -Sid 'S-1-5-32-545' -Rights 'Write')
        Test-AclEntries -OwnerSid 'S-1-5-32-544' -Rules $rules | Should -BeFalse
    }

    It '显式授予普通用户 SID 的 Modify 也不可信' {
        $rules = @(New-TestRule -Sid 'S-1-5-21-111111111-222222222-333333333-1001' -Rights 'Modify')
        Test-AclEntries -OwnerSid 'S-1-5-32-544' -Rules $rules | Should -BeFalse
    }

    It '所有者是普通用户时不可信' {
        Test-AclEntries -OwnerSid 'S-1-5-21-111111111-222222222-333333333-1001' | Should -BeFalse
    }

    It '仅 WRITE_DAC 也不可信' {
        $rules = @(New-TestRule -Sid 'S-1-5-32-545' -Rights 'ChangePermissions')
        Test-AclEntries -OwnerSid 'S-1-5-32-544' -Rules $rules | Should -BeFalse
    }

    It '父目录模式忽略“建文件”权限，但仍拦截删除' {
        $create = @(New-TestRule -Sid 'S-1-5-32-545' -Rights 'Write' -Inheritance 'ContainerInherit')
        Test-AclEntries -OwnerSid 'S-1-5-32-544' -Rules $create -Ancestor | Should -BeTrue

        $delete = @(New-TestRule -Sid 'S-1-5-32-545' -Rights 'Delete' -Inheritance 'ContainerInherit')
        Test-AclEntries -OwnerSid 'S-1-5-32-544' -Rules $delete -Ancestor | Should -BeFalse
    }

    It '普通用户拥有的临时目录不可信' {
        $d = Join-Path $TestDrive 'trust-dir'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Test-BackupPathTrusted -Path $d -Root $TestDrive | Should -BeFalse
    }

    It '不存在的路径不可信' {
        Test-BackupPathTrusted -Path (Join-Path $TestDrive 'nope') -Root $TestDrive | Should -BeFalse
    }

    It '系统 hosts 自动挑选只保留可信目录，-AllowUntrustedBackup 才放行' {
        $d = Join-Path $TestDrive 'untrusted-bk'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $r = Select-TrustedBackupDirs -Dirs @($d) -IsSystem $true
        @($r.Trusted).Count | Should -Be 0
        @($r.Untrusted) | Should -Contain $d

        $r2 = Select-TrustedBackupDirs -Dirs @($d) -IsSystem $true -AllowUntrusted
        @($r2.Trusted) | Should -Contain $d

        $r3 = Select-TrustedBackupDirs -Dirs @($d) -IsSystem $false
        @($r3.Trusted) | Should -Contain $d
    }
}

Describe 'F08 备份目录选择与回退' {
    It '只计算已存在的候选目录，不创建' {
        $a = Join-Path $TestDrive 'bk-a'
        $b = Join-Path $TestDrive 'bk-b'
        New-Item -ItemType Directory -Force -Path $a | Out-Null
        $dirs = @(Get-HostsBackupDirs -BaseCandidates @($a, $b))
        $dirs | Should -Contain $a
        $dirs | Should -Not -Contain $b
        Test-Path -LiteralPath $b | Should -BeFalse
    }

    It '首个候选不可创建时回退到下一个' {
        $bad = Join-Path $TestDrive 'bk-file'
        Set-Content -LiteralPath $bad -Value 'not a directory'
        $good = Join-Path $TestDrive 'bk-good'
        $dir = Get-HostsBackupDir -BaseCandidates @($bad, $good)
        $dir | Should -Be $good
        Test-Path -LiteralPath (Join-Path $good '.cfo-write-test-should-not-exist.tmp') | Should -BeFalse
    }
}

Describe 'F05 两阶段提交' {
    BeforeAll {
        function Get-ContentHash {
            param([string]$Text)
            return Get-Sha256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes($Text))
        }
        function New-ManifestBackup {
            param([string]$Dir, [string]$Name, [string]$Content, [hashtable]$Manifest)
            $bak = Join-Path $Dir $Name
            [IO.File]::WriteAllText($bak, $Content)
            ($Manifest | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath "$bak.json" -Encoding utf8
            return $bak
        }
    }

    It '未完成的 B→C 不会被当成最新已完成事务（回滚应恢复 A）' {
        $h = Join-Path $TestDrive 'p1-hosts'
        [IO.File]::WriteAllText($h, 'B')
        $dir = Join-Path $TestDrive 'p1-bk'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $hA = Get-ContentHash 'A'; $hB = Get-ContentHash 'B'; $hC = Get-ContentHash 'C'

        $null = New-ManifestBackup -Dir $dir -Name 'hosts-20260101-000001-aaaaaaaa.bak' -Content 'A' -Manifest @{
            createdAt = '2026-01-01T00:00:01.0000000+08:00'; hostsPath = $h
            preHash = $hA; intendedHash = $hB; postHash = $hB; state = 'committed'
        }
        $null = New-ManifestBackup -Dir $dir -Name 'hosts-20260101-000002-bbbbbbbb.bak' -Content 'B' -Manifest @{
            createdAt = '2026-01-01T00:00:02.0000000+08:00'; hostsPath = $h
            preHash = $hB; intendedHash = $hC; postHash = $null; state = 'pending'
        }

        $r = Invoke-HostsRollback -HostsPath $h -BackupDir $dir
        $r.Unchanged | Should -BeFalse
        (Get-Content -LiteralPath $h -Raw).Trim() | Should -Be 'A'
    }

    It '已替换但完成标记未落盘的 pending，按已完成恢复且不需要 -Force' {
        $h = Join-Path $TestDrive 'p2-hosts'
        [IO.File]::WriteAllText($h, 'C')
        $dir = Join-Path $TestDrive 'p2-bk'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $hB = Get-ContentHash 'B'; $hC = Get-ContentHash 'C'

        $null = New-ManifestBackup -Dir $dir -Name 'hosts-20260101-000003-cccccccc.bak' -Content 'B' -Manifest @{
            createdAt = '2026-01-01T00:00:03.0000000+08:00'; hostsPath = $h
            preHash = $hB; intendedHash = $hC; postHash = $null; state = 'pending'
        }

        $r = Invoke-HostsRollback -HostsPath $h -BackupDir $dir -Force:$false
        $r.Unchanged | Should -BeFalse
        (Get-Content -LiteralPath $h -Raw).Trim() | Should -Be 'B'
    }

    It 'aborted 记录不参与挑选' {
        $h = Join-Path $TestDrive 'p3-hosts'
        [IO.File]::WriteAllText($h, 'B')
        $dir = Join-Path $TestDrive 'p3-bk'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $hA = Get-ContentHash 'A'; $hB = Get-ContentHash 'B'
        $null = New-ManifestBackup -Dir $dir -Name 'hosts-20260101-000004-dddddddd.bak' -Content 'A' -Manifest @{
            createdAt = '2026-01-01T00:00:04.0000000+08:00'; hostsPath = $h
            preHash = $hA; intendedHash = $hB; postHash = $null; state = 'aborted'
        }
        { Invoke-HostsRollback -HostsPath $h -BackupDir $dir } | Should -Throw '*没有找到*'
    }

    It '旧格式（无 state、有 postHash）仍按已完成处理' {
        $h = Join-Path $TestDrive 'p4-hosts'
        [IO.File]::WriteAllText($h, 'B')
        $dir = Join-Path $TestDrive 'p4-bk'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $hA = Get-ContentHash 'A'; $hB = Get-ContentHash 'B'
        $null = New-ManifestBackup -Dir $dir -Name 'hosts-20260101-000005-eeeeeeee.bak' -Content 'A' -Manifest @{
            createdAt = '2026-01-01T00:00:05.0000000+08:00'; hostsPath = $h
            preHash = $hA; postHash = $hB
        }
        $r = Invoke-HostsRollback -HostsPath $h -BackupDir $dir
        $r.Unchanged | Should -BeFalse
        (Get-Content -LiteralPath $h -Raw).Trim() | Should -Be 'A'
    }

    It '写入成功后 manifest 标记为 committed 并记录实际哈希' {
        $tmp = Join-Path $TestDrive 'p5-hosts.txt'
        New-HostsFixture $tmp
        $doc = Read-HostsDocument -Path $tmp
        $u = Update-HostsDocument -Document $doc -VerifiedMap @{ 'cf.example.net' = @('10.0.0.1') } -ManagedDomains $script:AllDomains
        $dir = Join-Path $TestDrive 'p5-bk'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null

        $w = Write-HostsDocument -Document $doc -Update $u -BackupDir $dir -Version 'test'
        $w.Changed | Should -BeTrue
        $w.Verified | Should -BeTrue
        $w.Warning | Should -BeNullOrEmpty

        $m = Get-Content -LiteralPath "$($w.Backup).json" -Raw -Encoding utf8 | ConvertFrom-Json
        $m.state | Should -Be 'committed'
        $m.intendedHash | Should -Not -BeNullOrEmpty
        $m.postHash | Should -Be (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
        $m.verified | Should -BeTrue
    }
}

Describe 'C05 ACL 泛型权限与父链' {
    It '非 InheritOnly 的 GENERIC_ALL 对普通用户不可信' {
        $sd = [System.Security.AccessControl.RawSecurityDescriptor]::new('O:BAG:BAD:(A;;GA;;;WD)')
        $rules = @($sd.DiscretionaryAcl)
        Test-AclEntries -OwnerSid 'S-1-5-32-544' -Rules $rules | Should -BeFalse
    }

    It 'InheritOnly 的 GENERIC_ALL 不作用于对象本身' {
        $sd = [System.Security.AccessControl.RawSecurityDescriptor]::new('O:BAG:BAD:(A;OICIIO;GA;;;WD)')
        $rules = @($sd.DiscretionaryAcl)
        Test-AclEntries -OwnerSid 'S-1-5-32-544' -Rules $rules | Should -BeTrue
    }

    It '具体写权限位仍被识别' {
        # 0x120116 = 删除 + 写属性等
        $sd = [System.Security.AccessControl.RawSecurityDescriptor]::new('O:BAG:BAD:(A;;0x120116;;;WD)')
        $rules = @($sd.DiscretionaryAcl)
        Test-AclEntries -OwnerSid 'S-1-5-32-544' -Rules $rules | Should -BeFalse
    }

    It '只读规则仍然可信' {
        $sd = [System.Security.AccessControl.RawSecurityDescriptor]::new('O:BAG:BAD:(A;;0x120089;;;WD)')
        $rules = @($sd.DiscretionaryAcl)
        Test-AclEntries -OwnerSid 'S-1-5-32-544' -Rules $rules | Should -BeTrue
    }

    It '普通用户目录里的备份文件不可信（文件与父链一起查）' {
        $dir = Join-Path $TestDrive 'c05-dir'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $f = Join-Path $dir 'hosts-20260101-000000-aaaaaaaa.bak'
        Set-Content -LiteralPath $f -Value 'x'
        Test-BackupPathTrusted -Path $f -Root $TestDrive | Should -BeFalse
    }
}

Describe 'C03 读回哈希失败后的回滚' {
    It '替换后哈希读取抛错时，正常回滚不需要 -Force' {
        $tmp = Join-Path $TestDrive 'c03-hosts.txt'
        New-HostsFixture $tmp
        $doc = Read-HostsDocument -Path $tmp
        $u = Update-HostsDocument -Document $doc -VerifiedMap @{ 'cf.example.net' = @('10.0.0.1') } -ManagedDomains $script:AllDomains
        $dir = Join-Path $TestDrive 'c03-bk'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null

        $script:c03HashCalls = 0
        Mock Get-FileHash {
            $script:c03HashCalls++
            if ($script:c03HashCalls -eq 2) { throw 'Injected hash failure' }
            $bytes = [IO.File]::ReadAllBytes($LiteralPath)
            [pscustomobject]@{ Hash = (Get-Sha256Hex -Bytes $bytes) }
        }

        $w = Write-HostsDocument -Document $doc -Update $u -BackupDir $dir -Version 'test'
        $w.Changed | Should -BeTrue
        $w.Verified | Should -BeFalse
        $w.Warning | Should -Not -BeNullOrEmpty

        $m = Get-Content -LiteralPath "$($w.Backup).json" -Raw -Encoding utf8 | ConvertFrom-Json
        $m.state | Should -Be 'committed'
        $m.postHash | Should -BeNullOrEmpty
        $m.intendedHash | Should -Not -BeNullOrEmpty

        { Invoke-HostsRollback -HostsPath $tmp -BackupDir $dir } | Should -Not -Throw
        (Get-Content -LiteralPath $tmp -Raw) | Should -Match '203\.0\.113\.10'
    }
}

Describe 'C04 pending 恢复落盘' {
    BeforeAll {
        function Get-ContentHash2 {
            param([string]$Text)
            return Get-Sha256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes($Text))
        }
        function New-ManifestBackup2 {
            param([string]$Dir, [string]$Name, [string]$Content, [hashtable]$Manifest)
            $bak = Join-Path $Dir $Name
            [IO.File]::WriteAllText($bak, $Content)
            ($Manifest | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath "$bak.json" -Encoding utf8
            return $bak
        }
    }

    It '有旧历史的 pending 恢复后，重复回滚停在同一个版本' {
        $h = Join-Path $TestDrive 'c04-hosts'
        [IO.File]::WriteAllText($h, 'C')
        $dir = Join-Path $TestDrive 'c04-bk'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $hA = Get-ContentHash2 'A'; $hB = Get-ContentHash2 'B'; $hC = Get-ContentHash2 'C'

        $null = New-ManifestBackup2 -Dir $dir -Name 'hosts-20260101-000001-aaaaaaaa.bak' -Content 'A' -Manifest @{
            createdAt = '2026-01-01T00:00:01.0000000+08:00'; hostsPath = $h
            preHash = $hA; intendedHash = $hB; postHash = $hB; state = 'committed'
        }
        $pending = New-ManifestBackup2 -Dir $dir -Name 'hosts-20260101-000002-bbbbbbbb.bak' -Content 'B' -Manifest @{
            createdAt = '2026-01-01T00:00:02.0000000+08:00'; hostsPath = $h
            preHash = $hB; intendedHash = $hC; postHash = $null; state = 'pending'
        }

        $r1 = Invoke-HostsRollback -HostsPath $h -BackupDir $dir
        $r1.Unchanged | Should -BeFalse
        (Get-Content -LiteralPath $h -Raw).Trim() | Should -Be 'B'

        $m = Get-Content -LiteralPath "$pending.json" -Raw -Encoding utf8 | ConvertFrom-Json
        $m.state | Should -Be 'committed'
        $m.postHash | Should -Be $hC

        $r2 = Invoke-HostsRollback -HostsPath $h -BackupDir $dir
        $r2.Unchanged | Should -BeTrue
        (Get-Content -LiteralPath $h -Raw).Trim() | Should -Be 'B'
    }
}

Describe 'C06 不可信来源开关必须指定文件' {
    It '只给 -AllowUntrustedBackup 不给备份路径时拒绝' {
        $h = Join-Path $TestDrive 'c06-hosts'
        [IO.File]::WriteAllText($h, 'A')
        $dir = Join-Path $TestDrive 'c06-bk'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        { Invoke-HostsRollback -HostsPath $h -BackupDir $dir -AllowUntrustedBackup } |
            Should -Throw '*RollbackFrom*'
    }
}
