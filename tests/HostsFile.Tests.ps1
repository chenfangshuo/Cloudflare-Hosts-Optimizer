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
