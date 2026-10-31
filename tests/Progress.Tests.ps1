#Requires -Version 7.0
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib\Progress.ps1')
}

Describe 'Get-DisplayWidth' {
    It 'ASCII 按字符数算' {
        Get-DisplayWidth -Text '| 96/256' | Should -Be 8
    }

    It '中文按 2 列算' {
        Get-DisplayWidth -Text '探测' | Should -Be 4
        Get-DisplayWidth -Text '| 探测' | Should -Be 6
    }

    It '空字符串是 0' {
        Get-DisplayWidth -Text '' | Should -Be 0
    }

    It '中英混排' {
        Get-DisplayWidth -Text '逐域名验证 1/18 example.com' | Should -Be (10 + 1 + 4 + 1 + 11)
    }
}

Describe 'Format-TaskSpinnerText' {
    It '只有标签' {
        Format-TaskSpinnerText -Label '延迟筛选' | Should -Be '延迟筛选'
    }

    It '标签和详情用间隔点连接' {
        Format-TaskSpinnerText -Label '探测落地区域' -Detail '96/256 · 45s' | Should -Be '探测落地区域 · 96/256 · 45s'
    }

    It '没有标签时只返回详情' {
        Format-TaskSpinnerText -Detail '1/2' | Should -Be '1/2'
    }
}

Describe 'Format-Duration' {
    It '不到一分钟按秒显示' {
        Format-Duration -Duration ([TimeSpan]::FromSeconds(42)) | Should -Be '42 秒'
    }

    It '超过一分钟按分秒显示' {
        Format-Duration -Duration ([TimeSpan]::FromSeconds(83)) | Should -Be '1 分 23 秒'
    }

    It '整分钟也带秒' {
        Format-Duration -Duration ([TimeSpan]::FromSeconds(120)) | Should -Be '2 分 0 秒'
    }
}

Describe '动画状态' {
    It '默认没有动画' {
        Test-TaskSpinnerActive | Should -BeFalse
    }

    It '未启动时 Stop 不报错' {
        { Stop-TaskSpinner } | Should -Not -Throw
        Test-TaskSpinnerActive | Should -BeFalse
    }

    It '未启动时 Update 是空操作' {
        { Update-TaskSpinner -Detail '1/2' } | Should -Not -Throw
    }
}
