#Requires -Version 7.0
<#
    Update-HostsFile 的离线测试。

    这个函数不依赖网络，也不碰真实 hosts。测试用 AST 从主脚本里提取函数定义，
    避免执行整个脚本（主流程会扫描网络、可能修改 system hosts）。
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path $repoRoot 'pt-cf-optimize.ps1'

    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "pt-cf-optimize.ps1 存在语法错误，无法测试"
    }

    $fn = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Update-HostsFile'
        }, $true)[0]
    if (-not $fn) { throw '未找到 Update-HostsFile 函数' }
    Invoke-Expression $fn.Extent.Text

    $script:BeginMarker = '# >>> pt-cf-optimize BEGIN (auto-generated; -Rollback to undo) >>>'
    $script:EndMarker = '# <<< pt-cf-optimize END <<<'
    $script:LegacyTag = '# [pt-cf-optimize] '
    $script:AllDomains = @('cf.example.net', 'example.org')

    function New-HostsFixture {
        param([string]$Path)
        $lines = @(
            '127.0.0.1 localhost'
            '0.0.0.0 ads.example.com'
            ''
            '# user entries'
            '203.0.113.10 cf.example.net'
            '203.0.113.11 example.org'
        )
        [IO.File]::WriteAllText($Path, (($lines -join "`r`n") + "`r`n"), [Text.ASCIIEncoding]::new())
    }
}

Describe 'Update-HostsFile' {
    BeforeEach {
        $script:tmp = Join-Path $TestDrive ('hosts-' + [guid]::NewGuid().ToString('N') + '.txt')
        New-HostsFixture -Path $script:tmp
        $script:map = @{ 'cf.example.net' = @('10.0.0.1'); 'example.org' = @('10.0.0.2') }
        Update-HostsFile -Path $script:tmp -Map $script:map -AllDomains $script:AllDomains
        $script:text = Get-Content -LiteralPath $script:tmp -Raw
    }

    It '保留所有非管理行' {
        $script:text | Should -Match '127\.0\.0\.1 localhost'
        $script:text | Should -Match '0\.0\.0\.0 ads\.example\.com'
        ([regex]::Matches($script:text, 'ads\.example\.com')).Count | Should -Be 1
        $script:text | Should -Match '# user entries'
    }

    It '注释管理域的旧条目而不是删除' {
        $script:text | Should -Match ([regex]::Escape('# [pt-cf-optimize] 203.0.113.10 cf.example.net'))
        $script:text | Should -Match ([regex]::Escape('# [pt-cf-optimize] 203.0.113.11 example.org'))
    }

    It '写入标记区块和新的 IP' {
        $script:text | Should -Match ([regex]::Escape($script:BeginMarker))
        $script:text | Should -Match ([regex]::Escape($script:EndMarker))
        $script:text | Should -Match "10\.0\.0\.1`tcf\.example\.net"
        $script:text | Should -Match "10\.0\.0\.2`texample\.org"
    }

    It '标记区块只出现一次' {
        ([regex]::Matches($script:text, [regex]::Escape($script:BeginMarker))).Count | Should -Be 1
        ([regex]::Matches($script:text, [regex]::Escape($script:EndMarker))).Count | Should -Be 1
    }

    It '重复运行是幂等的' {
        $h1 = (Get-FileHash -LiteralPath $script:tmp -Algorithm SHA256).Hash
        Update-HostsFile -Path $script:tmp -Map $script:map -AllDomains $script:AllDomains
        $h2 = (Get-FileHash -LiteralPath $script:tmp -Algorithm SHA256).Hash
        $h2 | Should -Be $h1
    }

    It '缩小管理范围时还原旧条目' {
        Update-HostsFile -Path $script:tmp -Map @{ 'cf.example.net' = @('10.0.0.9') } -AllDomains $script:AllDomains
        $t2 = Get-Content -LiteralPath $script:tmp -Raw

        $t2 | Should -Match '(?m)^203\.0\.113\.11 example\.org'
        $t2 | Should -Not -Match '10\.0\.0\.2'
        $t2 | Should -Match "10\.0\.0\.9`tcf\.example\.net"
        $t2 | Should -Match ([regex]::Escape('# [pt-cf-optimize] 203.0.113.10 cf.example.net'))
    }

    It '保留原有的 CRLF 换行' {
        $bytes = [IO.File]::ReadAllBytes($script:tmp)
        $raw = [Text.Encoding]::ASCII.GetString($bytes)
        $raw | Should -Match "`r`n"
        ([regex]::Matches($raw, "(?<!`r)`n")).Count | Should -Be 0
    }
}
