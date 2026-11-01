#Requires -Version 7.0
<#
    真实入口（子进程）的安全回归：输出路径碰撞与凭据脱敏。

    这些用例都在“发任何网络请求之前”被拒绝（参数/路径校验阶段），
    所以可以离线运行；不会碰真实 hosts，也不会访问任何站点。
#>
BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    # 在临时目录里放一份源码副本再运行：脚本的 Root 取自身 PSScriptRoot，
    # 直接跑真实仓库会让失败运行（退出码 2）覆盖用户真实的 last-run.json。
    $script:SandboxRoot = Join-Path $TestDrive 'cli-repo'
    New-Item -ItemType Directory -Path $script:SandboxRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'Cloudflare-Hosts-Optimizer.ps1') -Destination $script:SandboxRoot
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'lib') -Destination (Join-Path $script:SandboxRoot 'lib') -Recurse
    $script:Main = Join-Path $script:SandboxRoot 'Cloudflare-Hosts-Optimizer.ps1'
    $script:Pwsh = (Get-Process -Id $PID).Path
    if (-not $script:Pwsh) { $script:Pwsh = (Get-Command pwsh).Source }

    function Invoke-Cli {
        param(
            [string[]]$Arguments,
            [string]$WorkingDirectory = $TestDrive
        )
        $old = Get-Location
        Push-Location $WorkingDirectory
        try {
            $output = & $script:Pwsh -NoProfile -ExecutionPolicy Bypass -File $script:Main @Arguments 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        return [pscustomobject]@{ ExitCode = $code; Output = $output }
    }

    function New-HostsFixture {
        param([string]$Name = 'hosts', [string]$Content = "127.0.0.1 localhost`r`n")
        $p = Join-Path $TestDrive $Name
        [IO.File]::WriteAllText($p, $Content)
        return $p
    }
}

Describe 'F01 输出路径与 hosts 碰撞' {
    It '报告与 hosts 是同一路径时拒绝，且 hosts 字节不变' {
        $h = New-HostsFixture
        $before = [IO.File]::ReadAllBytes($h)
        $r = Invoke-Cli -Arguments @('-DryRun', '-Rollback', '-HostsPath', $h, '-ReportPath', $h)
        $r.ExitCode | Should -Be 2
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($h)) | Should -Be ([Convert]::ToBase64String($before))
    }

    It '相对路径指向同一文件时拒绝' {
        Push-Location $TestDrive
        try {
            $null = New-HostsFixture -Name 'h'
            $r = Invoke-Cli -Arguments @('-DryRun', '-Rollback', '-HostsPath', 'h', '-ReportPath', '.\h') -WorkingDirectory $TestDrive
            $r.ExitCode | Should -Be 2
            (Get-Content -LiteralPath (Join-Path $TestDrive 'h') -Raw) | Should -Match 'localhost'
        } finally { Pop-Location }
    }

    It '大小写不同但同一文件时拒绝' {
        $h = New-HostsFixture -Name 'HostsFile'
        $upper = (Join-Path $TestDrive 'HOSTSFILE')
        $r = Invoke-Cli -Arguments @('-DryRun', '-Rollback', '-HostsPath', $h, '-ReportPath', $upper)
        $r.ExitCode | Should -Be 2
    }

    It '硬链接指向 hosts 时拒绝' {
        $h = New-HostsFixture -Name 'real-hosts'
        $link = Join-Path $TestDrive 'alias-hosts'
        New-Item -ItemType HardLink -Path $link -Target $h | Out-Null
        $r = Invoke-Cli -Arguments @('-DryRun', '-Rollback', '-HostsPath', $h, '-ReportPath', $link)
        $r.ExitCode | Should -Be 2
        (Get-Content -LiteralPath $h -Raw) | Should -Match 'localhost'
    }

    It '计划文件与 hosts 碰撞时拒绝' {
        $h = New-HostsFixture
        $r = Invoke-Cli -Arguments @('-Plan', '-PlanPath', $h, '-HostsPath', $h, '-Domains', 'example.com')
        $r.ExitCode | Should -Be 2
        (Get-Content -LiteralPath $h -Raw) | Should -Match 'localhost'
    }

    It '报告与域名文件碰撞时拒绝，域名文件不变' {
        $hosts = New-HostsFixture
        $domains = Join-Path $TestDrive 'domains.txt'
        Set-Content -LiteralPath $domains -Value 'example.com' -Encoding utf8
        $r = Invoke-Cli -Arguments @('-DryRun', '-HostsPath', $hosts, '-DomainsFile', $domains, '-ReportPath', $domains)
        $r.ExitCode | Should -Be 2
        (Get-Content -LiteralPath $domains -Raw) | Should -Match 'example\.com'
        (Get-Content -LiteralPath $domains -Raw) | Should -Not -Match 'Cloudflare-Hosts-Optimizer'
    }
}

Describe 'F04 凭据不进入输出' {
    It '-Domains 里的假 passkey 不出现在控制台或报告里' {
        $report = Join-Path $TestDrive 'report.txt'
        $r = Invoke-Cli -Arguments @(
            '-DryRun',
            '-Domains', 'https://example.com/announce.php?passkey=FAKE_AUDIT_TOKEN',
            '-ReportPath', $report
        )
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Not -Match 'FAKE_AUDIT_TOKEN'
        (Get-Content -LiteralPath $report -Raw) | Should -Not -Match 'FAKE_AUDIT_TOKEN'
        (Get-Content -LiteralPath $report -Raw) | Should -Match 'https://example\.com'
    }

    It 'domains.txt 里的假 passkey 只报告行号和脱敏预览' {
        $hosts = New-HostsFixture
        $domains = Join-Path $TestDrive 'domains-bad.txt'
        Set-Content -LiteralPath $domains -Encoding utf8 -Value @(
            'example.com',
            'https://tracker.example.com/announce.php?passkey=FAKE_AUDIT_TOKEN'
        )
        $report = Join-Path $TestDrive 'report-bad.txt'
        $r = Invoke-Cli -Arguments @('-DryRun', '-HostsPath', $hosts, '-DomainsFile', $domains, '-ReportPath', $report)
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Not -Match 'FAKE_AUDIT_TOKEN'
        $text = Get-Content -LiteralPath $report -Raw
        $text | Should -Not -Match 'FAKE_AUDIT_TOKEN'
        $text | Should -Match '第 2 行'
        $text | Should -Match 'https://tracker\.example\.com'
    }
}

Describe 'F02 卸载任务拒绝通配符' {
    It 'TaskName 为 * 时在删除任何任务前退出' {
        $r = Invoke-Cli -Arguments @('-UninstallTask', '-TaskName', '*')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match '任务名无效'
    }

    It 'TaskName 为 ? 时退出' {
        $r = Invoke-Cli -Arguments @('-UninstallTask', '-TaskName', '?')
        $r.ExitCode | Should -Be 2
    }
}

Describe '入口参数互斥仍然有效' {
    It '-AllowUntrustedBackup 不能单独使用' {
        $r = Invoke-Cli -Arguments @('-DryRun', '-AllowUntrustedBackup')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'AllowUntrustedBackup'
    }
}

Describe 'C07 输出互相相等' {
    It 'PlanPath 与 ReportPath 相同会在入口拒绝，文件保持原样' {
        $shared = Join-Path $TestDrive 'shared-plan-report.json'
        Set-Content -LiteralPath $shared -Value 'ORIGINAL_PLAN' -Encoding utf8
        $hosts = New-HostsFixture -Name 'c07-hosts'
        # 域名非法，确保不会走到网络阶段
        $r = Invoke-Cli -Arguments @('-Plan', '-PlanPath', $shared, '-ReportPath', $shared,
            '-HostsPath', $hosts, '-Domains', 'not a domain')
        $r.ExitCode | Should -Be 2
        (Get-Content -LiteralPath $shared -Raw) | Should -Match 'ORIGINAL_PLAN'
    }
}

Describe 'C06 不可信来源开关' {
    It '缺少 -RollbackFrom 时退出码 2' {
        $r = Invoke-Cli -Arguments @('-Rollback', '-AllowUntrustedBackup')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'AllowUntrustedBackup'
    }
}

Describe 'C09 CLI 测试隔离' {
    It '不写真实仓库的 last-run.json' {
        $real = Join-Path $script:RepoRoot 'last-run.json'
        $before = if (Test-Path -LiteralPath $real) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($real)) } else { $null }
        $h = New-HostsFixture -Name 'c09-hosts'
        $report = Join-Path $TestDrive 'c09-report.txt'
        $null = Invoke-Cli -Arguments @('-DryRun', '-Rollback', '-HostsPath', $h, '-ReportPath', $report)
        $after = if (Test-Path -LiteralPath $real) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($real)) } else { $null }
        $after | Should -Be $before
    }
}
