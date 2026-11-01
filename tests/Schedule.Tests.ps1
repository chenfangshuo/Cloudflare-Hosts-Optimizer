#Requires -Version 7.0
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib\Schedule.ps1')
    $script:RepoRoot = $repoRoot
}

Describe 'Get-OptimizerPwshPath' {
    It '返回当前 pwsh 的路径' {
        (Get-OptimizerPwshPath) | Should -Match 'pwsh(-preview)?\.exe$'
    }
}

Describe 'Test-OptimizerTaskName' {
    It '接受中文、空格和短横线' {
        Test-OptimizerTaskName -TaskName 'Cloudflare-Hosts-Optimizer DryRun' | Should -Be ''
        Test-OptimizerTaskName -TaskName '优选 任务-1' | Should -Be ''
    }

    It '拒绝反斜杠、通配符和保留字符' {
        Test-OptimizerTaskName -TaskName 'a\b' | Should -Match '不能包含'
        Test-OptimizerTaskName -TaskName 'a*b' | Should -Match '不能包含'
        Test-OptimizerTaskName -TaskName 'a:b' | Should -Match '不能包含'
    }

    It '拒绝空名字' {
        Test-OptimizerTaskName -TaskName '   ' | Should -Match '不能为空'
    }
}

Describe 'New-OptimizerTaskSpec' {
    It 'DryRun 默认值' {
        $s = New-OptimizerTaskSpec -Root $script:RepoRoot
        $s.TaskName | Should -Be 'Cloudflare-Hosts-Optimizer DryRun'
        $s.Mode | Should -Be 'DryRun'
        $s.IntervalDays | Should -Be 14
        $s.At | Should -Be '10:00'
        $s.RequiresAdmin | Should -BeFalse
        $s.Arguments | Should -Match '-DryRun'
        $s.Arguments | Should -Match '-ReportPath'
        $s.Arguments | Should -Match 'last-report\.txt'
        $s.Execute | Should -Match 'pwsh(-preview)?\.exe$'
    }

    It 'AutoApply 默认值' {
        $s = New-OptimizerTaskSpec -Root $script:RepoRoot -Mode AutoApply
        $s.TaskName | Should -Be 'Cloudflare-Hosts-Optimizer AutoApply'
        $s.At | Should -Be '04:00'
        $s.RequiresAdmin | Should -BeTrue
        $s.Arguments | Should -Not -Match '-DryRun'
    }

    It '自定义任务名原样保留' {
        $s = New-OptimizerTaskSpec -Root $script:RepoRoot -TaskName '优选 任务-1'
        $s.TaskName | Should -Be '优选 任务-1'
    }

    It '非法任务名抛错' {
        { New-OptimizerTaskSpec -Root $script:RepoRoot -TaskName 'a\b' } | Should -Throw '*不能包含*'
    }

    It '非法时间抛错' {
        { New-OptimizerTaskSpec -Root $script:RepoRoot -At '25:00' } | Should -Throw
        { New-OptimizerTaskSpec -Root $script:RepoRoot -At '4am' } | Should -Throw
    }

    It '透传开关和值，按参数名排序' {
        $s = New-OptimizerTaskSpec -Root $script:RepoRoot -ExtraParameters @{
            NoCfst     = [System.Management.Automation.SwitchParameter]::new($true)
            TopN       = 2
            SpeedTestUrl = 'https://speed.cloudflare.com/__down?bytes={bytes}'
        }
        $s.Arguments | Should -Match '-NoCfst'
        # 不含空白/引号的参数不再强行加引号（0.5.6 起按 Windows 命令行规则序列化）
        $s.Arguments | Should -Match '-TopN 2'
        $s.Arguments | Should -Match '-SpeedTestUrl https://speed\.cloudflare\.com/__down\?bytes=\{bytes\}'
        # 排序：NoCfst 在 SpeedTestUrl 前，SpeedTestUrl 在 TopN 前
        $s.Arguments.IndexOf('-NoCfst') | Should -BeLessThan $s.Arguments.IndexOf('-SpeedTestUrl')
    }

    It '数组参数直接拒绝' {
        { New-OptimizerTaskSpec -Root $script:RepoRoot -ExtraParameters @{ Domains = @('a.com', 'b.com') } } |
            Should -Throw '*数组*'
    }

    It '脚本不存在时报错' {
        { New-OptimizerTaskSpec -Root (Join-Path $TestDrive 'no-such-root') } | Should -Throw '*找不到脚本*'
    }
}

Describe 'Install-OptimizerTask' {
    It '-WhatIf 不注册任务' {
        $name = 'Cloudflare-Hosts-Optimizer Pester ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $spec = New-OptimizerTaskSpec -Root $script:RepoRoot -TaskName $name
        $returned = Install-OptimizerTask -Spec $spec -WhatIf
        $returned.TaskName | Should -Be $name
        @(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It '-TaskForce 与 -WhatIf 可以一起用' {
        $spec = New-OptimizerTaskSpec -Root $script:RepoRoot
        { Install-OptimizerTask -Spec $spec -WhatIf -TaskForce } | Should -Not -Throw
    }
}

Describe 'Uninstall-OptimizerTask' {
    It '任务不存在时视为成功' {
        $rows = @(Uninstall-OptimizerTask -TaskName @('Cloudflare-Hosts-Optimizer Pester Missing') -WhatIf)
        $rows.Count | Should -Be 1
        $rows[0].Removed | Should -BeTrue
        $rows[0].Detail | Should -Match '不存在'
    }

    It '不传任务名时目标为两个默认任务' {
        $rows = @(Uninstall-OptimizerTask -WhatIf)
        @($rows.TaskName) | Should -Be @('Cloudflare-Hosts-Optimizer DryRun', 'Cloudflare-Hosts-Optimizer AutoApply')
    }
}

Describe 'F02 卸载只处理本工具的精确任务' {
    It '拒绝通配符任务名' {
        { Uninstall-OptimizerTask -TaskName '*' -WhatIf } | Should -Throw '*任务名无效*'
        { Uninstall-OptimizerTask -TaskName '?' -WhatIf } | Should -Throw '*任务名无效*'
    }

    It '数组里有一个非法名时不删除任何任务' {
        Mock Get-ScheduledTask { @() }
        Mock Remove-OptimizerTask { }
        { Uninstall-OptimizerTask -TaskName @('Valid Name', '*') -WhatIf } | Should -Throw
        Should -Invoke Remove-OptimizerTask -Times 0
    }

    It '同名但不是本工具注册的任务不会被删除' {
        Mock Get-ScheduledTask {
            [pscustomobject]@{
                TaskName = 'Cloudflare-Hosts-Optimizer DryRun'
                Actions  = @([pscustomobject]@{ Execute = 'C:\Windows\System32\notepad.exe'; Arguments = '' })
            }
        }
        Mock Remove-OptimizerTask { }
        $rows = @(Uninstall-OptimizerTask -TaskName 'Cloudflare-Hosts-Optimizer DryRun' -WhatIf)
        $rows[0].Removed | Should -BeFalse
        $rows[0].Detail | Should -Match '不是本工具'
        Should -Invoke Remove-OptimizerTask -Times 0
    }

    It '本工具注册的任务按对象删除，方括号按字面匹配' {
        $script:f02Task = [pscustomobject]@{
            TaskName = 'My [Special] Task'
            Actions  = @([pscustomobject]@{
                    Execute   = 'C:\Program Files\PowerShell\7\pwsh.exe'
                    Arguments = '-NoProfile -File D:\tools\Cloudflare-Hosts-Optimizer.ps1 -DryRun'
                })
        }
        Mock Get-ScheduledTask { $script:f02Task }
        Mock Remove-OptimizerTask { }
        # 不加 -WhatIf，让 ShouldProcess 返回 true；真正的删除命令已被 Mock 拦截
        $rows = @(Uninstall-OptimizerTask -TaskName 'My [Special] Task')
        $rows[0].Removed | Should -BeTrue
        $rows[0].Detail | Should -Be '已删除'
        Should -Invoke Remove-OptimizerTask -Times 1
    }
}

Describe 'F09 任务参数序列化' {
    It '不含空白和引号的参数原样输出' {
        ConvertTo-NativeArgument -Value '2' | Should -Be '2'
        ConvertTo-NativeArgument -Value 'D:\cfst\cfst.exe' | Should -Be 'D:\cfst\cfst.exe'
    }

    It '不含空白的尾反斜杠路径不需要引号（反斜杠只在引号内才需要翻倍）' {
        ConvertTo-NativeArgument -Value 'D:\cfst\' | Should -Be 'D:\cfst\'
    }

    It '含空格的尾反斜杠路径必须加引号并翻倍' {
        ConvertTo-NativeArgument -Value 'D:\my cfst\' | Should -Be '"D:\my cfst\\"'
    }

    It '含空白的参数加引号' {
        ConvertTo-NativeArgument -Value 'C:\a b\x.txt' | Should -Be '"C:\a b\x.txt"'
    }

    It '引号前的反斜杠按规则转义' {
        ConvertTo-NativeArgument -Value 'a\"b' | Should -Be '"a\\\"b"'
    }

    It '真实子进程往返：尾反斜杠与含空格路径不失真' {
        $echo = Join-Path $TestDrive 'echo-args.ps1'
        Set-Content -LiteralPath $echo -Encoding utf8 -Value 'param([string]$CfstPath,[string]$DomainsFile) Write-Output ($CfstPath + "|" + $DomainsFile)'
        $spec = New-OptimizerTaskSpec -Root $script:RepoRoot -ExtraParameters @{
            CfstPath    = 'D:\my cfst\'
            DomainsFile = 'C:\a b\d.txt'
        }
        $scriptPath = Join-Path $script:RepoRoot 'Cloudflare-Hosts-Optimizer.ps1'
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = (Get-Command pwsh).Source
        $psi.Arguments = $spec.Arguments.Replace(
            (ConvertTo-NativeArgument -Value $scriptPath),
            (ConvertTo-NativeArgument -Value $echo))
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        $out.Trim() | Should -Be 'D:\my cfst\|C:\a b\d.txt'
    }
}

Describe 'C08 任务归属只认实际 -File 目标' {
    BeforeAll {
        function New-TaskObj {
            param([string]$Arguments, [string]$Execute = 'C:\Program Files\PowerShell\7\pwsh.exe')
            return [pscustomobject]@{
                TaskName = 'x'
                Actions  = @([pscustomobject]@{ Execute = $Execute; Arguments = $Arguments })
            }
        }
        $script:TaskScript = Join-Path $script:RepoRoot 'Cloudflare-Hosts-Optimizer.ps1'
    }

    It '参数标签里出现本脚本名不算本工具任务' {
        $t = New-TaskObj -Arguments '-NoProfile -File "C:\OtherTool\Backup.ps1" -Label "Cloudflare-Hosts-Optimizer.ps1"'
        Test-OptimizerTaskOwnership -Task $t -ScriptPath $script:TaskScript | Should -BeFalse
    }

    It '-Command 里只是打印脚本名不算' {
        $t = New-TaskObj -Arguments '-NoProfile -Command "Write-Output Cloudflare-Hosts-Optimizer.ps1"'
        Test-OptimizerTaskOwnership -Task $t -ScriptPath $script:TaskScript | Should -BeFalse
    }

    It '非 pwsh 宿主不算' {
        $t = New-TaskObj -Arguments '-NoProfile -File "D:\x\Cloudflare-Hosts-Optimizer.ps1"' -Execute 'C:\Windows\System32\notepad.exe'
        Test-OptimizerTaskOwnership -Task $t -ScriptPath $script:TaskScript | Should -BeFalse
    }

    It '真正 -File 指向本脚本才算（允许目录搬迁）' {
        $t = New-TaskObj -Arguments '-NoProfile -ExecutionPolicy Bypass -File "D:\moved\Cloudflare-Hosts-Optimizer.ps1" -DryRun'
        Test-OptimizerTaskOwnership -Task $t -ScriptPath $script:TaskScript | Should -BeTrue
    }
}

Describe 'D03 入口模式按宿主参数识别' {
    BeforeAll {
        $script:TaskScript2 = Join-Path $script:RepoRoot 'Cloudflare-Hosts-Optimizer.ps1'
        function New-TaskObj2 {
            param([string]$Arguments)
            return [pscustomobject]@{
                TaskName = 'x'
                Actions  = @([pscustomobject]@{ Execute = 'C:\Program Files\PowerShell\7\pwsh.exe'; Arguments = $Arguments })
            }
        }
    }

    It '-Command 内部的 -File 只是数据参数，不算入口' {
        $t = New-TaskObj2 -Arguments '-NoProfile -Command "& C:\OtherTool\OtherTool.ps1 -File C:\Moved\Cloudflare-Hosts-Optimizer.ps1 -Label data"'
        Test-OptimizerTaskOwnership -Task $t -ScriptPath $script:TaskScript2 | Should -BeFalse
    }

    It '-Command 里出现脚本名但没有 -File 也不算' {
        $t = New-TaskObj2 -Arguments '-NoProfile -Command "Write-Output C:\Moved\Cloudflare-Hosts-Optimizer.ps1"'
        Test-OptimizerTaskOwnership -Task $t -ScriptPath $script:TaskScript2 | Should -BeFalse
    }

    It '正常的宿主 -File 入口仍可识别' {
        $t = New-TaskObj2 -Arguments '-NoProfile -File "C:\Moved\Cloudflare-Hosts-Optimizer.ps1" -DryRun'
        Test-OptimizerTaskOwnership -Task $t -ScriptPath $script:TaskScript2 | Should -BeTrue
    }

    It '-File 之后的 -Command 只是脚本自己的参数' {
        $t = New-TaskObj2 -Arguments '-NoProfile -File "C:\Moved\Cloudflare-Hosts-Optimizer.ps1" -Command something'
        Test-OptimizerTaskOwnership -Task $t -ScriptPath $script:TaskScript2 | Should -BeTrue
    }
}

Describe 'E01 隐式脚本入口与其他执行模式' {
    BeforeAll {
        $script:TaskScript3 = Join-Path $script:RepoRoot 'Cloudflare-Hosts-Optimizer.ps1'
        function New-TaskObj3 {
            param([string]$Arguments)
            return [pscustomobject]@{
                TaskName = 'Cloudflare-Hosts-Optimizer DryRun'
                Actions  = @([pscustomobject]@{ Execute = 'C:\Program Files\PowerShell\7\pwsh.exe'; Arguments = $Arguments })
            }
        }
    }

    It '隐式脚本入口后面的 -File 只是那个脚本的参数' {
        $t = New-TaskObj3 -Arguments '-NoProfile "C:\OtherTool\OtherTool.ps1" -File C:\Moved\Cloudflare-Hosts-Optimizer.ps1 -Label data'
        Test-OptimizerTaskOwnership -Task $t -ScriptPath $script:TaskScript3 | Should -BeFalse
    }

    It 'CommandWithArgs 后面的 -File 也是数据参数' {
        $t = New-TaskObj3 -Arguments '-NoProfile -CommandWithArgs "Write-Output OTHER" -File C:\Moved\Cloudflare-Hosts-Optimizer.ps1 -Label data'
        Test-OptimizerTaskOwnership -Task $t -ScriptPath $script:TaskScript3 | Should -BeFalse
    }

    It '不认识的宿主开关保守拒绝' {
        $t = New-TaskObj3 -Arguments '-NoProfile -SomeFutureSwitch x -File C:\Moved\Cloudflare-Hosts-Optimizer.ps1'
        Test-OptimizerTaskOwnership -Task $t -ScriptPath $script:TaskScript3 | Should -BeFalse
    }

    It '误认的任务在卸载流程里也不会被删除' {
        $script:e01Task = New-TaskObj3 -Arguments '-NoProfile "C:\OtherTool\OtherTool.ps1" -File C:\Moved\Cloudflare-Hosts-Optimizer.ps1 -Label data'
        Mock Get-ScheduledTask { $script:e01Task }
        Mock Remove-OptimizerTask { }
        $rows = @(Uninstall-OptimizerTask -TaskName 'Cloudflare-Hosts-Optimizer DryRun' -WhatIf)
        $rows[0].Removed | Should -BeFalse
        Should -Invoke Remove-OptimizerTask -Times 0
    }
}
