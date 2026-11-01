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
        $d.BestTtfb | Should -Be 0.9
    }

    It '快基线下绝对毫秒门槛拦住小改善' {
        # 80ms -> 66ms：17.5% 达到百分比门槛，但只差 14ms，不应进入复核/切换
        $b = [pscustomobject]@{ IP = '1.1.1.1'; Ok = $true; Class = 'ok'; Ttfb = 0.080 }
        $c = @([pscustomobject]@{ IP = '2.2.2.2'; Ok = $true; Class = 'ok'; Ttfb = 0.066 })
        $d = Select-DomainIp -Baseline $b -Candidates $c -MinImprovementPct 15 -MinImprovementMs 30
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

Describe 'Get-PreviousAction' {
    It '无旧映射时 none' {
        Get-PreviousAction -HasPrevious $false -Baseline ([pscustomobject]@{ Class = 'bad' }) -Decision ([pscustomobject]@{ IP = $null }) |
            Should -Be 'none'
    }
    It '有可用决策时 keep' {
        Get-PreviousAction -HasPrevious $true -Baseline ([pscustomobject]@{ Class = 'ok' }) -Decision ([pscustomobject]@{ IP = '1.1.1.1' }) |
            Should -Be 'keep'
    }
    It '明确 1034 时 drop' {
        Get-PreviousAction -HasPrevious $true -Baseline ([pscustomobject]@{ Class = 'restricted' }) -Decision ([pscustomobject]@{ IP = $null }) |
            Should -Be 'drop'
    }
    It '连接失败默认保留' {
        Get-PreviousAction -HasPrevious $true -Baseline ([pscustomobject]@{ Class = 'bad' }) -Decision ([pscustomobject]@{ IP = $null }) |
            Should -Be 'keep-unreachable'
    }
    It 'DropUnreachable 时 drop' {
        Get-PreviousAction -HasPrevious $true -Baseline ([pscustomobject]@{ Class = 'bad' }) -Decision ([pscustomobject]@{ IP = $null }) -DropUnreachable |
            Should -Be 'drop'
    }
    It '基线可用时 DropUnreachable 不删除健康映射' {
        Get-PreviousAction -HasPrevious $true -Baseline ([pscustomobject]@{ Class = 'ok'; Ok = $true }) -Decision ([pscustomobject]@{ IP = $null }) -DropUnreachable |
            Should -Be 'keep'
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

Describe 'ConvertFrom-CurlWriteOut' {
    It '时间字段统一扣掉 DNS 解析时间' {
        $raw = '|@@|200|0|0.40|0.12|0.14|0.30|0.38|104.17.1.1'
        $m = ConvertFrom-CurlWriteOut -Raw $raw
        $m.Http | Should -Be '200'
        [math]::Round($m.Dns, 2) | Should -Be 0.12
        [math]::Round($m.Connect, 2) | Should -Be 0.02
        [math]::Round($m.Tls, 2) | Should -Be 0.18
        [math]::Round($m.Ttfb, 2) | Should -Be 0.26
        $m.RemoteIp | Should -Be '104.17.1.1'
    }
    It '解析时间为 0 时保持原值' {
        $raw = '|@@|200|0|0.30|0|0.05|0.20|0.28|104.17.1.2'
        $m = ConvertFrom-CurlWriteOut -Raw $raw
        [math]::Round($m.Ttfb, 2) | Should -Be 0.28
    }
    It '负值钳到 0，空输出返回 000' {
        $raw = '|@@|200|0|0.10|0.20|0.08|0.15|0.19|1.2.3.4'
        $m = ConvertFrom-CurlWriteOut -Raw $raw
        $m.Connect | Should -Be 0
        $m.Tls | Should -Be 0
        (ConvertFrom-CurlWriteOut -Raw '').Http | Should -Be '000'
    }
    It '忽略响应体，只取最后一个分隔段' {
        $raw = '<html>body|@@|200|1|0.5|0.1|0.2|0.3|0.4|8.8.8.8'
        $m = ConvertFrom-CurlWriteOut -Raw $raw
        $m.Http | Should -Be '200'
        $m.RemoteIp | Should -Be '8.8.8.8'
    }
}

Describe 'Resolve-SwitchConfirmation' {
    It '复核后改善不足则不切换' {
        $r = Resolve-SwitchConfirmation -BaseTtfb 0.40 -BestTtfb 0.34 `
            -BaseSamples @(0.40) -CandidateSamples @(0.39) -Reason improved
        $r.Switch | Should -BeFalse
        $r.Reason | Should -Be 'not-confirmed'
    }
    It '复核确认改善则切换' {
        $r = Resolve-SwitchConfirmation -BaseTtfb 0.50 -BestTtfb 0.30 `
            -BaseSamples @(0.52) -CandidateSamples @(0.31) -Reason improved
        $r.Switch | Should -BeTrue
        $r.Reason | Should -Be 'confirmed'
    }
    It '候选复测失败不切换' {
        $r = Resolve-SwitchConfirmation -BaseTtfb 0.50 -BestTtfb 0.20 -CandidateFlaky -Reason improved
        $r.Switch | Should -BeFalse
        $r.Reason | Should -Be 'candidate-flaky'
    }
    It '基线复测失败则切换' {
        $r = Resolve-SwitchConfirmation -BaseTtfb 0.50 -BestTtfb 0.45 -BaselineRetestFailed -Reason improved
        $r.Switch | Should -BeTrue
        $r.Reason | Should -Be 'baseline-failed-on-retest'
    }
    It '类别更好时只要求候选不失败' {
        $r = Resolve-SwitchConfirmation -BaseTtfb 0.50 -BestTtfb 0.60 -BaselineClass 'waf' -CandidateClass 'ok' -Reason better-class
        $r.Switch | Should -BeTrue
        $r.Reason | Should -Be 'confirmed-class'
    }
    It '类别打平后不再沿用首次的 better-class' {
        $r = Resolve-SwitchConfirmation -BaseTtfb 0.30 -BestTtfb 0.80 -BaselineClass 'ok' -CandidateClass 'ok' -Reason better-class
        $r.Switch | Should -BeFalse
    }
    It 'baseline-no-ttfb 复测恢复正常后按门槛判断' {
        # 首次基线没有 TTFB，复测基线 300ms、候选 800ms：不应切换
        $r = Resolve-SwitchConfirmation -BaseTtfb 0 -BaseSamples @(0.30) -BestTtfb 0.80 -CandidateSamples @(0.80) -Reason baseline-no-ttfb
        $r.Switch | Should -BeFalse
    }
    It '绝对毫秒门槛拦下快基线的小改善' {
        # 基线 80ms、候选 66ms：17.5% 达到百分比门槛，但只差 14ms
        $r = Resolve-SwitchConfirmation -BaseTtfb 0.080 -BestTtfb 0.066 -Reason improved -MinImprovementPct 15 -MinImprovementMs 30
        $r.Switch | Should -BeFalse
    }
    It '接受 baseline-failed，不因参数校验中止' {
        $r = Resolve-SwitchConfirmation -BaseTtfb 0.50 -BestTtfb 0.20 -Reason baseline-failed
        $r.Switch | Should -BeTrue
        $r.Reason | Should -Be 'confirmed'
    }
}

Describe 'Find-Cfst' {
    It '显式目录时找里面的 cfst.exe' {
        $dir = Join-Path $TestDrive 'cfst-dir'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $exe = Join-Path $dir 'cfst.exe'
        [IO.File]::WriteAllText($exe, '')
        (Find-Cfst -Explicit $dir -Root $TestDrive) | Should -Be (Resolve-Path -LiteralPath $exe).Path
    }
    It '显式文件不存在时报错' {
        { Find-Cfst -Explicit (Join-Path $TestDrive 'nope\cfst.exe') -Root $TestDrive } |
            Should -Throw '*不存在*'
    }
    It '未指定时在 Root\cfst 下查找' {
        $root = Join-Path $TestDrive 'root'
        $dir = Join-Path $root 'cfst'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $exe = Join-Path $dir 'cfst.exe'
        [IO.File]::WriteAllText($exe, '')
        (Find-Cfst -Root $root) | Should -Be (Resolve-Path -LiteralPath $exe).Path
    }
}

Describe 'Test-BypassStrict' {
    It '精确匹配与通配符' {
        Test-BypassStrict -Domain 'a.example.com' -Bypass 'a.example.com' | Should -BeTrue
        Test-BypassStrict -Domain 'b.example.com' -Bypass '*.example.com' | Should -BeTrue
        Test-BypassStrict -Domain 'example.net' -Bypass '*.example.com' | Should -BeFalse
    }
    It '支持以点开头的写法' {
        Test-BypassStrict -Domain 'example.com' -Bypass '.example.com' | Should -BeTrue
        Test-BypassStrict -Domain 'www.example.com' -Bypass '.example.com' | Should -BeTrue
    }
    It '忽略端口和 <local>' {
        Test-BypassStrict -Domain 'a.example.com' -Bypass 'a.example.com:443;<local>' | Should -BeTrue
    }
}

Describe 'Get-DomainAction' {
    It 'DNS 候选胜出时 release' {
        $dec = [pscustomobject]@{ IP = '2.2.2.2'; Changed = $true }
        Get-DomainAction -Decision $dec -BaselineFromBlock $true -ChosenSource 'dns' `
            -Baseline ([pscustomobject]@{ Class = 'restricted'; Ok = $false }) | Should -Be 'release'
    }
    It '有改善且非 DNS 时 update' {
        $dec = [pscustomobject]@{ IP = '2.2.2.2'; Changed = $true }
        Get-DomainAction -Decision $dec -BaselineFromBlock $true -ChosenSource 'global' `
            -Baseline ([pscustomobject]@{ Class = 'ok'; Ok = $true }) | Should -Be 'update'
    }
    It '保留基线时按来源返回 keep 或 dns' {
        $dec = [pscustomobject]@{ IP = '1.1.1.1'; Changed = $false }
        Get-DomainAction -Decision $dec -BaselineFromBlock $true -ChosenSource '' `
            -Baseline ([pscustomobject]@{ Class = 'ok'; Ok = $true }) | Should -Be 'keep'
        Get-DomainAction -Decision $dec -BaselineFromBlock $false -ChosenSource '' `
            -Baseline ([pscustomobject]@{ Class = 'ok'; Ok = $true }) | Should -Be 'dns'
    }
    It '没有决策且旧映射受限时 drop' {
        $dec = [pscustomobject]@{ IP = $null; Changed = $false }
        Get-DomainAction -Decision $dec -BaselineFromBlock $true -ChosenSource '' `
            -Baseline ([pscustomobject]@{ Class = 'restricted'; Ok = $false }) | Should -Be 'drop'
    }
    It '没有决策时健康基线不因 DropUnreachable 删除' {
        $dec = [pscustomobject]@{ IP = $null; Changed = $false }
        Get-DomainAction -Decision $dec -BaselineFromBlock $true -ChosenSource '' `
            -Baseline ([pscustomobject]@{ Class = 'ok'; Ok = $true }) -DropUnreachable | Should -Be 'keep'
    }
    It '没有旧映射时 none' {
        $dec = [pscustomobject]@{ IP = $null; Changed = $false }
        Get-DomainAction -Decision $dec -BaselineFromBlock $false -ChosenSource '' `
            -Baseline ([pscustomobject]@{ Class = 'bad'; Ok = $false }) | Should -Be 'none'
    }
}

Describe 'Resolve-ConfirmedDecision' {
    It '确认切换时选择候选' {
        $c = [pscustomobject]@{ Switch = $true; Reason = 'confirmed'; Pct = 25 }
        $b = [pscustomobject]@{ IP = '2.2.2.2'; Ttfb = 0.2 }
        $d = Resolve-ConfirmedDecision -Confirm $c -Best $b -BaselineIP '1.1.1.1'
        $d.IP | Should -Be '2.2.2.2'
        $d.Changed | Should -BeTrue
        $d.Reason | Should -Be 'confirmed'
    }
    It '未确认时回到基线' {
        $c = [pscustomobject]@{ Switch = $false; Reason = 'not-confirmed'; Pct = 8 }
        $b = [pscustomobject]@{ IP = '2.2.2.2'; Ttfb = 0.2 }
        $d = Resolve-ConfirmedDecision -Confirm $c -Best $b -BaselineIP '1.1.1.1'
        $d.IP | Should -Be '1.1.1.1'
        $d.Changed | Should -BeFalse
        $d.BestIP | Should -Be '2.2.2.2'
    }
}

Describe 'New-PlanDocument' {
    It '输出计划条目和告警' {
        $dec = @([pscustomobject]@{ Domain = 'a.example'; Action = 'update' })
        $fm = [ordered]@{ 'a.example' = @('1.2.3.4') }
        $w = @([pscustomobject]@{ Domain = 'b.example'; Line = 7; Ip = '9.9.9.9'; Kind = 'restored' })
        $p = New-PlanDocument -Version '0.0.0' -HostsPath 'hosts' -Decisions $dec -FinalMap $fm -Warnings $w -Changed $true
        $p.Changed | Should -BeTrue
        $p.Plan | Should -HaveCount 1
        $p.Plan[0].IP | Should -Be '1.2.3.4'
        $p.Warnings[0].Kind | Should -Be 'restored'
        ($p | ConvertTo-Json -Depth 6) | Should -Match 'a.example'
    }
    It '没有映射时计划为空' {
        $p = New-PlanDocument -Version '0.0.0' -HostsPath 'hosts' -Decisions @() -FinalMap ([ordered]@{}) -Warnings @() -Changed $false
        $p.Plan | Should -HaveCount 0
        $p.Changed | Should -BeFalse
    }
}

Describe '机房缓存' {
    It '写入后可以读回，去重并排序' {
        $path = Join-Path $TestDrive 'colo-cache.json'
        Write-ColoCache -Path $path -Colos @('SJC', 'LAX', 'SJC', '', 'HKG') | Should -BeTrue
        $c = Read-ColoCache -Path $path
        $c.Colos | Should -Be @('HKG', 'LAX', 'SJC')
    }

    It '过期缓存返回空' {
        $path = Join-Path $TestDrive 'colo-old.json'
        Write-ColoCache -Path $path -Colos @('SJC') | Out-Null
        $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $doc.updatedAt = '2020-01-01T00:00:00Z'
        $doc | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
        Read-ColoCache -Path $path -MaxAgeDays 14 | Should -BeNullOrEmpty
        Read-ColoCache -Path $path -MaxAgeDays 0 | Should -BeNullOrEmpty
    }

    It '损坏或版本不符的缓存当作没有缓存' {
        $bad = Join-Path $TestDrive 'colo-bad.json'
        Set-Content -LiteralPath $bad -Value '{not json' -Encoding utf8
        Read-ColoCache -Path $bad | Should -BeNullOrEmpty

        $v2 = Join-Path $TestDrive 'colo-v2.json'
        (@{ version = 2; updatedAt = (Get-Date).ToString('o'); colos = @('SJC') } | ConvertTo-Json) |
            Set-Content -LiteralPath $v2 -Encoding utf8
        Read-ColoCache -Path $v2 | Should -BeNullOrEmpty

        Read-ColoCache -Path (Join-Path $TestDrive 'nope.json') | Should -BeNullOrEmpty
    }

    It '空区域列表不写缓存' {
        $path = Join-Path $TestDrive 'colo-empty.json'
        Write-ColoCache -Path $path -Colos @('', 'xx') | Should -BeFalse
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It '区域覆盖判断' {
        $rows = @(
            [pscustomobject]@{ Colo = 'SJC' }
            [pscustomobject]@{ Colo = 'SJC' }
            [pscustomobject]@{ Colo = 'LAX' }
            [pscustomobject]@{ Colo = 'LAX' }
        )
        Test-ColoCoverage -Rows $rows -Colos @('SJC', 'LAX') | Should -BeTrue
        Test-ColoCoverage -Rows $rows -Colos @('SJC', 'HKG') | Should -BeFalse
        Test-ColoCoverage -Rows $rows -Colos @('SJC', 'LAX') -MinPerColo 3 | Should -BeFalse
        Test-ColoCoverage -Rows $rows -Colos @() | Should -BeFalse
        Test-ColoCoverage -Rows $rows -Colos @('') | Should -BeFalse
    }

    It '只缓存有样本量的区域，并限制数量' {
        $c = @(
            [pscustomobject]@{ Colo = 'SJC' }
            [pscustomobject]@{ Colo = 'SJC' }
            [pscustomobject]@{ Colo = 'SJC' }
            [pscustomobject]@{ Colo = 'FRA' }   # 只出现一次 → 不缓存
            [pscustomobject]@{ Colo = '' }      # 未识别 → 不缓存
            [pscustomobject]@{ Colo = 'LAX' }
            [pscustomobject]@{ Colo = 'LAX' }
            [pscustomobject]@{ Colo = 'HKG' }
            [pscustomobject]@{ Colo = 'HKG' }
        )
        Get-CachableColos -Candidates $c | Should -Be @('SJC', 'HKG', 'LAX')
        Get-CachableColos -Candidates $c -Max 2 | Should -Be @('SJC', 'HKG')
        Get-CachableColos -Candidates $c -MinCount 3 | Should -Be @('SJC')
        Get-CachableColos -Candidates @() | Should -BeNullOrEmpty
    }

    It '默认缓存路径在本地应用数据目录' {
        (Get-ColoCacheDefaultPath -Root $TestDrive) | Should -Match 'colo-cache\.json$'
    }
}

Describe 'Resolve-Colo 提前结束' {
    BeforeAll {
        # 假 curl：固定返回 SJC，用来验证提前结束和区域变化两条路径
        $script:FakeCurl = Join-Path $TestDrive 'fake-curl.cmd'
        "@echo off`r`necho colo=SJC`r`n" | Set-Content -LiteralPath $script:FakeCurl -Encoding ascii
        $script:Candidates = @(1..8 | ForEach-Object {
                [pscustomobject]@{ IP = "192.0.2.$_"; Loss = 0.0; Ttfb = 0.1 }
            })
    }

    It '覆盖缓存区域后提前结束' {
        $rows = @(Resolve-Colo -CurlExe $script:FakeCurl -Candidates $script:Candidates `
                -EarlyStopColos @('SJC') -EarlyStopMinProbe 4 -ChunkSize 4)
        $rows.Count | Should -Be 4
        $rows[0].Colo | Should -Be 'SJC'
    }

    It '缓存区域没有出现时继续全量探测' {
        $rows = @(Resolve-Colo -CurlExe $script:FakeCurl -Candidates $script:Candidates `
                -EarlyStopColos @('HKG') -EarlyStopMinProbe 4 -ChunkSize 4)
        $rows.Count | Should -Be 8
    }

    It '没有缓存时不提前结束' {
        $rows = @(Resolve-Colo -CurlExe $script:FakeCurl -Candidates $script:Candidates -ChunkSize 4)
        $rows.Count | Should -Be 8
    }
}

Describe 'Get-ReasonText / Get-ActionText' {
    It '把内部代码翻译成中文' {
        Get-ReasonText -Reason 'below-threshold' | Should -Be '未达阈值'
        Get-ReasonText -Reason 'confirmed' | Should -Be '复核确认'
        Get-ReasonText -Reason 'baseline-is-best' | Should -Be '基线已最优'
        Get-ActionText -Action 'keep-unreachable' | Should -Be '保留（未验证）'
        Get-ActionText -Action 'release' | Should -Be '交还 DNS'
    }

    It '未知代码原样返回' {
        Get-ReasonText -Reason 'something-new' | Should -Be 'something-new'
        Get-ActionText -Action '' | Should -Be ''
    }
}

Describe 'Get-DomainProbeClass' {
    It '2xx/3xx/401 是 ok' {
        foreach ($h in @('200', '204', '301', '302', '303', '307', '308', '401')) {
            Get-DomainProbeClass -HeadHttp $h | Should -Be 'ok'
        }
    }

    It 'HEAD 403 + 诊断超时 -> unverified' {
        Get-DomainProbeClass -HeadHttp 403 -DiagExit 28 -DiagHttp '000' | Should -Be 'unverified'
    }

    It 'HEAD 403 + 空 body -> unverified' {
        Get-DomainProbeClass -HeadHttp 403 -DiagExit 0 -DiagHttp 403 -Body '' | Should -Be 'unverified'
    }

    It 'HEAD 403 + 1034 body -> restricted' {
        Get-DomainProbeClass -HeadHttp 403 -DiagExit 0 -DiagHttp 403 -Body 'error code: 1034' | Should -Be 'restricted'
    }

    It 'HEAD 403 + 普通页 -> waf' {
        Get-DomainProbeClass -HeadHttp 403 -DiagExit 0 -DiagHttp 403 -Body '<html>403 Forbidden</html>' | Should -Be 'waf'
    }

    It 'HEAD 503 + 非限制页 -> bad' {
        Get-DomainProbeClass -HeadHttp 503 -DiagExit 0 -DiagHttp 503 -Body '<html>503</html>' | Should -Be 'bad'
    }

    It 'HEAD 失败或 remote 不匹配 -> bad' {
        Get-DomainProbeClass -HeadExit 28 -HeadHttp '000' | Should -Be 'bad'
        Get-DomainProbeClass -HeadHttp 200 -RemoteOk $false | Should -Be 'bad'
    }
}

Describe 'Get-CfClassRank / 复核降级' {
    It '类别排序' {
        Get-CfClassRank -Class 'ok' | Should -Be 0
        Get-CfClassRank -Class 'waf' | Should -Be 1
        Get-CfClassRank -Class 'bad' | Should -Be 2
        Get-CfClassRank -Class 'unverified' | Should -Be 2
    }

    It '候选复核变差时拒绝切换' {
        $r = Resolve-SwitchConfirmation -BaseTtfb 0.5 -BestTtfb 0.2 -BaselineClass 'ok' -CandidateClass 'waf'
        $r.Switch | Should -BeFalse
        $r.Reason | Should -Be 'candidate-degraded'
    }

    It '基线复测失败时仍然切换' {
        (Resolve-SwitchConfirmation -BaseTtfb 0.5 -BestTtfb 0.5 -BaselineRetestFailed -BaselineClass 'bad' -CandidateClass 'waf').Switch | Should -BeTrue
    }

    It '候选类别更好时按原逻辑确认' {
        (Resolve-SwitchConfirmation -BaseTtfb 0.5 -BestTtfb 0.5 -BaselineClass 'waf' -CandidateClass 'ok' -Reason 'better-class').Switch | Should -BeTrue
    }
}
