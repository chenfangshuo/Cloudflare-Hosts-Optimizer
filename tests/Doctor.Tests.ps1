#Requires -Version 7.0
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib\HostsFile.ps1')
    . (Join-Path $repoRoot 'lib\Probe.ps1')
    . (Join-Path $repoRoot 'lib\Doctor.ps1')

    function New-HostsFixture {
        param([string]$Path, [string[]]$Lines)
        Set-Content -LiteralPath $Path -Value $Lines -Encoding ascii
        return $Path
    }
}

Describe 'New-DoctorCheck' {
    It '默认 Detail 为空字符串' {
        $c = New-DoctorCheck -Group '环境' -Name 'PowerShell' -Status 'OK'
        $c.Detail | Should -Be ''
        $c.Status | Should -Be 'OK'
    }

    It '只接受四种状态' {
        { New-DoctorCheck -Group 'g' -Name 'n' -Status 'BAD' } | Should -Throw
    }
}

Describe 'Get-DoctorExitCode' {
    It '没有检查项时返回 0' {
        Get-DoctorExitCode -Checks @() | Should -Be 0
    }

    It 'OK/WARN/SKIP 都算成功' {
        $checks = @(
            New-DoctorCheck -Group 'g' -Name 'a' -Status 'OK'
            New-DoctorCheck -Group 'g' -Name 'b' -Status 'WARN'
            New-DoctorCheck -Group 'g' -Name 'c' -Status 'SKIP'
        )
        Get-DoctorExitCode -Checks $checks | Should -Be 0
    }

    It '任一 FAIL 返回 1' {
        $checks = @(
            New-DoctorCheck -Group 'g' -Name 'a' -Status 'OK'
            New-DoctorCheck -Group 'g' -Name 'b' -Status 'FAIL'
        )
        Get-DoctorExitCode -Checks $checks | Should -Be 1
    }
}

Describe 'Format-DoctorReport' {
    It '按加入顺序分组并给出汇总' {
        $checks = @(
            New-DoctorCheck -Group '环境' -Name 'a' -Status 'OK' -Detail 'x'
            New-DoctorCheck -Group '端点' -Name 'b' -Status 'WARN'
            New-DoctorCheck -Group '环境' -Name 'c' -Status 'SKIP'
        )
        $lines = @(Format-DoctorReport -Checks $checks)
        $lines[0] | Should -Be ''
        $lines[1] | Should -Be '== 环境 =='
        $lines -contains '== 端点 ==' | Should -BeTrue
        ($lines | Where-Object { $_ -eq '== 环境 ==' }).Count | Should -Be 1
        ($lines | Select-Object -Last 1) | Should -Match '1 项通过'
        ($lines | Select-Object -Last 1) | Should -Match '1 项警告'
        ($lines | Select-Object -Last 1) | Should -Match '1 项跳过'
    }

    It '中文详情原样保留' {
        $lines = @(Format-DoctorReport -Checks @(
                New-DoctorCheck -Group 'g' -Name 'n' -Status 'OK' -Detail '编码 ASCII；受管域名 18 个'
            ))
        ($lines -join "`n") | Should -Match '受管域名 18 个'
    }
}

Describe 'IPv4 / CIDR 覆盖' {
    It 'IPv4 整数转换可逆' {
        (ConvertTo-Ipv4Int64 -Ip '0.0.0.0') | Should -Be 0
        (ConvertTo-Ipv4Int64 -Ip '255.255.255.255') | Should -Be 4294967295
        (ConvertFrom-Ipv4Int64 -Value (ConvertTo-Ipv4Int64 -Ip '192.0.2.77')) | Should -Be '192.0.2.77'
        (ConvertTo-Ipv4Int64 -Ip '2001:db8::1') | Should -BeNullOrEmpty
    }

    It '比较两组 /24 的覆盖差异' {
        $g = Get-Cidr24Gap -Builtin @('192.0.2.0/24') -Other @('192.0.3.0/24')
        $g.MissingFromOther | Should -Be 1
        $g.MissingExamples[0] | Should -Be '192.0.2.0/24'
        $g.ExtraInOther | Should -Be 1
        $g.ExtraExamples[0] | Should -Be '192.0.3.0/24'
    }

    It '一个 /23 覆盖两个 /24' {
        $g = Get-Cidr24Gap -Builtin @('192.0.2.0/23') -Other @('192.0.2.0/24')
        $g.MissingFromOther | Should -Be 1
        $g.ExtraInOther | Should -Be 0
    }

    It '比 /24 更细的网段只算所在的那个 /24' {
        (Get-Cidr24Set -Ranges @('192.0.2.128/25')).Count | Should -Be 1
    }
}

Describe 'Get-HostsDoctorInfo' {
    It '正常区块' {
        $path = New-HostsFixture -Path (Join-Path $TestDrive 'hosts-ok') -Lines @(
            '127.0.0.1 localhost'
            $script:BeginMarker
            '203.0.113.10 example.com'
            $script:EndMarker
        )
        $r = Get-HostsDoctorInfo -HostsPath $path
        $r.Error | Should -BeNullOrEmpty
        $r.Exists | Should -BeTrue
        $r.Encoding | Should -Be 'ASCII'
        $r.HasBlock | Should -BeTrue
        $r.ManagedCount | Should -Be 1
        $r.Conflicts.Count | Should -Be 0
    }

    It '文件不存在时通过 Error 返回，不抛异常' {
        $r = Get-HostsDoctorInfo -HostsPath (Join-Path $TestDrive 'nope')
        $r.Exists | Should -BeFalse
        $r.Error | Should -Match '不存在'
    }

    It '缺少 END 时报告标记异常' {
        $path = New-HostsFixture -Path (Join-Path $TestDrive 'hosts-noend') -Lines @(
            '127.0.0.1 localhost'
            $script:BeginMarker
            '203.0.113.10 example.com'
        )
        $r = Get-HostsDoctorInfo -HostsPath $path
        $r.Error | Should -Match '标记'
    }

    It '区块外为受管域名写 IPv6 时报告冲突' {
        $path = New-HostsFixture -Path (Join-Path $TestDrive 'hosts-conflict') -Lines @(
            '2001:db8::1 example.com'
            $script:BeginMarker
            '203.0.113.10 example.com'
            $script:EndMarker
        )
        $r = Get-HostsDoctorInfo -HostsPath $path
        $r.Error | Should -BeNullOrEmpty
        $r.Conflicts.Count | Should -Be 1
        $r.Conflicts[0].Reason | Should -Be 'ipv6-mapping'
    }
}

Describe 'Get-BackupDoctorInfo' {
    It '目录不存在时不报错' {
        $r = Get-BackupDoctorInfo -BackupDir (Join-Path $TestDrive 'no-backup')
        $r.Exists | Should -BeFalse
        $r.Count | Should -Be 0
    }

    It '按文件名取最近的备份，而不是修改时间' {
        $dir = Join-Path $TestDrive 'backup'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $old = Join-Path $dir 'hosts-20260101-000000-aaaaaaaa.bak'
        $new = Join-Path $dir 'hosts-20260102-000000-bbbbbbbb.bak'
        Set-Content -LiteralPath $old -Value 'old' -Encoding ascii
        Set-Content -LiteralPath $new -Value 'new' -Encoding ascii
        # 把较新的文件名设成更早的修改时间，确认不是按时间挑
        (Get-Item $new).LastWriteTime = [datetime]'2026-01-01'
        $r = Get-BackupDoctorInfo -BackupDir $dir
        $r.Count | Should -Be 2
        $r.Newest | Should -Match '^hosts-20260102'
    }

    It '指定 -TestWritable 时检查可写' {
        $dir = Join-Path $TestDrive 'backup-w'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        (Get-BackupDoctorInfo -BackupDir $dir -TestWritable).Writable | Should -BeTrue
        # 探针文件不会留下
        @(Get-ChildItem -LiteralPath $dir -Filter '.doctor-*').Count | Should -Be 0
    }
}

Describe 'Get-CfstDoctorInfo' {
    It '找不到 cfst.exe 时返回 Found=false' {
        $r = Get-CfstDoctorInfo -Root (Join-Path $TestDrive 'empty')
        $r.Found | Should -BeFalse
        $r.Error | Should -BeNullOrEmpty
    }

    It '显式路径不存在时返回 Error' {
        $r = Get-CfstDoctorInfo -CfstPath (Join-Path $TestDrive 'missing.exe')
        $r.Found | Should -BeFalse
        $r.Error | Should -Match '不存在'
    }

    It '统计 ip.txt 网段并算出覆盖差异' {
        $dir = Join-Path $TestDrive 'cfstinfo'
        $sub = Join-Path $dir 'cfst'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        # 不是有效 PE 文件，调用 -h 会失败，版本留空；这里只验证 ip.txt 解析
        Set-Content -LiteralPath (Join-Path $sub 'cfst.exe') -Value 'not-a-real-exe' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $sub 'ip.txt') -Value @('192.0.2.0/24', '198.51.100.0/24') -Encoding ascii
        $r = Get-CfstDoctorInfo -Root $dir -BuiltinRanges @('192.0.2.0/24')
        $r.Found | Should -BeTrue
        $r.CidrCount | Should -Be 2
        $r.MissingFromIpFile | Should -Be 0
        $r.ExtraInIpFile | Should -Be 1
    }
}
