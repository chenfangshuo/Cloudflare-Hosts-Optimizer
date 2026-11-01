#Requires -Version 7.0
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib\Domains.ps1')
    . (Join-Path $repoRoot 'lib\HostsFile.ps1')
    . (Join-Path $repoRoot 'lib\Menu.ps1')

    function New-HostsFixture {
        param([string]$Path, [string[]]$Lines)
        Set-Content -LiteralPath $Path -Value $Lines -Encoding ascii
        return $Path
    }
}

Describe '菜单定义' {
    It '四个菜单的条目数量' {
        @(Get-MenuItems -Menu Main).Count | Should -Be 11
        @(Get-MenuItems -Menu Import).Count | Should -Be 6
        @(Get-MenuItems -Menu Cfst).Count | Should -Be 5
        @(Get-MenuItems -Menu Task).Count | Should -Be 4
    }

    It '每个菜单的 key 唯一且都能解析' {
        foreach ($menu in @('Main', 'Import', 'Cfst', 'Task')) {
            $items = @(Get-MenuItems -Menu $menu)
            @($items.Key | Select-Object -Unique).Count | Should -Be $items.Count
            foreach ($i in $items) {
                (Get-MenuActionSpec -Menu $menu -Key $i.Key).Label | Should -Be $i.Label
            }
        }
    }

    It '写入和回滚需要管理员并要确认' {
        $apply = Get-MenuActionSpec -Menu Main -Key '9'
        $apply.RequiresAdmin | Should -BeTrue
        $apply.Confirm | Should -BeTrue
        (Get-MenuActionSpec -Menu Main -Key '10').RequiresAdmin | Should -BeTrue
        (Get-MenuActionSpec -Menu Main -Key '8').RequiresAdmin | Should -BeFalse
    }

    It '主菜单按使用顺序排列，1-9 都能直达' {
        $items = @(Get-MenuItems -Menu Main)
        $items[0].Label | Should -Match '导入'
        $items[1].Label | Should -Match '查看域名'
        $items[7].Key | Should -Be '8'
        $items[7].Label | Should -Match 'DryRun'
        $items[8].Key | Should -Be '9'
        $items[8].Label | Should -Match '正式写入'
        $items[9].Key | Should -Be '10'
        $items[10].Key | Should -Be '0'
        foreach ($i in 1..9) {
            Get-MenuActionSpec -Menu Main -Key "$i" | Should -Not -BeNullOrEmpty
        }
    }

    It 'AutoApply 任务需要管理员' {
        (Get-MenuActionSpec -Menu Task -Key '2').RequiresAdmin | Should -BeTrue
        (Get-MenuActionSpec -Menu Task -Key '1').RequiresAdmin | Should -BeFalse
    }

    It '导入来源和输入类型' {
        (Get-MenuActionSpec -Menu Import -Key '1').Source | Should -Be 'Depiler'
        (Get-MenuActionSpec -Menu Import -Key '1').InputKind | Should -Be 'Path'
        (Get-MenuActionSpec -Menu Import -Key '2').Source | Should -Be 'ProxyBypass'
        (Get-MenuActionSpec -Menu Import -Key '3').Source | Should -Be 'Text'
        (Get-MenuActionSpec -Menu Import -Key '4').Source | Should -Be 'Clipboard'
        (Get-MenuActionSpec -Menu Import -Key '5').Kind | Should -Be 'EditDomains'
    }

    It 'CFST 子菜单' {
        (Get-MenuActionSpec -Menu Cfst -Key '1').Method | Should -Be 'Direct'
        (Get-MenuActionSpec -Menu Cfst -Key '2').Method | Should -Be 'Proxy'
        (Get-MenuActionSpec -Menu Cfst -Key '4').InputKind | Should -Be 'Path'
        (Get-MenuActionSpec -Menu Cfst -Key '3').Target | Should -Match 'lanzoub'
    }

    It '未知或空 key 返回 null' {
        Get-MenuActionSpec -Menu Main -Key '99' | Should -BeNullOrEmpty
        Get-MenuActionSpec -Menu Main -Key '  ' | Should -BeNullOrEmpty
        Get-MenuActionSpec -Menu Main -Key 'Q' | Should -BeNullOrEmpty
    }
}

Describe 'Get-DomainOverview' {
    It '只在列表 / 只在 hosts' {
        $domains = Join-Path $TestDrive 'domains.txt'
        Set-Content -LiteralPath $domains -Value @('a.com', 'b.com') -Encoding ascii
        $hosts = Join-Path $TestDrive 'hosts1'
        New-HostsFixture -Path $hosts -Lines @(
            '127.0.0.1 localhost'
            $script:BeginMarker
            '1.2.3.4 a.com'
            '5.6.7.8 c.com'
            $script:EndMarker
        )
        $o = Get-DomainOverview -DomainsFile $domains -HostsPath $hosts
        $o.HostsError | Should -BeNullOrEmpty
        @($o.Listed) | Should -Be @('a.com', 'b.com')
        @($o.OnlyListed) | Should -Be @('b.com')
        @($o.OnlyManaged) | Should -Be @('c.com')
        @($o.Managed['a.com']) | Should -Be @('1.2.3.4')
    }

    It 'hosts 标记异常时返回错误' {
        $domains = Join-Path $TestDrive 'domains2.txt'
        Set-Content -LiteralPath $domains -Value @('a.com') -Encoding ascii
        $hosts = Join-Path $TestDrive 'hosts2'
        New-HostsFixture -Path $hosts -Lines @($script:BeginMarker, '1.2.3.4 a.com')
        $o = Get-DomainOverview -DomainsFile $domains -HostsPath $hosts
        $o.HostsError | Should -Match '标记'
        $o.Managed.Keys.Count | Should -Be 0
    }

    It 'domains.txt 不存在时列表为空' {
        $hosts = Join-Path $TestDrive 'hosts3'
        New-HostsFixture -Path $hosts -Lines @('127.0.0.1 localhost')
        $o = Get-DomainOverview -DomainsFile (Join-Path $TestDrive 'nope.txt') -HostsPath $hosts
        @($o.Listed).Count | Should -Be 0
        $o.ListedError | Should -BeNullOrEmpty
        $o.HostsError | Should -BeNullOrEmpty
    }
}

Describe 'Get-MenuStatus' {
    It '汇总域名、hosts、CFST 和报告时间' {
        $domains = Join-Path $TestDrive 'domains-s.txt'
        Set-Content -LiteralPath $domains -Value @('a.com', 'b.com') -Encoding ascii
        $hosts = Join-Path $TestDrive 'hosts-s'
        New-HostsFixture -Path $hosts -Lines @(
            '127.0.0.1 localhost'
            $script:BeginMarker
            '1.2.3.4 a.com'
            $script:EndMarker
        )
        $cfst = Join-Path $TestDrive 'cfst-s'
        New-Item -ItemType Directory -Path $cfst -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $cfst 'cfst.exe') -Value 'MZ' -Encoding ascii
        $report = Join-Path $TestDrive 'last-report.txt'
        Set-Content -LiteralPath $report -Value 'x' -Encoding utf8

        $s = Get-MenuStatus -DomainsFile $domains -HostsPath $hosts -CfstDir $cfst -ReportPath $report
        $s.Listed | Should -Be 2
        $s.Invalid | Should -Be 0
        $s.Managed | Should -Be 1
        $s.Cfst | Should -Be '缺少 ip.txt'
        $s.LastRun | Should -Not -BeNullOrEmpty
        $s.HostsError | Should -BeNullOrEmpty
    }

    It 'hosts 异常时报告错误' {
        $domains = Join-Path $TestDrive 'domains-s2.txt'
        Set-Content -LiteralPath $domains -Value @('a.com') -Encoding ascii
        $hosts = Join-Path $TestDrive 'hosts-s2'
        New-HostsFixture -Path $hosts -Lines @($script:EndMarker)
        $cfst = Join-Path $TestDrive 'cfst-s2'
        $s = Get-MenuStatus -DomainsFile $domains -HostsPath $hosts -CfstDir $cfst -ReportPath ''
        $s.HostsError | Should -Not -BeNullOrEmpty
        $s.Cfst | Should -Be '未安装'
    }
}

Describe 'Format-MenuFrame' {
    It '每项带序号并保留头部和页脚' {
        $items = @(
            (New-MenuSpec '1' '第一项' 'Script'),
            (New-MenuSpec '2' '第二项' 'Script')
        )
        $lines = @(Format-MenuFrame -Header @('标题', '状态') -Items $items -Footer '↑↓ 选择')
        $lines[0] | Should -Be '标题'
        $lines[1] | Should -Be '状态'
        $lines[2] | Should -Be ''
        $lines[3] | Should -Be ' 1) 第一项'
        $lines[4] | Should -Be ' 2) 第二项'
        $lines[-1] | Should -Be '↑↓ 选择'
    }

    It '两位序号也保持对齐' {
        $items = @(
            (New-MenuSpec '9' '九' 'Script'),
            (New-MenuSpec '10' '十' 'Script'),
            (New-MenuSpec '0' '零' 'Script')
        )
        $lines = @(Format-MenuFrame -Header @() -Items $items -Footer '')
        $lines[1] | Should -Be ' 9) 九'
        $lines[2] | Should -Be '10) 十'
        $lines[3] | Should -Be ' 0) 零'
    }

    It '没有页脚时不额外加空行' {
        $items = @((New-MenuSpec '1' 'A' 'Script'))
        @(Format-MenuFrame -Header @() -Items $items -Footer '').Count | Should -Be 2
    }
}

Describe 'New-ElevatedArgumentLine' {
    It '空参数（正式写入）也带 -Elevated' {
        $line = New-ElevatedArgumentLine -MenuScript 'C:\My Tools\Menu.ps1'
        $line | Should -Match '-Elevated '
        $line | Should -Match '-ElevatedArgs ""'
        $line.Contains('"C:\My Tools\Menu.ps1"') | Should -BeTrue
    }

    It '参数按顺序拼接' {
        $line = New-ElevatedArgumentLine -MenuScript 'C:\Menu.ps1' -Arguments @('-InstallTask', '-TaskMode', 'AutoApply')
        $line | Should -Match '-ElevatedArgs "-InstallTask -TaskMode AutoApply"'
    }
}

Describe 'Get-MenuInitialIndex' {
    It '没有域名时停在导入' {
        Get-MenuInitialIndex -Menu Main -DomainCount 0 | Should -Be 0
    }

    It '已有域名时停在 DryRun' {
        $items = @(Get-MenuItems -Menu Main)
        $expected = 0
        for ($i = 0; $i -lt $items.Count; $i++) { if ($items[$i].Key -eq '8') { $expected = $i } }
        Get-MenuInitialIndex -Menu Main -DomainCount 5 | Should -Be $expected
    }

    It '子菜单默认第一项' {
        Get-MenuInitialIndex -Menu Import -DomainCount 9 | Should -Be 0
    }
}

Describe '任务菜单纯逻辑' {
    It '查询失败显示未知，不显示无任务' {
        (@(Get-TaskStatusLines -Info ([pscustomobject]@{ Available = $false; Tasks = @() })))[0] | Should -Match '未知'
    }

    It '没有任务和无任务状态' {
        (@(Get-TaskStatusLines -Info ([pscustomobject]@{ Available = $true; Tasks = @() })))[0] | Should -Match '无'
    }

    It '有任务时列出名称、状态和下次运行' {
        $info = [pscustomobject]@{
            Available = $true
            Tasks     = @([pscustomobject]@{ TaskName = 'Cloudflare-Hosts-Optimizer DryRun'; State = 'Ready'; NextRun = '2026-11-15 10:00'; LastRun = ''; LastResult = $null })
        }
        $line = (@(Get-TaskStatusLines -Info $info))[0]
        $line | Should -Match 'DryRun'
        $line | Should -Match 'Ready'
        $line | Should -Match '2026-11-15'
    }

    It '覆盖确认取消时不执行，确认后才带 -TaskForce' {
        Get-TaskInstallPlan -Arguments @('-InstallTask', '-TaskMode', 'DryRun') -TaskExists $true -Confirmed $false | Should -BeNullOrEmpty
        $plan = Get-TaskInstallPlan -Arguments @('-InstallTask', '-TaskMode', 'DryRun') -TaskExists $true -Confirmed $true
        $plan.Arguments | Should -Contain '-TaskForce'
        $plain = Get-TaskInstallPlan -Arguments @('-InstallTask', '-TaskMode', 'DryRun') -TaskExists $false
        $plain.Arguments | Should -Not -Contain '-TaskForce'
    }

    It 'UAC 结果文案' {
        Format-ElevatedResult -ExitCode 0 | Should -Match '退出码 0'
        Format-ElevatedResult -ExitCode 3 | Should -Match '退出码 3'
        Format-ElevatedResult -ExitCode $null -Cancelled $true | Should -Match '取消'
    }
}
