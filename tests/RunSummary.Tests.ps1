#Requires -Version 7.0
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib\RunSummary.ps1')
}

Describe 'RunSummary 读写' {
    It '文件不存在时返回 null' {
        Read-RunSummary -Path (Join-Path $TestDrive 'none.json') | Should -BeNullOrEmpty
    }

    It '写入后可读，字段完整' {
        $path = Join-Path $TestDrive 's1.json'
        $run = New-RunSummaryRecord -Mode 'write' -HostsPath 'C:\h\hosts' `
            -StartedAt ([datetime]'2026-11-01T10:00:00') -FinishedAt ([datetime]'2026-11-01T10:10:00') `
            -ExitCode 0 -Changed $true -Updated 3 -Kept 12 -Unverified 2 -RunId 'run-1'
        (Write-RunSummary -Path $path -Run $run -Committed $true -CommitMode 'write') | Should -BeTrue
        $s = Read-RunSummary -Path $path
        $s.lastRun.runId | Should -Be 'run-1'
        $s.lastRun.counts.updated | Should -Be 3
        $s.lastRun.changed | Should -BeTrue
        $s.lastCommit.mode | Should -Be 'write'
        $s.lastCommit.runId | Should -Be 'run-1'
    }

    It '无变化的成功运行不更新 lastCommit' {
        $path = Join-Path $TestDrive 's2.json'
        $commit = New-RunSummaryRecord -Mode 'write' -HostsPath 'C:\h\hosts' `
            -StartedAt ([datetime]'2026-11-01T10:00:00') -FinishedAt ([datetime]'2026-11-01T10:05:00') -Changed $true -RunId 'commit-1'
        $null = Write-RunSummary -Path $path -Run $commit -Committed $true
        $nochange = New-RunSummaryRecord -Mode 'dryrun' -HostsPath 'C:\h\hosts' `
            -StartedAt ([datetime]'2026-11-01T11:00:00') -FinishedAt ([datetime]'2026-11-01T11:03:00') -Changed $false -RunId 'dry-1'
        $null = Write-RunSummary -Path $path -Run $nochange -Committed $false
        $s = Read-RunSummary -Path $path
        $s.lastRun.runId | Should -Be 'dry-1'
        $s.lastCommit.runId | Should -Be 'commit-1'
    }

    It '较旧的提交不会覆盖较新的 lastCommit' {
        $path = Join-Path $TestDrive 's3.json'
        $newer = New-RunSummaryRecord -Mode 'write' -HostsPath 'C:\h\hosts' `
            -StartedAt ([datetime]'2026-11-01T12:00:00') -FinishedAt ([datetime]'2026-11-01T12:05:00') -Changed $true -RunId 'newer'
        $null = Write-RunSummary -Path $path -Run $newer -Committed $true
        $older = New-RunSummaryRecord -Mode 'rollback' -HostsPath 'C:\h\hosts' `
            -StartedAt ([datetime]'2026-11-01T09:00:00') -FinishedAt ([datetime]'2026-11-01T09:01:00') -Changed $true -RunId 'older'
        $null = Write-RunSummary -Path $path -Run $older -Committed $true -CommitMode 'rollback'
        $s = Read-RunSummary -Path $path
        $s.lastCommit.runId | Should -Be 'newer'
        $s.lastCommit.mode | Should -Be 'write'
    }

    It '损坏的 JSON 返回 null' {
        $path = Join-Path $TestDrive 'bad.json'
        Set-Content -LiteralPath $path -Value '{not json' -Encoding utf8
        Read-RunSummary -Path $path | Should -BeNullOrEmpty
    }
}

Describe 'Format-RunSummaryLine' {
    It '沙箱运行标注临时 hosts，且不计入系统提交' {
        $path = Join-Path $TestDrive 's4.json'
        $run = New-RunSummaryRecord -Mode 'write' -HostsPath 'C:\temp\x.hosts' `
            -StartedAt ([datetime]'2026-11-01T10:00:00') -FinishedAt ([datetime]'2026-11-01T10:10:00') -Changed $true -RunId 'sandbox'
        $null = Write-RunSummary -Path $path -Run $run -Committed $true
        $s = Read-RunSummary -Path $path
        $f = Format-RunSummaryLine -Summary $s -SystemHostsPath 'C:\Windows\System32\drivers\etc\hosts'
        $f.LastRun | Should -Match '临时 hosts'
        $f.LastCommit | Should -BeNullOrEmpty
    }

    It '回滚提交显示为最近提交：回滚' {
        $path = Join-Path $TestDrive 's5.json'
        $run = New-RunSummaryRecord -Mode 'rollback' -HostsPath 'C:\h\hosts' `
            -StartedAt ([datetime]'2026-11-01T10:00:00') -FinishedAt ([datetime]'2026-11-01T10:01:00') -Changed $true -RunId 'rb'
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
}
