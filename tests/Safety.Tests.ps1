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
