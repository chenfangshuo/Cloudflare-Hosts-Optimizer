#Requires -Version 7.0
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib\Safety.ps1')
    . (Join-Path $repoRoot 'lib\Domains.ps1')
    . (Join-Path $repoRoot 'lib\Import.ps1')
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    function New-TestZip {
        param([string]$Path, [switch]$NoMetadata, [switch]$BadMetadata, [switch]$DuplicateMetadata)

        $zip = [IO.Compression.ZipFile]::Open($Path, 'Create')
        try {
            if (-not $NoMetadata) {
                if ($BadMetadata) {
                    $meta = '%%%not json%%%'
                } else {
                    $meta = [ordered]@{
                        sites       = [ordered]@{
                            siteA = [ordered]@{ url = 'https://a.example/'; isOffline = $false }
                            siteB = [ordered]@{ url = 'https://b.example/'; isOffline = $true }
                        }
                        siteHostMap = [ordered]@{
                            'cdn.a.example' = 'siteA'
                            'alt.b.example' = 'siteB'
                        }
                    } | ConvertTo-Json -Depth 6
                }
                $e = $zip.CreateEntry('metadata.json')
                $w = [IO.StreamWriter]::new($e.Open())
                try { $w.Write($meta) } finally { $w.Dispose() }

                if ($DuplicateMetadata) {
                    $e2 = $zip.CreateEntry('metadata.json')
                    $w2 = [IO.StreamWriter]::new($e2.Open())
                    try { $w2.Write('{}') } finally { $w2.Dispose() }
                }
            }
            # 故意放入非法 JSON 和 canary：导入器不应读取它们
            foreach ($pair in @(@('cookies.json', '%%%not json%%%'), @('userInfo.json', 'SECRET_CANARY'))) {
                $e = $zip.CreateEntry($pair[0])
                $w = [IO.StreamWriter]::new($e.Open())
                try { $w.Write($pair[1]) } finally { $w.Dispose() }
            }
        } finally { $zip.Dispose() }
    }
}

Describe 'Get-DepilerDomains' {
    It '默认只取在线站点的 url' {
        $zip = Join-Path $TestDrive 'ptd1.zip'
        New-TestZip -Path $zip
        $r = Get-DepilerDomains -ZipPath $zip
        $r.Domains | Should -HaveCount 1
        $r.Domains | Should -Contain 'a.example'
        $r.Domains | Should -Not -Contain 'b.example'
    }

    It '包含离线站点' {
        $zip = Join-Path $TestDrive 'ptd2.zip'
        New-TestZip -Path $zip
        $r = Get-DepilerDomains -ZipPath $zip -WithOffline
        $r.Domains | Should -HaveCount 2
        $r.Domains | Should -Contain 'b.example'
    }

    It '包含备用主机名时跳过离线站点的备用域名' {
        $zip = Join-Path $TestDrive 'ptd3.zip'
        New-TestZip -Path $zip
        $r = Get-DepilerDomains -ZipPath $zip -WithAlternates
        $r.Domains | Should -HaveCount 2
        $r.Domains | Should -Contain 'cdn.a.example'
        $r.Domains | Should -Not -Contain 'alt.b.example'
    }

    It '离线 + 备用全量' {
        $zip = Join-Path $TestDrive 'ptd4.zip'
        New-TestZip -Path $zip
        $r = Get-DepilerDomains -ZipPath $zip -WithAlternates -WithOffline
        $r.Domains | Should -HaveCount 4
    }

    It '重复 metadata.json 时报错' {
        $zip = Join-Path $TestDrive 'ptd-dup.zip'
        New-TestZip -Path $zip -DuplicateMetadata
        { Get-DepilerDomains -ZipPath $zip } | Should -Throw '*多个同名*'
    }

    It '缺少 metadata.json 时报错' {
        $zip = Join-Path $TestDrive 'ptd5.zip'
        New-TestZip -Path $zip -NoMetadata
        { Get-DepilerDomains -ZipPath $zip } | Should -Throw '*metadata.json*'
    }

    It 'metadata.json 非明文时报错' {
        $zip = Join-Path $TestDrive 'ptd6.zip'
        New-TestZip -Path $zip -BadMetadata
        { Get-DepilerDomains -ZipPath $zip } | Should -Throw '*明文 JSON*'
    }
}

Describe 'Get-TextDomains' {
    It '提取 URL 和裸主机名，不把路径当域名' {
        $text = @'
https://a.example/index.php
b.example and c.example:8443/x
user@d.example
'@
        $r = Get-TextDomains -Text $text
        $r.Domains | Should -Contain 'a.example'
        $r.Domains | Should -Contain 'b.example'
        $r.Domains | Should -Contain 'c.example'
        $r.Domains | Should -Not -Contain 'index.php'
        $r.Domains | Should -Not -Contain 'd.example'
    }
}

Describe 'Merge-IntoDomainsFile' {
    It '只追加新增域名，幂等，并备份' {
        $target = Join-Path $TestDrive 'domains-merge.txt'
        [IO.File]::WriteAllText($target, "# existing`r`nexample.com`r`n", [Text.UTF8Encoding]::new($false))

        $m1 = Merge-IntoDomainsFile -Target $target -NewDomains @('a.example', 'example.com') -SourceName 'test'
        $m1.Added | Should -Be 1
        (Get-Content $target -Raw) | Should -Match 'a\.example'

        $m2 = Merge-IntoDomainsFile -Target $target -NewDomains @('a.example') -SourceName 'test'
        $m2.Added | Should -Be 0

        @(Get-ChildItem $TestDrive -Filter 'domains-merge.txt.bak-*').Count | Should -Be 1
    }
}

Describe 'Write-DomainsFile' {
    It '写入带说明的文件' {
        $out = Join-Path $TestDrive 'out.txt'
        Write-DomainsFile -FilePath $out -SourceName 'test' -Domains @('a.example') -Note 'note'
        (Get-Content $out -Raw) | Should -Match '# 来源: test'
        (Get-Content $out -Raw) | Should -Match '(?m)^a\.example\r?$'
    }
}
