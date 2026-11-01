#Requires -Version 7.0
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:RepoRoot = $repoRoot
    . (Join-Path $repoRoot 'lib\Safety.ps1')
    . (Join-Path $repoRoot 'lib\Domains.ps1')
    . (Join-Path $repoRoot 'lib\HostsFile.ps1')
    . (Join-Path $repoRoot 'lib\Menu.ps1')

    function New-HostsFixture {
        param([string]$Path, [string[]]$Lines)
        Set-Content -LiteralPath $Path -Value $Lines -Encoding ascii
        return $Path
    }

    # 从 Menu.ps1 里取出单个函数定义，供直接调用测试（Menu.ps1 顶层有菜单入口，不能整体 dot-source）
    function Get-MenuFunctionSource {
        param([string]$Name)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:RepoRoot 'Menu.ps1'), [ref]$tokens, [ref]$errors)
        $fn = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
            }, $true) | Select-Object -First 1
        if (-not $fn) { throw "找不到函数 $Name" }
        return $fn.Extent.Text
    }
}

Describe '菜单定义' {
    It '四个菜单的条目数量' {
        @(Get-MenuItems -Menu Main).Count | Should -Be 11
        @(Get-MenuItems -Menu Import).Count | Should -Be 6
        @(Get-MenuItems -Menu Cfst).Count | Should -Be 5
        @(Get-MenuItems -Menu Task).Count | Should -Be 4
    }

    It '每个菜单的 key 唯一且都能解析' {
        foreach ($menu in @('Main', 'Import', 'Cfst', 'Task')) {
            $items = @(Get-MenuItems -Menu $menu)
            @($items.Key | Select-Object -Unique).Count | Should -Be $items.Count
            foreach ($i in $items) {
                (Get-MenuActionSpec -Menu $menu -Key $i.Key).Label | Should -Be $i.Label
            }
        }
    }

    It '写入和回滚需要管理员并要确认' {
        $apply = Get-MenuActionSpec -Menu Main -Key '9'
        $apply.RequiresAdmin | Should -BeTrue
        $apply.Confirm | Should -BeTrue
        (Get-MenuActionSpec -Menu Main -Key '10').RequiresAdmin | Should -BeTrue
        (Get-MenuActionSpec -Menu Main -Key '8').RequiresAdmin | Should -BeFalse
    }

    It '主菜单按使用顺序排列，1-9 都能直达' {
        $items = @(Get-MenuItems -Menu Main)
        $items[0].Label | Should -Match '导入'
        $items[1].Label | Should -Match '查看域名'
        $items[7].Key | Should -Be '8'
        $items[7].Label | Should -Match 'DryRun'
        $items[8].Key | Should -Be '9'
        $items[8].Label | Should -Match '正式写入'
        $items[9].Key | Should -Be '10'
        $items[10].Key | Should -Be '0'
        foreach ($i in 1..9) {
            Get-MenuActionSpec -Menu Main -Key "$i" | Should -Not -BeNullOrEmpty
        }
    }

    It 'AutoApply 任务需要管理员' {
        (Get-MenuActionSpec -Menu Task -Key '2').RequiresAdmin | Should -BeTrue
        (Get-MenuActionSpec -Menu Task -Key '1').RequiresAdmin | Should -BeFalse
    }

    It '导入来源和输入类型' {
        (Get-MenuActionSpec -Menu Import -Key '1').Source | Should -Be 'Depiler'
        (Get-MenuActionSpec -Menu Import -Key '1').InputKind | Should -Be 'Path'
        (Get-MenuActionSpec -Menu Import -Key '2').Source | Should -Be 'ProxyBypass'
        (Get-MenuActionSpec -Menu Import -Key '3').Source | Should -Be 'Text'
        (Get-MenuActionSpec -Menu Import -Key '4').Source | Should -Be 'Clipboard'
        (Get-MenuActionSpec -Menu Import -Key '5').Kind | Should -Be 'EditDomains'
    }

    It 'CFST 子菜单' {
        (Get-MenuActionSpec -Menu Cfst -Key '1').Method | Should -Be 'Direct'
        (Get-MenuActionSpec -Menu Cfst -Key '2').Method | Should -Be 'Proxy'
        (Get-MenuActionSpec -Menu Cfst -Key '4').InputKind | Should -Be 'Path'
        (Get-MenuActionSpec -Menu Cfst -Key '3').Target | Should -Match 'lanzoub'
    }

    It '未知或空 key 返回 null' {
        Get-MenuActionSpec -Menu Main -Key '99' | Should -BeNullOrEmpty
        Get-MenuActionSpec -Menu Main -Key '  ' | Should -BeNullOrEmpty
        Get-MenuActionSpec -Menu Main -Key 'Q' | Should -BeNullOrEmpty
    }
}

Describe 'Get-DomainOverview' {
    It '只在列表 / 只在 hosts' {
        $domains = Join-Path $TestDrive 'domains.txt'
        Set-Content -LiteralPath $domains -Value @('a.com', 'b.com') -Encoding ascii
        $hosts = Join-Path $TestDrive 'hosts1'
        New-HostsFixture -Path $hosts -Lines @(
            '127.0.0.1 localhost'
            $script:BeginMarker
            '1.2.3.4 a.com'
            '5.6.7.8 c.com'
            $script:EndMarker
        )
        $o = Get-DomainOverview -DomainsFile $domains -HostsPath $hosts
        $o.HostsError | Should -BeNullOrEmpty
        @($o.Listed) | Should -Be @('a.com', 'b.com')
        @($o.OnlyListed) | Should -Be @('b.com')
        @($o.OnlyManaged) | Should -Be @('c.com')
        @($o.Managed['a.com']) | Should -Be @('1.2.3.4')
    }

    It 'hosts 标记异常时返回错误' {
        $domains = Join-Path $TestDrive 'domains2.txt'
        Set-Content -LiteralPath $domains -Value @('a.com') -Encoding ascii
        $hosts = Join-Path $TestDrive 'hosts2'
        New-HostsFixture -Path $hosts -Lines @($script:BeginMarker, '1.2.3.4 a.com')
        $o = Get-DomainOverview -DomainsFile $domains -HostsPath $hosts
        $o.HostsError | Should -Match '标记'
        $o.Managed.Keys.Count | Should -Be 0
    }

    It 'domains.txt 不存在时列表为空' {
        $hosts = Join-Path $TestDrive 'hosts3'
        New-HostsFixture -Path $hosts -Lines @('127.0.0.1 localhost')
        $o = Get-DomainOverview -DomainsFile (Join-Path $TestDrive 'nope.txt') -HostsPath $hosts
        @($o.Listed).Count | Should -Be 0
        $o.ListedError | Should -BeNullOrEmpty
        $o.HostsError | Should -BeNullOrEmpty
    }
}

Describe 'Get-MenuStatus' {
    It '汇总域名、hosts、CFST 和报告时间' {
        $domains = Join-Path $TestDrive 'domains-s.txt'
        Set-Content -LiteralPath $domains -Value @('a.com', 'b.com') -Encoding ascii
        $hosts = Join-Path $TestDrive 'hosts-s'
        New-HostsFixture -Path $hosts -Lines @(
            '127.0.0.1 localhost'
            $script:BeginMarker
            '1.2.3.4 a.com'
            $script:EndMarker
        )
        $cfst = Join-Path $TestDrive 'cfst-s'
        New-Item -ItemType Directory -Path $cfst -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $cfst 'cfst.exe') -Value 'MZ' -Encoding ascii
        $report = Join-Path $TestDrive 'last-report.txt'
        Set-Content -LiteralPath $report -Value 'x' -Encoding utf8

        $s = Get-MenuStatus -DomainsFile $domains -HostsPath $hosts -CfstDir $cfst -ReportPath $report
        $s.Listed | Should -Be 2
        $s.Invalid | Should -Be 0
        $s.Managed | Should -Be 1
        $s.Cfst | Should -Be '缺少 ip.txt'
        $s.LastRun | Should -Not -BeNullOrEmpty
        $s.HostsError | Should -BeNullOrEmpty
    }

    It 'hosts 异常时报告错误' {
        $domains = Join-Path $TestDrive 'domains-s2.txt'
        Set-Content -LiteralPath $domains -Value @('a.com') -Encoding ascii
        $hosts = Join-Path $TestDrive 'hosts-s2'
        New-HostsFixture -Path $hosts -Lines @($script:EndMarker)
        $cfst = Join-Path $TestDrive 'cfst-s2'
        $s = Get-MenuStatus -DomainsFile $domains -HostsPath $hosts -CfstDir $cfst -ReportPath ''
        $s.HostsError | Should -Not -BeNullOrEmpty
        $s.Cfst | Should -Be '未安装'
    }
}

Describe 'Format-MenuFrame' {
    It '每项带序号并保留头部和页脚' {
        $items = @(
            (New-MenuSpec '1' '第一项' 'Script'),
            (New-MenuSpec '2' '第二项' 'Script')
        )
        $lines = @(Format-MenuFrame -Header @('标题', '状态') -Items $items -Footer '↑↓ 选择')
        $lines[0] | Should -Be '标题'
        $lines[1] | Should -Be '状态'
        $lines[2] | Should -Be ''
        $lines[3] | Should -Be ' 1) 第一项'
        $lines[4] | Should -Be ' 2) 第二项'
        $lines[-1] | Should -Be '↑↓ 选择'
    }

    It '两位序号也保持对齐' {
        $items = @(
            (New-MenuSpec '9' '九' 'Script'),
            (New-MenuSpec '10' '十' 'Script'),
            (New-MenuSpec '0' '零' 'Script')
        )
        $lines = @(Format-MenuFrame -Header @() -Items $items -Footer '')
        $lines[1] | Should -Be ' 9) 九'
        $lines[2] | Should -Be '10) 十'
        $lines[3] | Should -Be ' 0) 零'
    }

    It '没有页脚时不额外加空行' {
        $items = @((New-MenuSpec '1' 'A' 'Script'))
        @(Format-MenuFrame -Header @() -Items $items -Footer '').Count | Should -Be 2
    }
}

Describe 'New-ElevatedArgumentLine' {
    It '空参数（正式写入）也带 -Elevated' {
        $line = New-ElevatedArgumentLine -MenuScript 'C:\My Tools\Menu.ps1'
        $line | Should -Match '-Elevated '
        $line | Should -Match '-ElevatedArgs ""'
        $line.Contains('"C:\My Tools\Menu.ps1"') | Should -BeTrue
    }

    It '参数按顺序拼接' {
        $line = New-ElevatedArgumentLine -MenuScript 'C:\Menu.ps1' -Arguments @('-InstallTask', '-TaskMode', 'AutoApply')
        $line | Should -Match '-ElevatedArgs "-InstallTask -TaskMode AutoApply"'
    }
}

Describe 'Get-MenuInitialIndex' {
    It '没有域名时停在导入' {
        Get-MenuInitialIndex -Menu Main -DomainCount 0 | Should -Be 0
    }

    It '已有域名时停在 DryRun' {
        $items = @(Get-MenuItems -Menu Main)
        $expected = 0
        for ($i = 0; $i -lt $items.Count; $i++) { if ($items[$i].Key -eq '8') { $expected = $i } }
        Get-MenuInitialIndex -Menu Main -DomainCount 5 | Should -Be $expected
    }

    It '子菜单默认第一项' {
        Get-MenuInitialIndex -Menu Import -DomainCount 9 | Should -Be 0
    }

    It '执行动作后返回主菜单默认停在退出' {
        $items = @(Get-MenuItems -Menu Main)
        $exitIndex = 0
        for ($i = 0; $i -lt $items.Count; $i++) { if ($items[$i].Key -eq '0') { $exitIndex = $i } }
        Get-MenuInitialIndex -Menu Main -DomainCount 5 -Returning | Should -Be $exitIndex
        Get-MenuInitialIndex -Menu Main -DomainCount 0 -Returning | Should -Be $exitIndex
    }

    It '编号模式空输入不会匹配任何动作' {
        Get-MenuActionSpec -Menu Main -Key '' | Should -BeNullOrEmpty
        Get-MenuActionSpec -Menu Main -Key '   ' | Should -BeNullOrEmpty
    }
}

Describe '任务菜单纯逻辑' {
    It '查询失败显示未知，不显示无任务' {
        (@(Get-TaskStatusLines -Info ([pscustomobject]@{ Available = $false; Tasks = @() })))[0] | Should -Match '未知'
    }

    It '没有任务和无任务状态' {
        (@(Get-TaskStatusLines -Info ([pscustomobject]@{ Available = $true; Tasks = @() })))[0] | Should -Match '无'
    }

    It '有任务时列出名称、状态和下次运行' {
        $info = [pscustomobject]@{
            Available = $true
            Tasks     = @([pscustomobject]@{ TaskName = 'Cloudflare-Hosts-Optimizer DryRun'; State = 'Ready'; NextRun = '2026-11-15 10:00'; LastRun = ''; LastResult = $null })
        }
        $line = (@(Get-TaskStatusLines -Info $info))[0]
        $line | Should -Match 'DryRun'
        $line | Should -Match 'Ready'
        $line | Should -Match '2026-11-15'
    }

    It '查询异常显示未知，不谎称没有任务' {
        $line = (@(Get-TaskStatusLines -Info ([pscustomobject]@{ Available = $true; QueryFailed = $true; Error = 'CIM 错误'; Tasks = @() })))[0]
        $line | Should -Match '未知'
        $line | Should -Match '查询失败'
        $line | Should -Not -Match '无'
    }

    It 'AutoApply 安装始终需要确认，DryRun 新建不需要' {
        (Get-TaskInstallPrompt -Arguments @('-InstallTask', '-TaskMode', 'AutoApply') -Required $true).NeedConfirm | Should -BeTrue
        (Get-TaskInstallPrompt -Arguments @('-InstallTask', '-TaskMode', 'DryRun')).NeedConfirm | Should -BeFalse
        $p = Get-TaskInstallPrompt -Arguments @('-InstallTask', '-TaskMode', 'AutoApply') -Required $true
        $p.Text | Should -Match '自动写入'
    }

    It '同名任务覆盖需要确认，查询失败时不加 TaskForce' {
        $p = Get-TaskInstallPrompt -Arguments @('-InstallTask', '-TaskMode', 'DryRun') -TaskExists $true -ExistsKnown $false
        $p.NeedConfirm | Should -BeTrue
        $p.Text | Should -Match '覆盖'
        $unknown = Get-TaskInstallPrompt -Arguments @('-InstallTask', '-TaskMode', 'DryRun') -ExistsKnown $false
        $unknown.NeedConfirm | Should -BeFalse
        $unknown.ExistsKnown | Should -BeFalse
    }

    It '覆盖确认取消时不执行，确认后才带 -TaskForce' {
        Get-TaskInstallPlan -Arguments @('-InstallTask', '-TaskMode', 'DryRun') -TaskExists $true -Confirmed $false | Should -BeNullOrEmpty
        $plan = Get-TaskInstallPlan -Arguments @('-InstallTask', '-TaskMode', 'DryRun') -TaskExists $true -Confirmed $true
        $plan.Arguments | Should -Contain '-TaskForce'
        $plain = Get-TaskInstallPlan -Arguments @('-InstallTask', '-TaskMode', 'DryRun') -TaskExists $false
        $plain.Arguments | Should -Not -Contain '-TaskForce'
    }

    It 'UAC 结果文案' {
        Format-ElevatedResult -ExitCode 0 | Should -Match '退出码 0'
        Format-ElevatedResult -ExitCode 3 | Should -Match '退出码 3'
        Format-ElevatedResult -ExitCode $null -Cancelled $true | Should -Match '取消'
    }
}

Describe 'Show-TaskMenu 行为（直接调用）' {
    BeforeAll {
        # Menu.ps1 顶层会进入菜单循环，只能取出 Show-TaskMenu 单独定义
        . ([scriptblock]::Create((Get-MenuFunctionSource -Name 'Show-TaskMenu')))
        $script:MainScript = 'C:\fake\Cloudflare-Hosts-Optimizer.ps1'

        function Get-ScheduledTaskDoctorInfo { & $script:TaskQuery }
        function Read-MenuChoice {
            param([string]$Menu, [string[]]$ExtraHeader = @())
            $script:Observed.Headers = @($ExtraHeader)
            if ($script:Choices.Count -eq 0) { return Get-MenuActionSpec -Menu Task -Key '0' }
            $next = $script:Choices[0]
            $script:Choices = @($script:Choices | Select-Object -Skip 1)
            return $next
        }
        function Confirm-Action {
            param([string]$Label)
            $script:Observed.Confirms = @($script:Observed.Confirms) + $Label
            return [bool]$script:Observed.ConfirmAnswer
        }
        function Invoke-Child {
            param([string]$FilePath, [string[]]$Arguments = @())
            $script:Observed.Child.Add(@($Arguments))
            return 0
        }
        function Invoke-Elevated {
            param([string[]]$Arguments = @())
            $script:Observed.Elevated.Add(@($Arguments))
            return [pscustomobject]@{ ExitCode = 0 }
        }
        function Pause-Action { }
    }

    BeforeEach {
        $script:Observed = @{
            Headers       = @()
            Confirms      = @()
            ConfirmAnswer = $false
            Child         = [System.Collections.Generic.List[object]]::new()
            Elevated      = [System.Collections.Generic.List[object]]::new()
        }
        $script:Choices = @()
        $script:IsAdmin = $false
        $script:TaskQuery = { [pscustomobject]@{ Available = $true; QueryFailed = $false; Error = ''; Tasks = @() } }
    }

    It '查询抛错时显示未知并可以返回，不会结束菜单' {
        $script:TaskQuery = { throw 'CIM 查询失败' }
        { Show-TaskMenu } | Should -Not -Throw
        $headers = $script:Observed.Headers -join "`n"
        $headers | Should -Match '未知'
        $headers | Should -Match '查询失败'
        $script:Observed.Child.Count | Should -Be 0
        $script:Observed.Elevated.Count | Should -Be 0
    }

    It '首次安装 AutoApply 拒绝确认时不启动子进程（普通权限）' {
        $script:Choices = @(Get-MenuActionSpec -Menu Task -Key '2')
        Show-TaskMenu
        $script:Observed.Confirms.Count | Should -Be 1
        $script:Observed.Child.Count | Should -Be 0
        $script:Observed.Elevated.Count | Should -Be 0
    }

    It '首次安装 AutoApply 拒绝确认时不启动子进程（管理员）' {
        $script:IsAdmin = $true
        $script:Choices = @(Get-MenuActionSpec -Menu Task -Key '2')
        Show-TaskMenu
        $script:Observed.Confirms.Count | Should -Be 1
        $script:Observed.Child.Count | Should -Be 0
    }

    It '管理员确认后安装 AutoApply，确认只问一次且不带 -TaskForce' {
        $script:IsAdmin = $true
        $script:Observed.ConfirmAnswer = $true
        $script:Choices = @(Get-MenuActionSpec -Menu Task -Key '2')
        Show-TaskMenu
        $script:Observed.Confirms.Count | Should -Be 1
        $script:Observed.Child.Count | Should -Be 1
        $args = @($script:Observed.Child[0])
        $args | Should -Contain '-InstallTask'
        $args | Should -Contain 'AutoApply'
        $args | Should -Not -Contain '-TaskForce'
    }

    It '同名任务覆盖拒绝时不执行' {
        $script:IsAdmin = $true
        $script:TaskQuery = {
            [pscustomobject]@{
                Available = $true; QueryFailed = $false; Error = ''
                Tasks     = @([pscustomobject]@{
                        TaskName = 'Cloudflare-Hosts-Optimizer AutoApply'; State = 'Ready'
                        NextRun = ''; LastRun = ''; LastResult = $null
                    })
            }
        }
        $script:Choices = @(Get-MenuActionSpec -Menu Task -Key '2')
        Show-TaskMenu
        $script:Observed.Confirms.Count | Should -Be 1
        $script:Observed.Child.Count | Should -Be 0
    }

    It '同名任务覆盖确认后带 -TaskForce' {
        $script:IsAdmin = $true
        $script:Observed.ConfirmAnswer = $true
        $script:TaskQuery = {
            [pscustomobject]@{
                Available = $true; QueryFailed = $false; Error = ''
                Tasks     = @([pscustomobject]@{
                        TaskName = 'Cloudflare-Hosts-Optimizer DryRun'; State = 'Ready'
                        NextRun = ''; LastRun = ''; LastResult = $null
                    })
            }
        }
        $script:Choices = @(Get-MenuActionSpec -Menu Task -Key '1')
        Show-TaskMenu
        $script:Observed.Child.Count | Should -Be 1
        @($script:Observed.Child[0]) | Should -Contain '-TaskForce'
    }

    It '查询失败时不确定是否存在，不加 -TaskForce 也不跳过安装' {
        $script:IsAdmin = $true
        $script:TaskQuery = { [pscustomobject]@{ Available = $true; QueryFailed = $true; Error = 'boom'; Tasks = @() } }
        $script:Choices = @(Get-MenuActionSpec -Menu Task -Key '1')
        Show-TaskMenu
        $script:Observed.Child.Count | Should -Be 1
        @($script:Observed.Child[0]) | Should -Not -Contain '-TaskForce'
    }
}

Describe '菜单头部状态栏' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'lib\RunSummary.ps1')
        Invoke-Expression (Get-MenuFunctionSource -Name 'Get-MenuHeader')
        $script:Version = '0.5.6'
        $script:Root = $TestDrive
        $script:HostsPath = Join-Path $TestDrive 'hosts'
        $script:ReportPath = Join-Path $TestDrive 'last-report.txt'
    }

    It '彩色模式下普通权限提示不会被变量名吞掉' {
        # 陷阱："$dim当前是普通权限" 会被解析成变量 $dim当前是普通权限（CJK 是合法变量名字符）
        $script:IsAdmin = $false
        $st = [pscustomobject]@{ Listed = 0; Cfst = '未安装'; Invalid = 0; HostsError = ''; Managed = 0 }
        $text = (Get-MenuHeader -Status $st -Color) -join "`n"
        $text | Should -Match ([regex]::Escape("$([char]27)[90m当前是普通权限"))
        $text | Should -Match ([regex]::Escape("$([char]27)[33m0 个"))
    }

    It 'hosts 结构异常时保留 hosts 字样和红色' {
        $script:IsAdmin = $true
        $st = [pscustomobject]@{ Listed = 3; Cfst = '已安装'; Invalid = 0; HostsError = 'bad markers'; Managed = 0 }
        $text = (Get-MenuHeader -Status $st -Color) -join "`n"
        $text | Should -Match ([regex]::Escape("$([char]27)[31mhosts 结构异常"))
    }

    It '纯文本模式也不丢字' {
        $script:IsAdmin = $false
        $st = [pscustomobject]@{ Listed = 0; Cfst = '未安装'; Invalid = 2; HostsError = ''; Managed = 0 }
        $text = (Get-MenuHeader -Status $st) -join "`n"
        $text | Should -Match '当前是普通权限'
        $text | Should -Match '0 个'
        $text | Should -Match '2 个非法'
        $text | Should -Not -Match ([regex]::Escape([string][char]27))
    }
}

Describe 'F12 单个菜单动作失败不结束菜单' {
    It '报告被独占打开时只提示，不抛异常' {
        $report = Join-Path $TestDrive 'locked-report.txt'
        Set-Content -LiteralPath $report -Value @('runId: old', '模式: 写入') -Encoding utf8
        $fs = [IO.File]::Open($report, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            $script:ReportPath = $report
            $script:Root = $TestDrive
            Invoke-Expression (Get-MenuFunctionSource 'Show-Report')
            { Show-Report } | Should -Not -Throw
        } finally {
            $fs.Dispose()
        }
    }

    It '动作抛错后主循环继续读取下一次选择' {
        Invoke-Expression (Get-MenuFunctionSource 'Invoke-MenuLoop')
        $script:f12Reads = 0
        $script:f12Errors = 0
        $script:f12Spec = [pscustomobject]@{ Kind = 'Action'; Key = '8'; Label = 'DryRun' }
        $readChoice = {
            param($first)
            $script:f12Reads++
            if ($script:f12Reads -eq 1) { return $script:f12Spec }
            return [pscustomobject]@{ Kind = 'Exit'; Key = '0'; Label = '退出' }
        }
        $invokeAction = { param($spec) throw 'boom' }
        $onError = { param($err) $script:f12Errors++ }

        Invoke-MenuLoop -ReadChoice $readChoice -InvokeAction $invokeAction -OnError $onError

        $script:f12Reads | Should -Be 2
        $script:f12Errors | Should -Be 1
    }
}
