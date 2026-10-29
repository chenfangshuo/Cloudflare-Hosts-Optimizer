#Requires -Version 7.0
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib\Probe.ps1')
}

Describe 'Get-CfErrorClass' {
    It '识别 1034 边缘限制' {
        Get-CfErrorClass -Body 'error code: 1034' | Should -Be 'restricted'
        Get-CfErrorClass -Body '<title>Error 1034: Edge IP Restricted</title>' | Should -Be 'restricted'
    }
    It '识别 1003' {
        Get-CfErrorClass -Body 'error code: 1003' | Should -Be 'restricted'
    }
    It '普通 403 HTML 不算限制' {
        Get-CfErrorClass -Body '<html><body>403 Forbidden</body></html>' | Should -Be ''
    }
}

Describe 'Select-DomainIp' {
    It '基线失败时选择最佳候选' {
        $b = [pscustomobject]@{ IP = '1.1.1.1'; Ok = $false; Class = 'restricted'; Ttfb = 0.5 }
        $c = @([pscustomobject]@{ IP = '2.2.2.2'; Ok = $true; Class = 'ok'; Ttfb = 0.8 })
        $d = Select-DomainIp -Baseline $b -Candidates $c -MinImprovementPct 15
        $d.IP | Should -Be '2.2.2.2'
        $d.Changed | Should -BeTrue
        $d.Reason | Should -Be 'baseline-failed'
    }

    It '基线是最佳时不切换' {
        $b = [pscustomobject]@{ IP = '2.2.2.2'; Ok = $true; Class = 'ok'; Ttfb = 0.6 }
        $c = @(
            [pscustomobject]@{ IP = '2.2.2.2'; Ok = $true; Class = 'ok'; Ttfb = 0.6 }
            [pscustomobject]@{ IP = '3.3.3.3'; Ok = $true; Class = 'ok'; Ttfb = 0.7 }
        )
        $d = Select-DomainIp -Baseline $b -Candidates $c
        $d.IP | Should -Be '2.2.2.2'
        $d.Changed | Should -BeFalse
    }

    It '改善达到阈值才切换' {
        $b = [pscustomobject]@{ IP = '1.1.1.1'; Ok = $true; Class = 'ok'; Ttfb = 1.0 }
        $c = @([pscustomobject]@{ IP = '2.2.2.2'; Ok = $true; Class = 'ok'; Ttfb = 0.8 })
        $d = Select-DomainIp -Baseline $b -Candidates $c -MinImprovementPct 15
        $d.IP | Should -Be '2.2.2.2'
        $d.Changed | Should -BeTrue
        $d.ImprovementPct | Should -Be 20
    }

    It '改善不足时保留基线' {
        $b = [pscustomobject]@{ IP = '1.1.1.1'; Ok = $true; Class = 'ok'; Ttfb = 1.0 }
        $c = @([pscustomobject]@{ IP = '2.2.2.2'; Ok = $true; Class = 'ok'; Ttfb = 0.9 })
        $d = Select-DomainIp -Baseline $b -Candidates $c -MinImprovementPct 15
        $d.IP | Should -Be '1.1.1.1'
        $d.Changed | Should -BeFalse
        $d.Reason | Should -Be 'below-threshold'
    }

    It '候选类别更差时保留基线' {
        $b = [pscustomobject]@{ IP = '1.1.1.1'; Ok = $true; Class = 'ok'; Ttfb = 0.9 }
        $c = @([pscustomobject]@{ IP = '2.2.2.2'; Ok = $true; Class = 'waf'; Ttfb = 0.5 })
        $d = Select-DomainIp -Baseline $b -Candidates $c
        $d.IP | Should -Be '1.1.1.1'
        $d.Changed | Should -BeFalse
    }

    It '候选类别更好时切换' {
        $b = [pscustomobject]@{ IP = '1.1.1.1'; Ok = $true; Class = 'waf'; Ttfb = 0.6 }
        $c = @([pscustomobject]@{ IP = '2.2.2.2'; Ok = $true; Class = 'ok'; Ttfb = 0.9 })
        $d = Select-DomainIp -Baseline $b -Candidates $c
        $d.IP | Should -Be '2.2.2.2'
        $d.Changed | Should -BeTrue
        $d.Reason | Should -Be 'better-class'
    }

    It '没有可用候选时返回空' {
        $b = [pscustomobject]@{ IP = '1.1.1.1'; Ok = $false; Class = 'bad'; Ttfb = 0 }
        $c = @([pscustomobject]@{ IP = '2.2.2.2'; Ok = $false; Class = 'bad'; Ttfb = 0 })
        $d = Select-DomainIp -Baseline $b -Candidates $c
        $d.IP | Should -BeNullOrEmpty
        $d.Changed | Should -BeFalse
    }
}

Describe 'Test-IpInCidr' {
    It '匹配网段内地址' {
        Test-IpInCidr -Ip '104.16.0.5' -Cidr '104.16.0.0/13' | Should -BeTrue
        Test-IpInCidr -Ip '104.23.255.1' -Cidr '104.16.0.0/13' | Should -BeTrue
    }

    It '拒绝网段外地址' {
        Test-IpInCidr -Ip '104.24.0.1' -Cidr '104.16.0.0/13' | Should -BeFalse
        Test-IpInCidr -Ip '1.1.1.1' -Cidr '104.16.0.0/13' | Should -BeFalse
    }

    It '拒绝地址族不匹配' {
        Test-IpInCidr -Ip '2606:4700::1' -Cidr '104.16.0.0/13' | Should -BeFalse
    }
}

Describe 'Get-Median' {
    It '奇数个取中间' {
        Get-Median -Values @(3, 1, 2) | Should -Be 2
    }
    It '偶数个取中间两值平均' {
        Get-Median -Values @(1, 2, 3, 4) | Should -Be 2.5
    }
}

Describe 'Split-SpeedTestUrl' {
    It '解析默认地址' {
        $t = Split-SpeedTestUrl -UrlTemplate 'https://speed.cloudflare.com/__down?bytes={bytes}'
        $t.Host | Should -Be 'speed.cloudflare.com'
        $t.Port | Should -Be 443
    }
    It '拒绝 http' {
        { Split-SpeedTestUrl -UrlTemplate 'http://example.com/x?bytes={bytes}' } | Should -Throw '*https*'
    }
    It '拒绝凭据' {
        { Split-SpeedTestUrl -UrlTemplate 'https://u:p@example.com/x?bytes={bytes}' } | Should -Throw '*凭据*'
    }
}

Describe 'Get-CfRanges' {
    It '官方列表 15 段' {
        @(Get-CfRanges).Count | Should -Be 15
    }
    It '实验模式追加 104.28' {
        @(Get-CfRanges -Experimental).Count | Should -Be 16
    }
}

Describe 'Select-Stratified' {
    It '优先覆盖不同机房' {
        $c = @(
            [pscustomobject]@{ IP = 'a'; Colo = 'HKG'; Ttfb = 0.10; Loss = 0 }
            [pscustomobject]@{ IP = 'b'; Colo = 'HKG'; Ttfb = 0.11; Loss = 0 }
            [pscustomobject]@{ IP = 'c'; Colo = 'LAX'; Ttfb = 0.20; Loss = 0 }
            [pscustomobject]@{ IP = 'd'; Colo = 'SJC'; Ttfb = 0.30; Loss = 0 }
        )
        $p = @(Select-Stratified -Candidates $c -Count 3)
        $p | Should -HaveCount 3
        @($p | ForEach-Object { $_.Colo } | Select-Object -Unique).Count | Should -Be 3
    }
}
