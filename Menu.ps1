#Requires -Version 7.0
<#
    双击 Start.bat 后进入的菜单。
    只负责显示、读输入、调用子进程；动作定义在 lib\Menu.ps1。

    注意：不能用 dot-source 调主脚本——它末尾有 exit，会把菜单一起结束。
    写入 hosts / 回滚 / AutoApply 任务需要管理员时，用 Start-Process -Verb RunAs 单独提权。
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

$script:Pwsh = Get-PwshPath

function Pause-Menu {
    [void](Read-Host '按回车返回菜单')
}

function Confirm-Action {
    param([string]$Label)
    $ans = Read-Host "确认执行「$Label」？[y/N]"
    return ($ans -match '^[Yy]')
}

function Invoke-Child {
    param([string]$FilePath, [string[]]$Arguments = @())
    & $script:Pwsh -NoProfile -ExecutionPolicy Bypass -File $FilePath @Arguments
    return $LASTEXITCODE
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

function Write-Header {
    $version = ''
    try {
        $m = Select-String -LiteralPath $MainScript -Pattern "ScriptVersion\s*=\s*'([^']+)'" | Select-Object -First 1
        if ($m) { $version = $m.Matches[0].Groups[1].Value }
    } catch { }
    $st = Get-MenuStatus -DomainsFile $DomainsFile -HostsPath $HostsPath -CfstDir $CfstDir -ReportPath $ReportPath

    $title = if ($version) { "Cloudflare-Hosts-Optimizer $version" } else { 'Cloudflare-Hosts-Optimizer' }
    $dot = [string][char]0x00B7
    $hostsText = if ($st.HostsError) { 'hosts 结构异常' } else { "hosts 已写入 $($st.Managed) 个" }
    $invalidText = if ($st.Invalid -gt 0) { "（$($st.Invalid) 个非法）" } else { '' }
    $lastText = if ($st.LastRun) { "$dot 上次运行 $($st.LastRun)" } else { '' }
    $status = "域名 $($st.Listed) 个$invalidText $dot $hostsText $dot CFST $($st.Cfst) $lastText"

    Write-Host ''
    Write-Host $title -ForegroundColor Cyan
    Write-Host $status -ForegroundColor DarkGray
    if (-not (Test-IsAdmin)) {
        Write-Host '当前是普通权限；写入 hosts / 回滚时会单独弹出 UAC。' -ForegroundColor DarkGray
    }
}

function Show-Menu {
    param([string]$Menu)
    Write-Host ''
    foreach ($i in (Get-MenuItems -Menu $Menu)) {
        Write-Host ("  {0}) {1}" -f $i.Key, $i.Label)
    }
}

function Invoke-ScriptAction {
    param($Spec, [switch]$NoPause)
    if ($Spec.Confirm -and -not (Confirm-Action $Spec.Label)) { return }
    if ($Spec.RequiresAdmin -and -not (Test-IsAdmin)) {
        [void](Invoke-Elevated -Arguments @($Spec.Arguments))
        if (-not $NoPause) { Pause-Menu }
        return
    }
    $exit = Invoke-Child -FilePath $MainScript -Arguments @($Spec.Arguments)
    $color = if ($exit -eq 0) { 'Green' } else { 'Yellow' }
    Write-Host "退出码：$exit" -ForegroundColor $color
    if (-not $NoPause) { Pause-Menu }
}

function Invoke-ImportAction {
    param($Spec, [switch]$NoPause)
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
        if (-not $NoPause) { Pause-Menu }
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
    if (-not $NoPause) { Pause-Menu }
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
        Write-Host ''
        Write-Host "CFST：$stateText" -ForegroundColor Cyan
        Show-Menu -Menu Cfst
        $key = Read-Host '请选择'
        $spec = Get-MenuActionSpec -Menu Cfst -Key $key
        if (-not $spec) { Write-Host '无效选项' -ForegroundColor Yellow; continue }
        if ($spec.Kind -eq 'Back') { return }
        if ($spec.Kind -eq 'OpenUrl') {
            Start-Process $spec.Target
            Write-Host '已在浏览器打开下载页；下载后选「从本地 zip 安装」。' -ForegroundColor DarkGray
            Pause-Menu
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
            Pause-Menu
        }
    }
}

function Show-TaskMenu {
    while ($true) {
        Show-Menu -Menu Task
        $key = Read-Host '请选择'
        $spec = Get-MenuActionSpec -Menu Task -Key $key
        if (-not $spec) { Write-Host '无效选项' -ForegroundColor Yellow; continue }
        if ($spec.Kind -eq 'Back') { return }
        Invoke-ScriptAction -Spec $spec
    }
}

function Show-ImportMenu {
    while ($true) {
        Show-Menu -Menu Import
        $key = Read-Host '请选择'
        $spec = Get-MenuActionSpec -Menu Import -Key $key
        if (-not $spec) { Write-Host '无效选项' -ForegroundColor Yellow; continue }
        switch ($spec.Kind) {
            'Back' { return }
            'EditDomains' { Invoke-EditDomains; Pause-Menu }
            'Import' { Invoke-ImportAction -Spec $spec }
        }
    }
}

function Invoke-Choice {
    param($Spec, [switch]$NoPause)
    switch ($Spec.Kind) {
        'Exit' { return $false }
        'Submenu' {
            switch ($Spec.Target) {
                'Import' { Show-ImportMenu }
                'Cfst' { Show-CfstMenu }
                'Task' { Show-TaskMenu }
            }
        }
        'Script' { Invoke-ScriptAction -Spec $Spec -NoPause:$NoPause }
        'Import' { Invoke-ImportAction -Spec $Spec -NoPause:$NoPause }
        'EditDomains' { Invoke-EditDomains; if (-not $NoPause) { Pause-Menu } }
        'DomainOverview' { Show-DomainOverview; if (-not $NoPause) { Pause-Menu } }
        'ViewReport' { Show-Report; if (-not $NoPause) { Pause-Menu } }
        'OpenReadme' { Start-Process (Join-Path $Root 'README.md') }
    }
    return $true
}

if ($Action) {
    $spec = Get-MenuActionSpec -Menu Main -Key $Action
    if (-not $spec -or $spec.Kind -in @('Exit', 'Submenu')) {
        Write-Host "不支持的 -Action：$Action（可用：1/3/4/5/6/9/10）" -ForegroundColor Red
        exit 2
    }
    [void](Invoke-Choice -Spec $spec -NoPause)
    exit 0
}

try {
    while ($true) {
        Write-Header
        Show-Menu -Menu Main
        $key = Read-Host '请选择'
        $spec = Get-MenuActionSpec -Menu Main -Key $key
        if (-not $spec) { Write-Host '无效选项' -ForegroundColor Yellow; continue }
        $keep = Invoke-Choice -Spec $spec
        if (-not $keep) { break }
    }
} catch {
    Write-Host "菜单出错：$($_.Exception.Message)" -ForegroundColor Red
    Pause-Menu
    exit 1
}
exit 0
