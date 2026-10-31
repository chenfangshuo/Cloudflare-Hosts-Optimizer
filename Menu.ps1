#Requires -Version 7.0
<#
    双击 Start.bat 后进入的菜单（TUI：上下箭头选择）。

    - 交互终端里使用备用屏幕缓冲区（ESC[?1049h）画菜单，退出后原样恢复滚动内容；
      动作执行前会先退出备用屏幕，输出留在正常屏幕上。
    - 输出/输入被重定向、或终端不支持 VT 时，自动退回编号输入。
      `$env:CFO_PLAIN_MENU='1'` 可强制使用编号输入。
    - 不能用 dot-source 调主脚本——它末尾有 exit，会把菜单一起结束。
    - 写入 hosts / 回滚 / AutoApply 任务需要管理员时，用 Start-Process -Verb RunAs 单独提权。
#>
[CmdletBinding()]
param([string]$Action)

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

function Get-PwshPath {
    $p = [Environment]::ProcessPath
    if ($p -and (Test-Path -LiteralPath $p) -and ([IO.Path]::GetFileName($p) -match '^pwsh(-preview)?\.exe$')) { return $p }
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
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
    $argLine = '-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}"' -f $MainScript
    if ($Arguments.Count -gt 0) { $argLine += ' ' + ($Arguments -join ' ') }
    Write-Host '会先弹出 UAC，然后打开一个管理员窗口；完成后关闭那个窗口即可回到菜单。' -ForegroundColor Yellow
    try {
        Start-Process -FilePath $script:Pwsh -Verb RunAs -Wait -WorkingDirectory $Root -ArgumentList $argLine
        return $true
    } catch {
        $code = $null
        try { $code = $_.Exception.NativeErrorCode } catch { }
        if ($code -eq 1223 -or $_.Exception.Message -match '1223|cancel|取消') {
            Write-Host '已取消提权。' -ForegroundColor Yellow
        } else {
            Write-Host "提权失败：$($_.Exception.Message)" -ForegroundColor Red
        }
        return $false
    }
}

function Get-MenuHeader {
    $st = Get-MenuStatus -DomainsFile $DomainsFile -HostsPath $HostsPath -CfstDir $CfstDir -ReportPath $ReportPath
    $dot = [string][char]0x00B7
    $title = if ($script:Version) { "Cloudflare-Hosts-Optimizer $($script:Version)" } else { 'Cloudflare-Hosts-Optimizer' }
    $hostsText = if ($st.HostsError) { 'hosts 结构异常' } else { "hosts 已写入 $($st.Managed) 个" }
    $invalidText = if ($st.Invalid -gt 0) { "（$($st.Invalid) 个非法）" } else { '' }
    $lastText = if ($st.LastRun) { "$dot 上次运行 $($st.LastRun)" } else { '' }
    $lines = @(
        $title
        "域名 $($st.Listed) 个$invalidText $dot $hostsText $dot CFST $($st.Cfst) $lastText"
    )
    if (-not $script:IsAdmin) {
        $lines += '当前是普通权限；写入 hosts / 回滚时会单独弹出 UAC。'
    }
    return $lines
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
    param([string]$Menu, [string[]]$Header = @())
    $items = @(Get-MenuItems -Menu $Menu)
    if ($items.Count -eq 0) { return $null }
    $selected = 0
    $top = -1
    $frameCount = 0
    try {
        while ($true) {
            $footer = '↑↓ 选择 · Enter 确认 · Esc 返回'
            $lines = @(Format-MenuFrame -Header $Header -Items $items -SelectedIndex $selected -Footer $footer)
            $selLine = $Header.Count + 1 + $selected
            # 回到菜单块顶部重画；窗口缩放等导致位置失效时退回“从当前位置画”
            if ($top -ge 0) {
                try { [Console]::SetCursorPosition(0, $top) }
                catch { $top = -1 }
            }
            if ($top -lt 0) {
                try { $top = [Console]::CursorTop } catch { $top = 0 }
            }
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($i -eq $selLine) { [Console]::Write("`e[7m" + $lines[$i] + "`e[K`e[0m`r`n") }
                else { [Console]::Write($lines[$i] + "`e[K`r`n") }
            }
            [Console]::Write("`e[J")
            $frameCount = $lines.Count
            try { $top = [Math]::Max(0, [Console]::CursorTop - $frameCount) } catch { }
            $key = [Console]::ReadKey($true)
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
    param([string]$Menu, [string[]]$ExtraHeader = @())
    $header = @(Get-MenuHeader) + @($ExtraHeader)
    if ($script:Tui) {
        return Show-TuiMenu -Menu $Menu -Header $header
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
        [void](Invoke-Elevated -Arguments @($Spec.Arguments))
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
    $time = (Get-Item -LiteralPath $ReportPath).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
    Write-Host "报告：$ReportPath（$time）" -ForegroundColor DarkGray
    Get-Content -LiteralPath $ReportPath -Tail 80 | ForEach-Object { Write-Host $_ }
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
        $spec = Read-MenuChoice -Menu Task
        if (-not $spec -or $spec.Kind -eq 'Back') { return }
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

if ($Action) {
    $spec = Get-MenuActionSpec -Menu Main -Key $Action
    if (-not $spec -or $spec.Kind -in @('Exit', 'Submenu')) {
        Write-Host "不支持的 -Action：$Action（可用：1/3/4/5/6/9/10）" -ForegroundColor Red
        exit 2
    }
    [void](Invoke-Choice -Spec $spec)
    exit 0
}

try {
    while ($true) {
        $spec = Read-MenuChoice -Menu Main
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
