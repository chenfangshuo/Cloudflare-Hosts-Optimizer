#Requires -Version 7.0
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib\Safety.ps1')
    . (Join-Path $repoRoot 'lib\Domains.ps1')
}

Describe 'ConvertTo-NormalizedDomain' {
    It '去掉 scheme、端口、路径' {
        ConvertTo-NormalizedDomain -Value 'https://WWW.Example.COM:8443/a/b?x=1' | Should -Be 'www.example.com'
    }

    It '接受带尾点的裸域名' {
        ConvertTo-NormalizedDomain -Value 'example.com.' | Should -Be 'example.com'
    }

    It '转换 IDN 为 Punycode' {
        $r = ConvertTo-NormalizedDomain -Value '例子.测试'
        $r | Should -Match '^xn--'
    }

    It '拒绝 IP 字面量' {
        ConvertTo-NormalizedDomain -Value '1.2.3.4' | Should -BeNullOrEmpty
    }

    It '拒绝单标签' {
        ConvertTo-NormalizedDomain -Value 'localhost' | Should -BeNullOrEmpty
    }

    It '严格模式拒绝 URL / 端口 / 路径' {
        ConvertTo-NormalizedDomain -Value 'https://example.com/a' -Strict | Should -BeNullOrEmpty
        ConvertTo-NormalizedDomain -Value 'example.com:443' -Strict | Should -BeNullOrEmpty
        ConvertTo-NormalizedDomain -Value 'example.com/a' -Strict | Should -BeNullOrEmpty
        ConvertTo-NormalizedDomain -Value 'user@example.com' -Strict | Should -BeNullOrEmpty
    }

    It '严格模式接受普通域名' {
        ConvertTo-NormalizedDomain -Value 'www.Example.com' -Strict | Should -Be 'www.example.com'
    }
}

Describe 'Read-DomainsFile' {
    It '跳过注释和空行，去重，并报告非法项' {
        $tmp = Join-Path $TestDrive 'domains.txt'
        $text = "# comment`r`n`r`nexample.com`r`nhttps://bad.example/a`r`nwww.example.com`r`nexample.com`r`n"
        [IO.File]::WriteAllText($tmp, $text, [Text.UTF8Encoding]::new($false))
        $r = Read-DomainsFile -Path $tmp
        $r.Domains | Should -HaveCount 2
        $r.Domains | Should -Contain 'example.com'
        $r.Invalid | Should -HaveCount 1
    }

    It '文件不存在时返回空' {
        $r = Read-DomainsFile -Path (Join-Path $TestDrive 'nope.txt')
        $r.Domains | Should -HaveCount 0
        $r.Invalid | Should -HaveCount 0
    }
}

Describe 'Merge-DomainLists' {
    It '去重并报告新增' {
        $m = Merge-DomainLists -Existing @('a.example', 'b.example') -New @('b.example', 'c.example')
        $m.Domains | Should -HaveCount 3
        $m.Added | Should -Contain 'c.example'
        $m.Added | Should -Not -Contain 'b.example'
    }
}
