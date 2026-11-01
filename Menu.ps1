#Requires -Version 7.0
<#
    双击 Start.bat 后进入的菜单（TUI：上下箭头选择，1-9 直达）。

    - 菜单就地重绘；选定后先擦掉整块菜单，动作输出从干净的位置开始。
    - 输出/输入被重定向、或终端不支持 VT 时，自动退回编号输入。
      `$env:CFO_PLAIN_MENU='1'` 可强制使用编号输入。
    - 不能用 dot-source 调主脚本——它末尾有 exit，会把菜单一起结束。
    - 写入 hosts / 回滚 / AutoApply 任务需要管理员时，用 Start-Process -Verb RunAs
      打开 Menu.ps1 -ElevatedKey <key>，子窗口跑完按 Enter 自动关闭。
#>
[CmdletBinding()]
param([string]$Action, [switch]$Elevated, [string]$ElevatedArgs)

$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$MainScript = Join-Path $Root 'Cloudflare-Hosts-Optimizer.ps1'
$ImportScript = Join-Path $Root 'Import-Domains.ps1'
$CfstScript = Join-Path $Root 'Install-Cfst.ps1'
$DomainsFile = Join-Path $Root 'domains.txt'
$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$ReportPath = Join-Path $Root 'last-report.txt'
$CfstDir = Join-Path $Root 'cfst'

. (Join-Path $Root 'lib\Domains.ps1')
. (Join-Path $Root 'lib\HostsFile.ps1')
. (Join-Path $Root 'lib\Probe.ps1')
. (Join-Path $Root 'lib\CfstInstaller.ps1')
. (Join-Path $Root 'lib\Menu.ps1')
. (Join-Path $Root 'lib\RunSummary.ps1')
. (Join-Path $Root 'lib\Doctor.ps1')

function Get-PwshPath {
    # [Environment]::ProcessPath 从 .NET 6 才有；PowerShell 7.0（.NET Core 3.1）上访问会抛错，
    # 所以必须先 try/catch，再退回命令查找和常见安装位置。
    $p = ''
    try { $p = [Environment]::ProcessPath } catch { $p = '' }
    if ($p -and (Test-Path -LiteralPath $p) -and ([IO.Path]::GetFileName($p) -match '^pwsh(-preview)?\.exe$')) { return $p }
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $candidates = @()
    try { $candidates += Join-Path $PSHOME 'pwsh.exe' } catch { }
    if ($env:ProgramFiles) {
        $candidates += Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        $candidates += Join-Path $env:ProgramFiles 'PowerShell\7-preview\pwsh.exe'
    }
    if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe' }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw '找不到 pwsh.exe。'
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-TuiSupported {
    if ($env:CFO_PLAIN_MENU -eq '1') { return $false }
    try {
        if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) { return $false }
        if (-not $Host.UI.SupportsVirtualTerminal) { return $false }
        [void][Console]::WindowWidth
        return $true
    } catch {
        return $false
    }
}

# 清屏并清掉回滚记录（Windows Terminal 支持 ESC[3J）
function Clear-MenuScreen {
    if (-not $script:Tui) { return }
    try { [Console]::Write("`e[2J`e[3J`e[H") } catch { }
}

$script:Pwsh = Get-PwshPath
$script:IsAdmin = Test-IsAdmin
$script:Tui = if ($Action) { $false } else { Test-TuiSupported }
$script:Version = ''
try {
    $m = Select-String -LiteralPath $MainScript -Pattern "ScriptVersion\s*=\s*'([^']+)'" | Select-Object -First 1
    if ($m) { $script:Version = $m.Matches[0].Groups[1].Value }
} catch { }

function Pause-Menu {
    [void](Read-Host '按回车返回菜单')
}

function Pause-Action {
    if ($script:Tui) { [void](Read-Host '按回车返回菜单') }
    else { Pause-Menu }
}

function Confirm-Action {
    param([string]$Label)
    $ans = Read-Host "确认执行「$Label」？[y/N]"
    return ($ans -match '^[Yy]')
}

function ConvertTo-ArgumentString {
    param([string[]]$Arguments = @())
    $parts = foreach ($a in $Arguments) {
        if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }
    return ($parts -join ' ')
}

function Invoke-Child {
    param([string]$FilePath, [string[]]$Arguments = @())
    # 用 Start-Process -NoNewWindow 让子进程直接使用当前控制台：
    # 1) 输出实时、保留颜色和它自己的进度动画；2) 不会被函数返回值捕获成一整块。
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $FilePath
    $extra = ConvertTo-ArgumentString -Arguments $Arguments
    if ($extra) { $argLine += ' ' + $extra }
    $p = Start-Process -FilePath $script:Pwsh -NoNewWindow -Wait -PassThru -WorkingDirectory $Root -ArgumentList $argLine
    return $p.ExitCode
}

function Invoke-Elevated {
    param([string[]]$Arguments = @())
    $menuScript = Join-Path $Root 'Menu.ps1'
    $argLine = New-ElevatedArgumentLine -MenuScript $menuScript -Arguments $Arguments
    Write-Host '会先弹出 UAC；请在管理员窗口中查看进度，结束后按 Enter 关闭该窗口。' -ForegroundColor Yellow
    try {
        $p = Start-Process -FilePath $script:Pwsh -Verb RunAs -Wait -PassThru -WorkingDirectory $Root -ArgumentList $argLine
        if ($p) {
            $text = Format-ElevatedResult -ExitCode $p.ExitCode
            Write-Host $text -ForegroundColor $(if ($p.ExitCode -eq 0) { 'Green' } else { 'Yellow' })
        }
        return $p
    } catch {
        $code = $null
        try { $code = $_.Exception.NativeErrorCode } catch { }
        if ($code -eq 1223 -or $_.Exception.Message -match '1223|cancel|取消') {
            Write-Host (Format-ElevatedResult -ExitCode $null -Cancelled $true) -ForegroundColor Yellow
        } else {
            Write-Host "提权失败：$($_.Exception.Message)" -ForegroundColor Red
        }
        return $null
    }
}

function Get-MenuHeader {
    param($Status, [switch]$Color)
    $st = if ($Status) { $Status } else {
        Get-MenuStatus -DomainsFile $DomainsFile -HostsPath $HostsPath -CfstDir $CfstDir -ReportPath $ReportPath
    }
    $dot = [string][char]0x00B7
    $title = if ($script:Version) { "Cloudflare-Hosts-Optimizer $($script:Version)" } else { 'Cloudflare-Hosts-Optimizer' }

    $summary = Read-RunSummary -Path (Join-Path $Root 'last-run.json')
    $runLines = Format-RunSummaryLine -Summary $summary -SystemHostsPath $HostsPath -ReportPath $ReportPath

    $hint = ''
    $hintKind = ''
    if ($st.Listed -eq 0) {
        $hint = '下一步：按 1 导入或编辑网页域名（只填网页域名，不填独立 tracker）'
        $hintKind = 'warn'
    } elseif ($st.Cfst -eq '未安装') {
        $hint = '可直接按 8 试跑；装 CFST 可改善候选覆盖（按 3）'
        $hintKind = 'dim'
    }

    if ($Color) {
        $green = "`e[32m"; $yellow = "`e[33m"; $red = "`e[31m"; $reset = "`e[0m"
        $dim = "`e[90m"
        $sep = "`e[90m$dot`e[0m"
        $titleLine = "`e[1;36m$title`e[0m"
        $listedValue = if ($st.Listed -gt 0) { "$green$($st.Listed) 个$reset" } else { "${yellow}0 个$reset" }
        $invalidText = if ($st.Invalid -gt 0) { " $yellow（$($st.Invalid) 个非法）$reset" } else { '' }
        if ($st.HostsError) {
            $hostsText = "${red}hosts 结构异常$reset"
        } else {
            $managedValue = if ($st.Managed -gt 0) { "$green$($st.Managed) 个$reset" } else { "${yellow}0 个$reset" }
            $hostsText = "hosts 已写入 $managedValue"
        }
        $cfstValue = if ($st.Cfst -eq '已安装') { "$green$($st.Cfst)$reset" } else { "$yellow$($st.Cfst)$reset" }
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add($titleLine)
        $lines.Add("域名 $listedValue$invalidText$sep $hostsText$sep CFST $cfstValue")
        if ($runLines.LastRun) { $lines.Add("$dim$($runLines.LastRun)$reset") }
        if ($runLines.LastCommit) { $lines.Add("$dim$($runLines.LastCommit)$reset") }
        if ($hint) {
            $hintColor = if ($hintKind -eq 'warn') { $yellow } else { $dim }
            $lines.Add("$hintColor$hint$reset")
        }
        if (-not $script:IsAdmin) {
            $lines.Add("${dim}当前是普通权限；写入 hosts / 回滚时会单独弹出 UAC。$reset")
        }
        return @($lines)
    }

    $hostsText = if ($st.HostsError) { 'hosts 结构异常' } else { "hosts 已写入 $($st.Managed) 个" }
    $invalidText = if ($st.Invalid -gt 0) { "（$($st.Invalid) 个非法）" } else { '' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($title)
    $lines.Add("域名 $($st.Listed) 个$invalidText $dot $hostsText $dot CFST $($st.Cfst)")
    if ($runLines.LastRun) { $lines.Add($runLines.LastRun) }
    if ($runLines.LastCommit) { $lines.Add($runLines.LastCommit) }
    if ($hint) { $lines.Add($hint) }
    if (-not $script:IsAdmin) { $lines.Add('当前是普通权限；写入 hosts / 回滚时会单独弹出 UAC。') }
    return @($lines)
}

function Show-Menu {
    param([string]$Menu)
    Write-Host ''
    foreach ($i in (Get-MenuItems -Menu $Menu)) {
        Write-Host ("  {0}) {1}" -f $i.Key, $i.Label)
    }
}

# 原地重绘（不使用备用屏幕）：菜单画在当前位置，选中行反显；
# 选定后先擦掉整块菜单，动作输出从菜单原来的位置开始，不会被菜单内容覆盖。
function Show-TuiMenu {
    param([string]$Menu, [string[]]$Header = @(), [int]$InitialIndex = 0)
    $items = @(Get-MenuItems -Menu $Menu)
    if ($items.Count -eq 0) { return $null }
    $selected = if ($InitialIndex -ge 0 -and $InitialIndex -lt $items.Count) { $InitialIndex } else { 0 }
    $top = -1
    $frameCount = 0
    try {
        while ($true) {
            $footer = '↑↓ 选择 · 1-9 直达 · Enter 确认 · Esc 返回'
            $lines = @(Format-MenuFrame -Header $Header -Items $items -Footer $footer)
            $selLine = $Header.Count + 1 + $selected
            $footerLine = $lines.Count - 1
            # 回到菜单块顶部重画；窗口缩放等导致位置失效时退回“从当前位置画”
            if ($top -ge 0) {
                try { [Console]::SetCursorPosition(0, $top) }
                catch { $top = -1 }
            }
            if ($top -lt 0) {
                try { $top = [Console]::CursorTop } catch { $top = 0 }
            }
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($i -eq $selLine) {
                    # 青色背景黑字，ESC[K 会把这一行剩余部分也填上背景色
                    [Console]::Write("`e[30;46m" + $lines[$i] + "`e[K`e[0m`r`n")
                } elseif ($i -eq $footerLine) {
                    [Console]::Write("`e[90m" + $lines[$i] + "`e[0m`e[K`r`n")
                } else {
                    [Console]::Write($lines[$i] + "`e[K`r`n")
                }
            }
            [Console]::Write("`e[J")
            $frameCount = $lines.Count
            try { $top = [Math]::Max(0, [Console]::CursorTop - $frameCount) } catch { }
            $key = [Console]::ReadKey($true)
            # 数字键直达：1-9 对应菜单里的 key，0 是退出/返回
            $keyName = $key.Key.ToString()
            if ($keyName -match '^(?:D|NumPad)([0-9])$') {
                $digitSpec = Get-MenuActionSpec -Menu $Menu -Key $Matches[1]
                if ($digitSpec) {
                    try { [Console]::SetCursorPosition(0, $top) } catch { }
                    [Console]::Write("`e[J")
                    return $digitSpec
                }
            }
            switch ($key.Key) {
                'UpArrow' { $selected = ($selected - 1 + $items.Count) % $items.Count }
                'DownArrow' { $selected = ($selected + 1) % $items.Count }
                'Home' { $selected = 0 }
                'End' { $selected = $items.Count - 1 }
                'Enter' {
                    # 擦掉菜单块，动作输出从这里开始
                    try { [Console]::SetCursorPosition(0, $top) } catch { }
                    [Console]::Write("`e[J")
                    return $items[$selected]
                }
                'Escape' {
                    try { [Console]::SetCursorPosition(0, $top) } catch { }
                    [Console]::Write("`e[J")
                    $back = @($items | Where-Object { $_.Kind -in @('Back', 'Exit') } | Select-Object -First 1)
                    if ($back.Count -gt 0) { return $back[0] }
                    return $null
                }
            }
        }
    } finally {
        try { [Console]::Write("`e[?25h") } catch { }
    }
}

function Read-MenuChoice {
    param([string]$Menu, [string[]]$ExtraHeader = @(), [switch]$Returning)
    Clear-MenuScreen
    $st = Get-MenuStatus -DomainsFile $DomainsFile -HostsPath $HostsPath -CfstDir $CfstDir -ReportPath $ReportPath
    $header = @(Get-MenuHeader -Status $st -Color:$script:Tui) + @($ExtraHeader)
    if ($script:Tui) {
        $initial = if ($Menu -eq 'Main') {
            Get-MenuInitialIndex -Menu $Menu -DomainCount $st.Listed -Returning:$Returning
        } else { 0 }
        return Show-TuiMenu -Menu $Menu -Header $header -InitialIndex $initial
    }
    Write-Host ''
    if ($header.Count -gt 0) { Write-Host $header[0] -ForegroundColor Cyan }
    for ($i = 1; $i -lt $header.Count; $i++) { Write-Host $header[$i] -ForegroundColor DarkGray }
    Show-Menu -Menu $Menu
    while ($true) {
        $key = Read-Host '请选择'
        $spec = Get-MenuActionSpec -Menu $Menu -Key $key
        if ($spec) { return $spec }
        Write-Host '无效选项' -ForegroundColor Yellow
    }
}

function Invoke-ScriptAction {
    param($Spec)
    if ($Spec.Confirm -and -not (Confirm-Action $Spec.Label)) { return }
    if ($Spec.RequiresAdmin -and -not $script:IsAdmin) {
        $p = Invoke-Elevated -Arguments @($Spec.Arguments)
        if ($p -and $p.ExitCode -ne 0) {
            Write-Host '管理员窗口返回非 0，请查看报告或重试。' -ForegroundColor Yellow
        }
        return
    }
    # 菜单里的 DryRun 也写报告，方便「查看上次报告」；命令行 DryRun 默认仍然不写
    $runArgs = @($Spec.Arguments)
    if ($runArgs -contains '-DryRun' -and $runArgs -notcontains '-ReportPath') {
        $runArgs += @('-ReportPath', $ReportPath)
    }
    $exit = Invoke-Child -FilePath $MainScript -Arguments $runArgs
    $color = if ($exit -eq 0) { 'Green' } else { 'Yellow' }
    Write-Host "退出码：$exit" -ForegroundColor $color
}

function Invoke-ImportAction {
    param($Spec)
    $path = ''
    if ($Spec.InputKind -eq 'Path') {
        $path = (Read-Host '输入文件路径（可把文件拖进来）').Trim('"').Trim()
        if (-not $path) { return }
    }
    $out = Join-Path $Root 'domains.imported.txt'
    $args = @('-Source', $Spec.Source, '-OutFile', $out)
    if ($path) { $args += @('-Path', $path) }
    $exit = Invoke-Child -FilePath $ImportScript -Arguments $args
    if ($exit -ne 0) {
        Write-Host "导入失败（退出码 $exit）。" -ForegroundColor Red
        return
    }
    $lines = @(Get-Content -LiteralPath $out -ErrorAction SilentlyContinue |
        Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
    Write-Host "提取到 $($lines.Count) 个域名：" -ForegroundColor Green
    $shown = 0
    foreach ($l in $lines) {
        if ($shown -ge 15) { Write-Host ("  … 其余 {0} 个未显示" -f ($lines.Count - 15)); break }
        Write-Host "  $($l.Trim())"
        $shown++
    }
    $ans = Read-Host '合并到 domains.txt？[y/N]'
    if ($ans -match '^[Yy]') {
        $mergeArgs = @('-Source', $Spec.Source, '-Merge', '-MergeTarget', $DomainsFile)
        if ($path) { $mergeArgs += @('-Path', $path) }
        $exit2 = Invoke-Child -FilePath $ImportScript -Arguments $mergeArgs
        if ($exit2 -eq 0) { Write-Host '已合并到 domains.txt。' -ForegroundColor Green }
    }
}

function Invoke-EditDomains {
    if (-not (Test-Path -LiteralPath $DomainsFile)) {
        $example = Join-Path $Root 'domains.example.txt'
        if (Test-Path -LiteralPath $example) { Copy-Item -LiteralPath $example -Destination $DomainsFile }
        else { Set-Content -LiteralPath $DomainsFile -Value '# 一行一个域名' -Encoding utf8 }
    }
    while ($true) {
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $DomainsFile) -Wait
        try {
            $r = Read-DomainsFile -Path $DomainsFile
        } catch {
            Write-Host "读取 domains.txt 失败：$($_.Exception.Message)" -ForegroundColor Red
            $again = Read-Host '重新打开编辑？[Y/n]'
            if ($again -match '^[Nn]') { return }
            continue
        }
        $invalid = @($r.Invalid)
        if ($invalid.Count -eq 0) {
            Write-Host "domains.txt 现有 $(@($r.Domains).Count) 个域名。" -ForegroundColor Green
            return
        }
        Write-Host "有 $($invalid.Count) 个非法项：$($invalid -join ', ')" -ForegroundColor Yellow
        $again = Read-Host '重新打开编辑？[Y/n]'
        if ($again -match '^[Nn]') { return }
    }
}

function Show-DomainOverview {
    $o = Get-DomainOverview -DomainsFile $DomainsFile -HostsPath $HostsPath
    $dot = [string][char]0x00B7
    Write-Host ''
    if ($o.ListedError) {
        Write-Host "domains.txt 读取失败：$($o.ListedError)" -ForegroundColor Red
    } else {
        Write-Host "domains.txt（$($o.Listed.Count) 个）：" -ForegroundColor Cyan
        foreach ($d in $o.Listed) { Write-Host "  $d" }
        if ($o.Invalid.Count -gt 0) { Write-Host "非法项：$($o.Invalid -join ', ')" -ForegroundColor Yellow }
    }
    Write-Host ''
    if ($o.HostsError) {
        Write-Host "hosts：结构异常（$($o.HostsError)）" -ForegroundColor Red
    } else {
        Write-Host "hosts 托管区块（$($o.Managed.Keys.Count) 个）：" -ForegroundColor Cyan
        foreach ($k in $o.Managed.Keys) { Write-Host ("  {0} -> {1}" -f $k, ($o.Managed[$k] -join ', ')) }
    }
    if ($o.OnlyListed.Count -gt 0) {
        Write-Host "$dot 只在 domains.txt、尚未写入：$($o.OnlyListed -join ', ')" -ForegroundColor Yellow
    }
    if ($o.OnlyManaged.Count -gt 0) {
        Write-Host "$dot 只在 hosts、不在列表：$($o.OnlyManaged -join ', ')" -ForegroundColor DarkGray
    }
}

function Show-Report {
    if (-not (Test-Path -LiteralPath $ReportPath)) {
        Write-Host '还没有报告：先跑一次 DryRun 或正式写入。' -ForegroundColor Yellow
        return
    }
    $lines = @(Get-Content -LiteralPath $ReportPath)
    $marker = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '=== 详细日志 ===') { $marker = $i; break }
    }
    $head = if ($marker -ge 0) { @($lines[0..$marker]) } else { @() }

    $summary = Read-RunSummary -Path (Join-Path $Root 'last-run.json')
    $reportRun = ($head | Where-Object { $_ -like 'runId:*' } | Select-Object -First 1)
    if ($reportRun) { $reportRun = ($reportRun -replace '^runId:\s*', '').Trim() }
    if ($summary -and $summary.lastRun -and $reportRun -and $reportRun -ne [string]$summary.lastRun.runId) {
        Write-Host '提示：以下为较早报告；最近一次运行（或回滚）没有覆盖它。' -ForegroundColor Yellow
    }

    $time = (Get-Item -LiteralPath $ReportPath).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
    Write-Host "报告：$ReportPath（$time）" -ForegroundColor DarkGray
    if ($lines.Count -le 80) {
        foreach ($l in $lines) { Write-Host $l }
        return
    }
    foreach ($l in $head) { Write-Host $l }
    Write-Host '...' -ForegroundColor DarkGray
    foreach ($l in @($lines | Select-Object -Last 40)) { Write-Host $l }
}

function Show-CfstMenu {
    while ($true) {
        $st = Get-CfstInstallState -Destination $CfstDir
        $ver = ''
        if ($st.Installed) {
            try { $ver = Get-CfstVersion -Exe $st.Exe } catch { }
        }
        $stateText = if ($st.Installed) { "已安装$(if ($ver) { " v$ver" })" } elseif ($st.HasExe) { '缺少 ip.txt' } else { '未安装' }
        $spec = Read-MenuChoice -Menu Cfst -ExtraHeader @("CFST：$stateText")
        if (-not $spec -or $spec.Kind -eq 'Back') { return }

        if ($spec.Kind -eq 'OpenUrl') {
            Start-Process $spec.Target
            Write-Host '已在浏览器打开下载页；下载后选「从本地 zip 安装」。' -ForegroundColor DarkGray
            Pause-Action
            continue
        }
        if ($spec.Kind -eq 'InstallCfst') {
            $cfstArgs = @()
            if ($spec.Method -eq 'Proxy') { $cfstArgs += '-UseProxy' }
            if ($spec.Method -eq 'File') {
                $zip = (Read-Host 'zip 路径（可把文件拖进来）').Trim('"').Trim()
                if (-not $zip) { continue }
                $cfstArgs += @('-FromFile', $zip)
            }
            if ($st.Installed) {
                $ans = Read-Host '已安装，覆盖？[y/N]'
                if ($ans -notmatch '^[Yy]') { continue }
                $cfstArgs += '-Force'
            }
            $exit = Invoke-Child -FilePath $CfstScript -Arguments $cfstArgs
            Write-Host "退出码：$exit" -ForegroundColor $(if ($exit -eq 0) { 'Green' } else { 'Yellow' })
            Pause-Action
        }
    }
}

function Show-TaskMenu {
    while ($true) {
        # 查询失败只影响状态显示，不能把异常抛到主菜单导致整个菜单退出
        $info = Get-TaskMenuInfo -Query { Get-ScheduledTaskDoctorInfo }
        $status = @(Get-TaskStatusLines -Info $info)
        $spec = Read-MenuChoice -Menu Task -ExtraHeader $status
        if (-not $spec -or $spec.Kind -eq 'Back') { return }

        # 安装：AutoApply 的“自动写入”确认和同名任务覆盖确认合并成一次提问；
        # 任何一个必要确认被拒绝都不执行（提权与非提权路径一致）。
        if ($spec.Arguments -contains '-InstallTask') {
            $existsKnown = -not [bool]$info.QueryFailed
            $mode = if ($spec.Arguments -contains 'DryRun') { 'DryRun' } else { 'AutoApply' }
            $name = "Cloudflare-Hosts-Optimizer $mode"
            $exists = [bool]($existsKnown -and @($info.Tasks | Where-Object { $_.TaskName -eq $name }).Count -gt 0)
            $prompt = Get-TaskInstallPrompt -Arguments @($spec.Arguments) -Required ([bool]$spec.Confirm) `
                -TaskExists $exists -ExistsKnown $existsKnown
            if ($prompt.NeedConfirm -and -not (Confirm-Action $prompt.Text)) { continue }
            $plan = Get-TaskInstallPlan -Arguments @($spec.Arguments) -TaskExists $exists -Confirmed $true
            if (-not $plan) { continue }
            try {
                if (-not $existsKnown) {
                    Write-Host '提示：查询计划任务失败，无法确认是否已存在同名任务；本次不带 -TaskForce。' -ForegroundColor Yellow
                }
                if ($spec.RequiresAdmin -and -not $script:IsAdmin) {
                    $p = Invoke-Elevated -Arguments $plan.Arguments
                    if ($p -and $p.ExitCode -ne 0) { Write-Host '管理员窗口返回非 0，请查看输出。' -ForegroundColor Yellow }
                } else {
                    $exit = Invoke-Child -FilePath $MainScript -Arguments $plan.Arguments
                    Write-Host "退出码：$exit" -ForegroundColor $(if ($exit -eq 0) { 'Green' } else { 'Yellow' })
                }
            } catch {
                Write-Host "安装任务失败：$($_.Exception.Message)" -ForegroundColor Red
            }
            Pause-Action
            continue
        }

        # 卸载：存在 AutoApply 任务且不是管理员时，走提权；失败不退出菜单
        if ($spec.Arguments -contains '-UninstallTask') {
            $hasAuto = [bool](-not $info.QueryFailed -and
                @($info.Tasks | Where-Object { $_.TaskName -like '*AutoApply' }).Count -gt 0)
            try {
                if ($hasAuto -and -not $script:IsAdmin) {
                    $p = Invoke-Elevated -Arguments @('-UninstallTask')
                    if ($p -and $p.ExitCode -ne 0) { Write-Host '管理员窗口返回非 0，请查看输出。' -ForegroundColor Yellow }
                } else {
                    if ($info.QueryFailed -and -not $script:IsAdmin) {
                        Write-Host '提示：无法确认任务状态；卸载 AutoApply 任务需要管理员，可能失败。' -ForegroundColor Yellow
                    }
                    $exit = Invoke-Child -FilePath $MainScript -Arguments @('-UninstallTask')
                    Write-Host "退出码：$exit" -ForegroundColor $(if ($exit -eq 0) { 'Green' } else { 'Yellow' })
                }
            } catch {
                Write-Host "卸载任务失败：$($_.Exception.Message)" -ForegroundColor Red
            }
            Pause-Action
            continue
        }

        [void](Invoke-Choice -Spec $spec)
    }
}

function Show-ImportMenu {
    while ($true) {
        $spec = Read-MenuChoice -Menu Import
        if (-not $spec -or $spec.Kind -eq 'Back') { return }
        [void](Invoke-Choice -Spec $spec)
    }
}

function Invoke-Choice {
    param($Spec)
    if ($Spec.Kind -eq 'Exit') { return $false }
    switch ($Spec.Kind) {
        'Submenu' {
            switch ($Spec.Target) {
                'Import' { Show-ImportMenu }
                'Cfst' { Show-CfstMenu }
                'Task' { Show-TaskMenu }
            }
            return $true
        }
        'Script' { Invoke-ScriptAction -Spec $Spec }
        'Import' { Invoke-ImportAction -Spec $Spec }
        'EditDomains' { Invoke-EditDomains }
        'DomainOverview' { Show-DomainOverview }
        'ViewReport' { Show-Report }
        'OpenReadme' { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f (Join-Path $Root 'README.md')) }
    }
    Pause-Action
    return $true
}

if ($Action -and $Elevated) {
    Write-Host '-Action 和 -Elevated 不能同时使用。' -ForegroundColor Red
    exit 2
}

# 提权子窗口专用：跑完指定参数后提示按 Enter，窗口随即关闭
if ($Elevated) {
    $runArgs = @($ElevatedArgs -split '\s+' | Where-Object { $_ })
    $argsLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $MainScript
    $extra = ConvertTo-ArgumentString -Arguments $runArgs
    if ($extra) { $argsLine += ' ' + $extra }
    # 统一用启动时解析好的 pwsh；[Environment]::ProcessPath 在 PowerShell 7.0 上不存在
    $p = Start-Process -FilePath $script:Pwsh -NoNewWindow -Wait -PassThru -WorkingDirectory $Root -ArgumentList $argsLine
    Write-Host ''
    Write-Host "执行完毕（退出码 $($p.ExitCode)），按 Enter 关闭此窗口并返回主菜单。" -ForegroundColor Green
    [void](Read-Host)
    exit $p.ExitCode
}

if ($Action) {
    $spec = Get-MenuActionSpec -Menu Main -Key $Action
    if (-not $spec -or $spec.Kind -in @('Exit', 'Submenu')) {
        Write-Host "不支持的 -Action：$Action（可用：2/5/6/7/8/9/10）" -ForegroundColor Red
        exit 2
    }
    [void](Invoke-Choice -Spec $spec)
    exit 0
}

try {
    $firstMenu = $true
    while ($true) {
        # 首次打开按状态定位；执行过动作或从子菜单返回后默认停在“退出”，
        # 避免连续按 Enter 重复启动 DryRun/写入。
        $spec = Read-MenuChoice -Menu Main -Returning:(-not $firstMenu)
        $firstMenu = $false
        if (-not $spec -or $spec.Kind -eq 'Exit') { break }
        $keep = Invoke-Choice -Spec $spec
        if (-not $keep) { break }
    }
} catch {
    Write-Host "菜单出错：$($_.Exception.Message)" -ForegroundColor Red
    Pause-Menu
    exit 1
}
exit 0
