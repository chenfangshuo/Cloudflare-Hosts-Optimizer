#Requires -Version 7.0
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib\RunSummary.ps1')
    $script:SystemHosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $script:SandboxHosts = 'C:\temp\x.hosts'
}

Describe 'RunSummary 读写' {
    It '文件不存在时返回 null' {
        Read-RunSummary -Path (Join-Path $TestDrive 'none.json') | Should -BeNullOrEmpty
    }

    It '写入后可读，字段完整' {
        $path = Join-Path $TestDrive 's1.json'
        $run = New-RunSummaryRecord -Mode 'write' -HostsPath 'C:\h\hosts' `
            -StartedAt ([datetime]'2026-11-01T10:00:00') -FinishedAt ([datetime]'2026-11-01T10:10:00') `
            -CommittedAt ([datetime]'2026-11-01T10:05:00') `
            -ExitCode 0 -Changed $true -Updated 3 -Kept 12 -Unverified 2 -RunId 'run-1'
        (Write-RunSummary -Path $path -Run $run -Committed $true -CommitMode 'write') | Should -BeTrue
        $s = Read-RunSummary -Path $path
        $s.lastRun.runId | Should -Be 'run-1'
        $s.lastRun.counts.updated | Should -Be 3
        $s.lastRun.changed | Should -BeTrue
        $s.lastRun.committedAt | Should -Not -BeNullOrEmpty
        $key = (ConvertTo-SummaryPathKey -Path 'C:\h\hosts')
        $s.commits.$key.mode | Should -Be 'write'
        $s.commits.$key.runId | Should -Be 'run-1'
    }

    It '无变化的成功运行不更新提交记录' {
        $path = Join-Path $TestDrive 's2.json'
        $commit = New-RunSummaryRecord -Mode 'write' -HostsPath 'C:\h\hosts' `
            -StartedAt ([datetime]'2026-11-01T10:00:00') -FinishedAt ([datetime]'2026-11-01T10:05:00') `
            -CommittedAt ([datetime]'2026-11-01T10:02:00') -Changed $true -RunId 'commit-1'
        $null = Write-RunSummary -Path $path -Run $commit -Committed $true
        $nochange = New-RunSummaryRecord -Mode 'dryrun' -HostsPath 'C:\h\hosts' `
            -StartedAt ([datetime]'2026-11-01T11:00:00') -FinishedAt ([datetime]'2026-11-01T11:03:00') -Changed $false -RunId 'dry-1'
        $null = Write-RunSummary -Path $path -Run $nochange -Committed $false
        $s = Read-RunSummary -Path $path
        $s.lastRun.runId | Should -Be 'dry-1'
        $key = ConvertTo-SummaryPathKey -Path 'C:\h\hosts'
        $s.commits.$key.runId | Should -Be 'commit-1'
    }

    It '较旧的提交不会覆盖较新的提交' {
        $path = Join-Path $TestDrive 's3.json'
        $newer = New-RunSummaryRecord -Mode 'write' -HostsPath 'C:\h\hosts' `
            -StartedAt ([datetime]'2026-11-01T12:00:00') -FinishedAt ([datetime]'2026-11-01T12:05:00') `
            -CommittedAt ([datetime]'2026-11-01T12:04:00') -Changed $true -RunId 'newer'
        $null = Write-RunSummary -Path $path -Run $newer -Committed $true
        $older = New-RunSummaryRecord -Mode 'rollback' -HostsPath 'C:\h\hosts' `
            -StartedAt ([datetime]'2026-11-01T09:00:00') -FinishedAt ([datetime]'2026-11-01T09:01:00') `
            -CommittedAt ([datetime]'2026-11-01T09:00:30') -Changed $true -RunId 'older'
        $null = Write-RunSummary -Path $path -Run $older -Committed $true -CommitMode 'rollback'
        $s = Read-RunSummary -Path $path
        $key = ConvertTo-SummaryPathKey -Path 'C:\h\hosts'
        $s.commits.$key.runId | Should -Be 'newer'
        $s.commits.$key.mode | Should -Be 'write'
    }

    It '提交按事务时间排序，而不是整次运行结束时间' {
        # A 先提交（10:00）但后结束（10:30）；B 后提交（10:05）但先结束（10:06）。
        # 无论谁先写摘要，最近提交都应该是 B。
        $a = New-RunSummaryRecord -Mode 'write' -HostsPath 'C:\h\hosts' `
            -StartedAt ([datetime]'2026-11-01T09:55:00') -FinishedAt ([datetime]'2026-11-01T10:30:00') `
            -CommittedAt ([datetime]'2026-11-01T10:00:00') -Changed $true -RunId 'A'
        $b = New-RunSummaryRecord -Mode 'rollback' -HostsPath 'C:\h\hosts' `
            -StartedAt ([datetime]'2026-11-01T10:04:00') -FinishedAt ([datetime]'2026-11-01T10:06:00') `
            -CommittedAt ([datetime]'2026-11-01T10:05:00') -Changed $true -RunId 'B'
        $key = ConvertTo-SummaryPathKey -Path 'C:\h\hosts'

        $p1 = Join-Path $TestDrive 'order-a-b.json'
        $null = Write-RunSummary -Path $p1 -Run $a -Committed $true
        $null = Write-RunSummary -Path $p1 -Run $b -Committed $true -CommitMode 'rollback'
        (Read-RunSummary -Path $p1).commits.$key.runId | Should -Be 'B'

        $p2 = Join-Path $TestDrive 'order-b-a.json'
        $null = Write-RunSummary -Path $p2 -Run $b -Committed $true -CommitMode 'rollback'
        $null = Write-RunSummary -Path $p2 -Run $a -Committed $true
        (Read-RunSummary -Path $p2).commits.$key.runId | Should -Be 'B'
    }

    It '临时 hosts 的提交不会覆盖系统 hosts 的提交' {
        $path = Join-Path $TestDrive 's4.json'
        $system = New-RunSummaryRecord -Mode 'write' -HostsPath $script:SystemHosts `
            -StartedAt ([datetime]'2026-11-01T10:00:00') -FinishedAt ([datetime]'2026-11-01T10:01:00') `
            -CommittedAt ([datetime]'2026-11-01T10:01:00') -Changed $true -RunId 'sys'
        $null = Write-RunSummary -Path $path -Run $system -Committed $true
        $sandbox = New-RunSummaryRecord -Mode 'write' -HostsPath $script:SandboxHosts `
            -StartedAt ([datetime]'2026-11-01T11:00:00') -FinishedAt ([datetime]'2026-11-01T11:01:00') `
            -CommittedAt ([datetime]'2026-11-01T11:01:00') -Changed $true -RunId 'box'
        $null = Write-RunSummary -Path $path -Run $sandbox -Committed $true

        $s = Read-RunSummary -Path $path
        @($s.commits.PSObject.Properties).Count | Should -Be 2
        $f = Format-RunSummaryLine -Summary $s -SystemHostsPath $script:SystemHosts
        $f.LastCommit | Should -Match '写入'
        $f.LastCommit | Should -Match '10:01'

        # 之后系统 hosts 上的 DryRun 也不能把系统提交抹掉
        $dry = New-RunSummaryRecord -Mode 'dryrun' -HostsPath $script:SystemHosts `
            -StartedAt ([datetime]'2026-11-01T12:00:00') -FinishedAt ([datetime]'2026-11-01T12:01:00') -RunId 'sys-dry'
        $null = Write-RunSummary -Path $path -Run $dry -Committed $false
        $s2 = Read-RunSummary -Path $path
        (Format-RunSummaryLine -Summary $s2 -SystemHostsPath $script:SystemHosts).LastCommit | Should -Match '写入'
    }

    It '记录时规范化相对路径' {
        Push-Location $TestDrive
        try {
            $record = New-RunSummaryRecord -Mode 'write' -HostsPath '.\hosts.tmp' `
                -StartedAt ([datetime]'2026-11-01T10:00:00') -FinishedAt ([datetime]'2026-11-01T10:01:00')
        } finally { Pop-Location }
        [IO.Path]::IsPathRooted($record.hostsPath) | Should -BeTrue
        $record.hostsPath | Should -Match 'hosts\.tmp$'
    }

    It '旧格式 lastCommit 迁移到对应目标' {
        $path = Join-Path $TestDrive 'legacy.json'
        $legacy = [ordered]@{
            lastRun    = @{ runId = 'old-run'; mode = 'write'; hostsPath = $script:SystemHosts; finishedAt = '2026-11-01T09:00:00' }
            lastCommit = @{ runId = 'old-commit'; mode = 'write'; hostsPath = $script:SystemHosts; at = '2026-11-01T09:00:00' }
        }
        ($legacy | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $path -Encoding utf8

        $run = New-RunSummaryRecord -Mode 'dryrun' -HostsPath $script:SystemHosts `
            -StartedAt ([datetime]'2026-11-01T10:00:00') -FinishedAt ([datetime]'2026-11-01T10:01:00') -RunId 'new-run'
        $null = Write-RunSummary -Path $path -Run $run -Committed $false
        $s = Read-RunSummary -Path $path
        $key = ConvertTo-SummaryPathKey -Path $script:SystemHosts
        $s.commits.$key.runId | Should -Be 'old-commit'
        $s.lastCommit | Should -BeNullOrEmpty
    }

    It '损坏的 JSON 返回 null' {
        $path = Join-Path $TestDrive 'bad.json'
        Set-Content -LiteralPath $path -Value '{not json' -Encoding utf8
        Read-RunSummary -Path $path | Should -BeNullOrEmpty
    }
}

Describe 'Format-RunSummaryLine' {
    It '沙箱运行标注临时 hosts，且不计入系统提交' {
        $path = Join-Path $TestDrive 's5.json'
        $run = New-RunSummaryRecord -Mode 'write' -HostsPath $script:SandboxHosts `
            -StartedAt ([datetime]'2026-11-01T10:00:00') -FinishedAt ([datetime]'2026-11-01T10:10:00') -Changed $true -RunId 'sandbox'
        $null = Write-RunSummary -Path $path -Run $run -Committed $true
        $s = Read-RunSummary -Path $path
        $f = Format-RunSummaryLine -Summary $s -SystemHostsPath $script:SystemHosts
        $f.LastRun | Should -Match '临时 hosts'
        $f.LastCommit | Should -BeNullOrEmpty
    }

    It '回滚提交显示为最近提交：回滚' {
        $path = Join-Path $TestDrive 's6.json'
        $run = New-RunSummaryRecord -Mode 'rollback' -HostsPath 'C:\h\hosts' `
            -StartedAt ([datetime]'2026-11-01T10:00:00') -FinishedAt ([datetime]'2026-11-01T10:01:00') `
            -CommittedAt ([datetime]'2026-11-01T10:01:00') -Changed $true -RunId 'rb'
        $null = Write-RunSummary -Path $path -Run $run -Committed $true -CommitMode 'rollback'
        $s = Read-RunSummary -Path $path
        $f = Format-RunSummaryLine -Summary $s -SystemHostsPath 'C:\h\hosts'
        $f.LastCommit | Should -Match '回滚'
    }

    It '摘要缺失时只显示上次报告时间' {
        $report = Join-Path $TestDrive 'last-report.txt'
        Set-Content -LiteralPath $report -Value 'x' -Encoding utf8
        $f = Format-RunSummaryLine -Summary $null -SystemHostsPath 'C:\h\hosts' -ReportPath $report
        $f.LastRun | Should -Match '^上次报告：'
        $f.LastCommit | Should -BeNullOrEmpty
    }

    It '没有系统目标路径时不猜提交' {
        $path = Join-Path $TestDrive 's7.json'
        $run = New-RunSummaryRecord -Mode 'write' -HostsPath 'C:\h\hosts' `
            -StartedAt ([datetime]'2026-11-01T10:00:00') -FinishedAt ([datetime]'2026-11-01T10:01:00') -Changed $true -RunId 'x'
        $null = Write-RunSummary -Path $path -Run $run -Committed $true
        $s = Read-RunSummary -Path $path
        (Format-RunSummaryLine -Summary $s).LastCommit | Should -BeNullOrEmpty
    }
}
