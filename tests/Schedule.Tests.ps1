#Requires -Version 7.0
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib\Schedule.ps1')
    $script:RepoRoot = $repoRoot
}

Describe 'Get-OptimizerPwshPath' {
    It '返回当前 pwsh 的路径' {
        (Get-OptimizerPwshPath) | Should -Match 'pwsh(-preview)?\.exe$'
    }
}

Describe 'Test-OptimizerTaskName' {
    It '接受中文、空格和短横线' {
        Test-OptimizerTaskName -TaskName 'Cloudflare-Hosts-Optimizer DryRun' | Should -Be ''
        Test-OptimizerTaskName -TaskName '优选 任务-1' | Should -Be ''
    }

    It '拒绝反斜杠、通配符和保留字符' {
        Test-OptimizerTaskName -TaskName 'a\b' | Should -Match '不能包含'
        Test-OptimizerTaskName -TaskName 'a*b' | Should -Match '不能包含'
        Test-OptimizerTaskName -TaskName 'a:b' | Should -Match '不能包含'
    }

    It '拒绝空名字' {
        Test-OptimizerTaskName -TaskName '   ' | Should -Match '不能为空'
    }
}

Describe 'New-OptimizerTaskSpec' {
    It 'DryRun 默认值' {
        $s = New-OptimizerTaskSpec -Root $script:RepoRoot
        $s.TaskName | Should -Be 'Cloudflare-Hosts-Optimizer DryRun'
        $s.Mode | Should -Be 'DryRun'
        $s.IntervalDays | Should -Be 14
        $s.At | Should -Be '10:00'
        $s.RequiresAdmin | Should -BeFalse
        $s.Arguments | Should -Match '-DryRun'
        $s.Arguments | Should -Match '-ReportPath'
        $s.Arguments | Should -Match 'last-report\.txt'
        $s.Execute | Should -Match 'pwsh(-preview)?\.exe$'
    }

    It 'AutoApply 默认值' {
        $s = New-OptimizerTaskSpec -Root $script:RepoRoot -Mode AutoApply
        $s.TaskName | Should -Be 'Cloudflare-Hosts-Optimizer AutoApply'
        $s.At | Should -Be '04:00'
        $s.RequiresAdmin | Should -BeTrue
        $s.Arguments | Should -Not -Match '-DryRun'
    }

    It '自定义任务名原样保留' {
        $s = New-OptimizerTaskSpec -Root $script:RepoRoot -TaskName '优选 任务-1'
        $s.TaskName | Should -Be '优选 任务-1'
    }

    It '非法任务名抛错' {
        { New-OptimizerTaskSpec -Root $script:RepoRoot -TaskName 'a\b' } | Should -Throw '*不能包含*'
    }

    It '非法时间抛错' {
        { New-OptimizerTaskSpec -Root $script:RepoRoot -At '25:00' } | Should -Throw
        { New-OptimizerTaskSpec -Root $script:RepoRoot -At '4am' } | Should -Throw
    }

    It '透传开关和值，按参数名排序' {
        $s = New-OptimizerTaskSpec -Root $script:RepoRoot -ExtraParameters @{
            NoCfst     = [System.Management.Automation.SwitchParameter]::new($true)
            TopN       = 2
            SpeedTestUrl = 'https://speed.cloudflare.com/__down?bytes={bytes}'
        }
        $s.Arguments | Should -Match '-NoCfst'
        $s.Arguments | Should -Match '-TopN "2"'
        $s.Arguments | Should -Match '-SpeedTestUrl "https://speed\.cloudflare\.com/__down\?bytes=\{bytes\}"'
        # 排序：NoCfst 在 SpeedTestUrl 前，SpeedTestUrl 在 TopN 前
        $s.Arguments.IndexOf('-NoCfst') | Should -BeLessThan $s.Arguments.IndexOf('-SpeedTestUrl')
    }

    It '数组参数直接拒绝' {
        { New-OptimizerTaskSpec -Root $script:RepoRoot -ExtraParameters @{ Domains = @('a.com', 'b.com') } } |
            Should -Throw '*数组*'
    }

    It '脚本不存在时报错' {
        { New-OptimizerTaskSpec -Root (Join-Path $TestDrive 'no-such-root') } | Should -Throw '*找不到脚本*'
    }
}

Describe 'Install-OptimizerTask' {
    It '-WhatIf 不注册任务' {
        $name = 'Cloudflare-Hosts-Optimizer Pester ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $spec = New-OptimizerTaskSpec -Root $script:RepoRoot -TaskName $name
        $returned = Install-OptimizerTask -Spec $spec -WhatIf
        $returned.TaskName | Should -Be $name
        @(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It '-TaskForce 与 -WhatIf 可以一起用' {
        $spec = New-OptimizerTaskSpec -Root $script:RepoRoot
        { Install-OptimizerTask -Spec $spec -WhatIf -TaskForce } | Should -Not -Throw
    }
}

Describe 'Uninstall-OptimizerTask' {
    It '任务不存在时视为成功' {
        $rows = @(Uninstall-OptimizerTask -TaskName @('Cloudflare-Hosts-Optimizer Pester Missing') -WhatIf)
        $rows.Count | Should -Be 1
        $rows[0].Removed | Should -BeTrue
        $rows[0].Detail | Should -Match '不存在'
    }

    It '不传任务名时目标为两个默认任务' {
        $rows = @(Uninstall-OptimizerTask -WhatIf)
        @($rows.TaskName) | Should -Be @('Cloudflare-Hosts-Optimizer DryRun', 'Cloudflare-Hosts-Optimizer AutoApply')
    }
}
