#Requires -Version 7.0
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib\Probe.ps1')
    . (Join-Path $repoRoot 'lib\Endpoint.ps1')
}

Describe 'Split-ProbeUrl' {
    It '接受默认 trace 地址' {
        $r = Split-ProbeUrl -Url 'https://speed.cloudflare.com/cdn-cgi/trace'
        $r.Host | Should -Be 'speed.cloudflare.com'
        $r.Port | Should -Be 443
    }

    It '拒绝非 https、凭据、IP 字面量、非 443 端口、fragment' {
        { Split-ProbeUrl -Url 'http://speed.cloudflare.com/cdn-cgi/trace' } | Should -Throw '*https*'
        { Split-ProbeUrl -Url 'https://u:p@speed.cloudflare.com/x' } | Should -Throw '*凭据*'
        { Split-ProbeUrl -Url 'https://192.0.2.1/cdn-cgi/trace' } | Should -Throw '*IP*'
        { Split-ProbeUrl -Url 'https://speed.cloudflare.com:8443/x' } | Should -Throw '*443*'
        { Split-ProbeUrl -Url 'https://speed.cloudflare.com/x#frag' } | Should -Throw '*片段*'
    }

    It '拒绝不是 URL 的字符串' {
        { Split-ProbeUrl -Url 'not a url' } | Should -Throw
    }
}

Describe 'Get-TraceColo' {
    It '从多行响应里取 colo' {
        Get-TraceColo -Raw "fl=1`ncolo=hkg`nh=speed.cloudflare.com`n" | Should -Be 'HKG'
    }
    It '没有 colo 时返回空串' {
        Get-TraceColo -Raw "fl=1`nh=cloudflare.com" | Should -BeNullOrEmpty
    }
    It '行中间出现的 colo= 不算' {
        Get-TraceColo -Raw 'x=1 colo=HKG' | Should -BeNullOrEmpty
    }
}

Describe 'Test-DownloadResult' {
    It '95% 是边界' {
        (Test-DownloadResult -ExitCode 0 -Http 200 -Bytes 62260 -ExpectedBytes 65536).Ok | Should -BeTrue
        (Test-DownloadResult -ExitCode 0 -Http 200 -Bytes 62259 -ExpectedBytes 65536).Ok | Should -BeFalse
    }
    It '206 可用，302 不可用' {
        (Test-DownloadResult -ExitCode 0 -Http 206 -Bytes 65536 -ExpectedBytes 65536).Ok | Should -BeTrue
        (Test-DownloadResult -ExitCode 0 -Http 302 -Bytes 0 -ExpectedBytes 65536).Ok | Should -BeFalse
    }
    It '退出码非 0 直接失败' {
        $r = Test-DownloadResult -ExitCode 28 -Http 200 -Bytes 65536 -ExpectedBytes 65536
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match '28'
    }
}

Describe 'Select-ProbeEndpoint' {
    It '主端点可用时用主端点' {
        $p = [pscustomobject]@{ Url = 'https://a.example/trace'; Ok = $true; Detail = 'ok' }
        $f = [pscustomobject]@{ Url = 'https://b.example/trace'; Ok = $true; Detail = 'ok' }
        $r = Select-ProbeEndpoint -Primary $p -Fallback $f -AllowFallback
        $r.Url | Should -Be 'https://a.example/trace'
        $r.UsedFallback | Should -BeFalse
    }

    It '主端点失败且允许回退时用备用' {
        $p = [pscustomobject]@{ Url = 'https://a.example/trace'; Ok = $false; Detail = 'boom' }
        $f = [pscustomobject]@{ Url = 'https://b.example/trace'; Ok = $true; Detail = 'ok' }
        $r = Select-ProbeEndpoint -Primary $p -Fallback $f -AllowFallback
        $r.Url | Should -Be 'https://b.example/trace'
        $r.UsedFallback | Should -BeTrue
        $r.Ok | Should -BeTrue
    }

    It '不允许回退时报失败' {
        $p = [pscustomobject]@{ Url = 'https://a.example/trace'; Ok = $false; Detail = 'boom' }
        $f = [pscustomobject]@{ Url = 'https://b.example/trace'; Ok = $true; Detail = 'ok' }
        $r = Select-ProbeEndpoint -Primary $p -Fallback $f
        $r.Ok | Should -BeFalse
        $r.UsedFallback | Should -BeFalse
        $r.Detail | Should -Be 'boom'
    }

    It '备用也失败时返回失败' {
        $p = [pscustomobject]@{ Url = 'https://a.example/trace'; Ok = $false; Detail = 'a' }
        $f = [pscustomobject]@{ Url = 'https://b.example/trace'; Ok = $false; Detail = 'b' }
        (Select-ProbeEndpoint -Primary $p -Fallback $f -AllowFallback).Ok | Should -BeFalse
    }
}

Describe 'Test-ProbeResponse' {
    It 'HTTP 200 且响应体含 colo 时成功' {
        $r = Test-ProbeResponse -ExitCode 0 -Http 200 -Raw "fl=1`ncolo=HKG`nh=x"
        $r.Ok | Should -BeTrue
        $r.Colo | Should -Be 'HKG'
    }

    It '响应里没有 colo 时失败' {
        $r = Test-ProbeResponse -ExitCode 0 -Http 200 -Raw 'h=speed.cloudflare.com'
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'colo'
    }

    It 'HTTP 403 时失败' {
        $r = Test-ProbeResponse -ExitCode 0 -Http 403 -Raw 'colo=HKG'
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match '403'
    }

    It 'curl 退出码非 0 时失败' {
        $r = Test-ProbeResponse -ExitCode 6 -Http 000 -Raw ''
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match '6'
    }
}

Describe 'Test-SpeedEndpoint' {
    It '没有 {bytes} 占位符时跳过预检，不调用 curl' {
        $r = Test-SpeedEndpoint -CurlExe 'C:\definitely\missing\curl.exe' `
            -UrlTemplate 'https://speed.cloudflare.com/fixed.bin'
        $r.Ok | Should -BeTrue
        $r.Skipped | Should -BeTrue
    }
}

Describe 'Resolve-ProbeEndpoint 输入校验' {
    It '非法 URL 在发请求前就报错' {
        { Resolve-ProbeEndpoint -CurlExe 'C:\definitely\missing\curl.exe' -PrimaryUrl 'http://x.example/trace' } | Should -Throw '*https*'
    }
}
