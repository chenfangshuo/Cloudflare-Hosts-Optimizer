#Requires -Version 7.0
<#
    主脚本的“接线”回归：这些行为在 Invoke-Main 里，没有独立的纯函数，
    用源码级断言防止后来的人把守卫改回去（真正的行为测试见 Cli.Tests.ps1）。
#>
BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:MainSource = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Cloudflare-Hosts-Optimizer.ps1') -Raw
}

Describe 'F06 TUN 守卫' {
    It '不再对 DryRun/Plan 放行' {
        $script:MainSource | Should -Not -Match 'if \(\$tun -and -not \$DryRun'
        $script:MainSource | Should -Not -Match '\$tun -and -not \$planMode'
    }

    It '所有模式都只由 -Force 覆盖' {
        $script:MainSource | Should -Match 'if \(\$tun -and -not \$Force\)'
    }
}

Describe 'F07 每 IP 请求预算' {
    It '逐域名循环用预算函数包住每一次显式 IP 探测' {
        $script:MainSource | Should -Match 'Test-ProbeBudgetAllows'
        $script:MainSource | Should -Match 'Add-ProbeUse'
        # 4 个候选来源 + 复核 = 至少 5 处
        ([regex]::Matches($script:MainSource, 'Test-ProbeBudgetAllows')).Count | Should -BeGreaterOrEqual 5
    }

    It '基线复核换了 IP 时不切换' {
        $script:MainSource | Should -Match 'baseline-ip-changed'
        $script:MainSource | Should -Match 'Get-RecheckPlan'
        # 复核失败也不能跳过候选验证
        $script:MainSource | Should -Match "need-candidate"
    }
}

Describe 'F05 两阶段提交接线' {
    It '备份 manifest 先写 pending，完成后再升级' {
        $hostsLib = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'lib\HostsFile.ps1') -Raw
        $hostsLib | Should -Match "state\s*=\s*'pending'"
        $hostsLib | Should -Match "state = 'committed'"
        $hostsLib | Should -Match 'intendedHash'
    }
}
