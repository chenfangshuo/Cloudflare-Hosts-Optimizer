#Requires -Version 7.0
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib\Safety.ps1')
}

Describe 'Get-NormalizedPath' {
    It '解析相对路径并去掉末尾分隔符' {
        Push-Location $TestDrive
        try {
            (Get-NormalizedPath -Path '.\sub\') | Should -Be (Get-NormalizedPath -Path (Join-Path $TestDrive 'sub'))
        } finally { Pop-Location }
    }

    It '不把 C:\ 变成 C:' {
        Get-NormalizedPath -Path 'C:\' | Should -Be 'c:\'
    }

    It '大小写归一' {
        Get-NormalizedPath -Path 'C:\Temp\A.TXT' | Should -Be (Get-NormalizedPath -Path 'c:\temp\a.txt')
    }
}

Describe 'Test-SamePath / Test-SystemHostsPath' {
    It '相对路径、大小写、末尾分隔符视为同一路径' {
        Push-Location $TestDrive
        try {
            (Test-SamePath -Left '.\sub\' -Right (Join-Path $TestDrive 'SUB')) | Should -BeTrue
        } finally { Pop-Location }
    }

    It '不同的文件不是同一路径' {
        Test-SamePath -Left (Join-Path $TestDrive 'a') -Right (Join-Path $TestDrive 'b') | Should -BeFalse
    }

    It '系统 hosts 路径识别为系统目标' {
        Test-SystemHostsPath -Path (Get-SystemHostsPath) | Should -BeTrue
    }

    It '沙箱临时文件不是系统 hosts' {
        $p = Join-Path $TestDrive 'sandbox-hosts'
        Set-Content -LiteralPath $p -Value 'x'
        Test-SystemHostsPath -Path $p | Should -BeFalse
    }

    It '指向系统 hosts 的硬链接仍按系统目标处理' {
        $system = Get-SystemHostsPath
        if (-not (Test-Path -LiteralPath $system)) { Set-ItResult -Skipped -Because '本机没有系统 hosts'; return }
        $link = Join-Path $TestDrive 'system-hosts-link'
        try {
            New-Item -ItemType HardLink -Path $link -Target $system -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Skipped -Because '无法创建硬链接（权限或文件系统限制）'; return
        }
        Test-SystemHostsPath -Path $link | Should -BeTrue
    }
}

Describe 'Get-OutputPathConflicts' {
    It '两个输出相同时返回冲突' {
        $p = Join-Path $TestDrive 'same-report.txt'
        @(Get-OutputPathConflicts -Outputs @($p, $p)).Count | Should -BeGreaterThan 0
    }

    It '输出与输入相同时返回冲突' {
        $p = Join-Path $TestDrive 'hosts-input'
        Set-Content -LiteralPath $p -Value 'x'
        @(Get-OutputPathConflicts -Outputs @($p) -InputPaths @($p)).Count | Should -BeGreaterThan 0
    }

    It '互不相同的输出和输入没有冲突' {
        $out = Join-Path $TestDrive 'report.txt'
        $in = Join-Path $TestDrive 'hosts'
        Set-Content -LiteralPath $in -Value 'x'
        @(Get-OutputPathConflicts -Outputs @($out) -InputPaths @($in)).Count | Should -Be 0
    }
}

Describe 'Test-PathCollision' {
    It '同一个文件不同大小写视为碰撞' {
        $p = Join-Path $TestDrive 'Hosts'
        Set-Content -LiteralPath $p -Value 'x'
        $r = Test-PathCollision -Left $p -Right $p.ToUpperInvariant()
        $r.Collision | Should -BeTrue
    }

    It '相对路径与绝对路径指向同一文件时视为碰撞' {
        Push-Location $TestDrive
        try {
            Set-Content -LiteralPath (Join-Path $TestDrive 'h') -Value 'x'
            (Test-PathCollision -Left 'h' -Right (Join-Path $TestDrive 'h')).Collision | Should -BeTrue
        } finally { Pop-Location }
    }

    It '硬链接视为同一文件（卷标识 + 文件 ID）' {
        $a = Join-Path $TestDrive 'orig.txt'
        $b = Join-Path $TestDrive 'alias.txt'
        Set-Content -LiteralPath $a -Value 'x'
        New-Item -ItemType HardLink -Path $b -Target $a | Out-Null
        $r = Test-PathCollision -Left $a -Right $b
        $r.Collision | Should -BeTrue
        $r.Uncertain | Should -BeFalse
    }

    It '两个不同的文件不碰撞' {
        $a = Join-Path $TestDrive 'a.txt'
        $b = Join-Path $TestDrive 'b.txt'
        Set-Content -LiteralPath $a -Value 'x'
        Set-Content -LiteralPath $b -Value 'y'
        (Test-PathCollision -Left $a -Right $b).Collision | Should -BeFalse
    }

    It '不存在的不同路径不碰撞' {
        (Test-PathCollision -Left (Join-Path $TestDrive 'no1') -Right (Join-Path $TestDrive 'no2')).Collision |
            Should -BeFalse
    }

    It '两个都不存在的同一路径视为碰撞' {
        $p = Join-Path $TestDrive 'future.txt'
        (Test-PathCollision -Left $p -Right $p).Collision | Should -BeTrue
    }
}

Describe 'Assert-OutputPathSafe' {
    It '输出与输入相同时拒绝' {
        $p = Join-Path $TestDrive 'hosts'
        Set-Content -LiteralPath $p -Value 'x'
        Assert-OutputPathSafe -Path $p -InputPaths @($p) | Should -Not -BeNullOrEmpty
    }

    It '两个输出指向同一文件时拒绝' {
        $p = Join-Path $TestDrive 'report.txt'
        Assert-OutputPathSafe -Path $p -InputPaths @() -OtherOutputs @($p) | Should -Not -BeNullOrEmpty
    }

    It '路径安全时返回空' {
        $out = Join-Path $TestDrive 'report.txt'
        $in = Join-Path $TestDrive 'hosts'
        Set-Content -LiteralPath $in -Value 'x'
        Assert-OutputPathSafe -Path $out -InputPaths @($in) | Should -BeNullOrEmpty
    }
}

Describe 'Get-SafeInputPreview' {
    It '合法域名原样返回' {
        Get-SafeInputPreview -Value 'www.example.com' | Should -Be 'www.example.com'
    }

    It '带 passkey 的 URL 只保留 scheme 和主机' {
        Get-SafeInputPreview -Value 'https://tracker.example.com/announce.php?passkey=SECRET' |
            Should -Be 'https://tracker.example.com'
    }

    It '带 userinfo 的 URL 不泄露用户信息' {
        $v = Get-SafeInputPreview -Value 'https://user:pw@example.com/a'
        $v | Should -Be 'https://example.com'
        $v | Should -Not -Match 'user|pw'
    }

    It '无 scheme 的凭据串整体隐藏' {
        Get-SafeInputPreview -Value 'passkey:abc@example.com' | Should -Be '<已隐藏>'
    }

    It '含控制字符时隐藏' {
        Get-SafeInputPreview -Value "example.com`tpasskey" | Should -Be '<已隐藏>'
    }

    It '带端口或路径的输入回退为隐藏，不截取原文' {
        Get-SafeInputPreview -Value 'example.com:8080/path' | Should -Be '<已隐藏>'
    }
}

Describe 'Protect-ErrorMessage' {
    It '去掉 URL 里的 userinfo' {
        $m = '请求失败：https://user:secret@example.com/a'
        $r = Protect-ErrorMessage -Text $m
        $r | Should -Not -Match 'secret'
        $r | Should -Match '<redacted>'
        $r | Should -Match '请求失败'
    }

    It '打码凭据类查询参数' {
        Protect-ErrorMessage -Text 'bad https://example.com/?passkey=FAKE123&x=1' |
            Should -Not -Match 'FAKE123'
    }

    It '保留普通 IO 错误的原因' {
        Protect-ErrorMessage -Text 'Access to the path C:\x is denied.' |
            Should -Be 'Access to the path C:\x is denied.'
    }

    It '去掉 NUL 等不可见控制字符，保留换行和制表' {
        (Protect-ErrorMessage -Text "a`0b") | Should -Be 'ab'
        (Protect-ErrorMessage -Text "a`tb") | Should -Be "a`tb"
    }
}

Describe 'C01 受保护输入始终包含系统 hosts' {
    It '即使指定了沙箱 -HostsPath，系统 hosts 仍在保护集合里' {
        $paths = @(Get-ProtectedInputPaths -HostsPath 'C:\tmp\sandbox-hosts' -DomainsFile 'C:\tmp\d.txt')
        $systemHosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        $paths | Should -Contain $systemHosts
        $paths | Should -Contain 'C:\tmp\sandbox-hosts'
        $paths | Should -Contain 'C:\tmp\d.txt'
    }

    It '报告指向系统 hosts 时会被拒绝' {
        $systemHosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        $inputs = @(Get-ProtectedInputPaths -HostsPath 'C:\tmp\sandbox-hosts' -DomainsFile 'C:\tmp\d.txt')
        Assert-OutputPathSafe -Path $systemHosts -InputPaths $inputs | Should -Not -BeNullOrEmpty
    }
}

Describe 'C07 输出之间按文件身份比较' {
    It '两个输出是同一个硬链接时拒绝' {
        $a = Join-Path $TestDrive 'out-a.txt'
        $b = Join-Path $TestDrive 'out-b.txt'
        Set-Content -LiteralPath $a -Value 'x'
        New-Item -ItemType HardLink -Path $b -Target $a | Out-Null
        Assert-OutputPathSafe -Path $a -InputPaths @() -OtherOutputs @($b) | Should -Not -BeNullOrEmpty
    }

    It '两个输出只是字符串相同也拒绝' {
        $p = Join-Path $TestDrive 'same.txt'
        Assert-OutputPathSafe -Path $p -InputPaths @() -OtherOutputs @($p) | Should -Not -BeNullOrEmpty
    }
}
