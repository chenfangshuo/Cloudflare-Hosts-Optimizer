#Requires -Version 7.0
<#
    控制台输出：步骤标题 + 单行转轮动画。

    为什么不用 Write-Progress：它在传统控制台里会在窗口右上方画一条进度条，
    和脚本自己打印的行交错后会留下括号/方块残影。

    动画实现：后台 thread job 每 150ms 重绘一行，主线程通过同步哈希表更新文字；
    两边共用一把锁，写普通行（Write-StatusLine / Say）之前先擦掉动画行。
    擦行优先用 ANSI ESC[2K（整行清除，不受中文字宽影响），终端不支持时按显示宽度补空格。
    输出被重定向（计划任务、管道）或没有控制台时自动禁用，不影响 last-report.txt。

    步骤：Start-Step 打印一行 [n/总步数] 名称 · 预计时间，Complete-Step 打印实际用时。
    转轮行只放帧和进度数字，不放步骤名（步骤名在上面的标题行里）。
#>

$script:ProgressLock = [object]::new()
$script:ProgressState = $null
$script:ProgressJob = $null
$script:ProgressVt = $false
$script:StepNumber = 0
$script:StepTotal = 0
$script:StepWatch = $null

# 控制台显示宽度：东亚宽字符按 2 列算，否则补空格擦除时会留下半截字符
function Get-DisplayWidth {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text = '')
    if (-not $Text) { return 0 }
    $wide = [regex]::Matches($Text, '[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹯＀-｠￠-￦]').Count
    return $Text.Length + $wide
}

function Format-TaskSpinnerText {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Label = '',
        [AllowEmptyString()][string]$Detail = ''
    )
    if ($Label -and $Detail) { return "$Label · $Detail" }
    if ($Detail) { return $Detail }
    return $Label
}

function Format-Duration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][TimeSpan]$Duration)
    $s = [int][math]::Round($Duration.TotalSeconds)
    if ($s -lt 60) { return "$s 秒" }
    return "{0} 分 {1} 秒" -f [int][math]::Floor($s / 60), ($s % 60)
}

function Test-TaskSpinnerActive {
    [CmdletBinding()]
    param()
    return ($null -ne $script:ProgressState)
}

function Test-ProgressInteractive {
    [CmdletBinding()]
    param()
    # 诊断用：CFO_SPINNER=1 强制开（终端被误判成重定向时），=0 强制关
    if ($env:CFO_SPINNER -eq '1') { return $true }
    if ($env:CFO_SPINNER -eq '0') { return $false }
    try {
        if ([Console]::IsOutputRedirected) { return $false }
        return ([Console]::WindowWidth -gt 0)
    } catch {
        return $false
    }
}

# 调用方必须已经持有 ProgressLock。VT 可用时整行清除，否则按上次画出的宽度补空格。
function Write-ClearProgressLine {
    [CmdletBinding()]
    param([hashtable]$State)
    if ($script:ProgressVt) {
        [Console]::Write("`e[2K`r")
        return
    }
    $width = if ($State) { [int]$State.LastWidth } else { 0 }
    if ($width -gt 0) { [Console]::Write("`r" + (' ' * $width) + "`r") }
    else { [Console]::Write("`r") }
    if ($State) { $State.LastWidth = 0 }
}

# 所有普通控制台输出都走这里：有动画行就先擦掉，避免两行叠在一起。
function Write-StatusLine {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text = '',
        [string]$Color = 'Gray'
    )
    if (-not $script:ProgressState) {
        Write-Host $Text -ForegroundColor $Color
        return
    }
    [System.Threading.Monitor]::Enter($script:ProgressLock)
    try {
        Write-ClearProgressLine -State $script:ProgressState
        Write-Host $Text -ForegroundColor $Color
    } finally {
        [System.Threading.Monitor]::Exit($script:ProgressLock)
    }
}

function Invoke-WithProgressClear {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Action)
    if (-not $script:ProgressState) { & $Action; return }
    [System.Threading.Monitor]::Enter($script:ProgressLock)
    try {
        Write-ClearProgressLine -State $script:ProgressState
        & $Action
    } finally {
        [System.Threading.Monitor]::Exit($script:ProgressLock)
    }
}

function Clear-TaskSpinnerLine {
    [CmdletBinding()]
    param()
    if (-not $script:ProgressState) { return }
    [System.Threading.Monitor]::Enter($script:ProgressLock)
    try { Write-ClearProgressLine -State $script:ProgressState }
    finally { [System.Threading.Monitor]::Exit($script:ProgressLock) }
}

function Start-Step {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Estimate = '',
        [ValidateRange(0, 20)][int]$Total = 0
    )
    if ($Total -gt 0) { $script:StepTotal = $Total }
    $script:StepNumber++
    Say ''
    $line = if ($script:StepTotal -gt 0) {
        "[{0}/{1}] {2}" -f $script:StepNumber, $script:StepTotal, $Name
    } else {
        "> $Name"
    }
    if ($Estimate) { $line += "  ·  $Estimate" }
    Say $line 'Cyan'
    $script:StepWatch = [System.Diagnostics.Stopwatch]::StartNew()
}

function Complete-Step {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Note = '')
    if (-not $script:StepWatch) { return }
    $script:StepWatch.Stop()
    $text = "完成 · 用时 $(Format-Duration -Duration $script:StepWatch.Elapsed)"
    if ($Note) { $text += " · $Note" }
    Say $text 'DarkGray'
    $script:StepWatch = $null
}

function Start-TaskSpinner {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Label = '')
    if (-not (Test-ProgressInteractive)) {
        Write-Verbose "动画：已禁用（输出被重定向或没有控制台；可用 `$env:CFO_SPINNER='1' 强制开启）"
        return
    }
    if ($script:ProgressState) { Update-TaskSpinner -Label $Label; return }
    if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
        Write-Verbose '动画：缺少 Start-ThreadJob，跳过'
        return
    }

    $script:ProgressVt = $false
    try { $script:ProgressVt = [bool]$Host.UI.SupportsVirtualTerminal } catch { }

    $state = [hashtable]::Synchronized(@{
            Running    = $true
            Label      = $Label
            Detail     = ''
            Text       = $Label
            LastWidth  = 0
            StartTicks = [Environment]::TickCount64
        })
    $script:ProgressState = $state

    # 子 runspace 不继承函数，ScriptBlock 又没法通过 -ArgumentList 传过去，
    # 所以宽字符计算直接写在任务里（和 Get-DisplayWidth 保持一致）。
    try {
        $script:ProgressJob = Start-ThreadJob -ArgumentList $state, $script:ProgressLock, $script:ProgressVt -ScriptBlock {
            param($s, $lock, $vt)
            function Get-SpinnerWidth {
                param([string]$Text = '')
                if (-not $Text) { return 0 }
                $wide = [regex]::Matches($Text, '[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹯＀-｠￠-￦]').Count
                return $Text.Length + $wide
            }
            $frames = @('|', '/', '-', '\')
            $i = 0
            while ($true) {
                $stop = $false
                [System.Threading.Monitor]::Enter($lock)
                try {
                    if (-not $s.Running) {
                        $stop = $true
                    } else {
                        $frame = $frames[$i % 4]
                        if ($s.Text) {
                            $line = "$frame $($s.Text)"
                        } else {
                            # 没有具体进度时至少显示已用时间（CFST 那种长时间静默）
                            $sec = [int](([Environment]::TickCount64 - [long]$s.StartTicks) / 1000)
                            $elapsed = if ($sec -ge 60) { '{0}:{1:00}' -f [int][math]::Floor($sec / 60), ($sec % 60) } else { "${sec}s" }
                            $line = "$frame $elapsed"
                        }
                        if ($vt) {
                            [Console]::Write("`e[2K`r" + $line)
                        } else {
                            $max = 0
                            try { $max = [Console]::WindowWidth - 1 } catch { }
                            $width = Get-SpinnerWidth -Text $line
                            # 超宽时按字符截断，避免自动换行把上一行顶上去
                            if ($max -gt 1 -and $line.Length -gt $max) {
                                $line = $line.Substring(0, $max)
                                $width = Get-SpinnerWidth -Text $line
                            }
                            [Console]::Write("`r" + $line)
                            if ($s.LastWidth -gt $width) { [Console]::Write(' ' * ($s.LastWidth - $width)) }
                            $s.LastWidth = $width
                        }
                        $i++
                    }
                } finally {
                    [System.Threading.Monitor]::Exit($lock)
                }
                if ($stop) { break }
                Start-Sleep -Milliseconds 150
            }
        }
    } catch {
        # 动画起不来不能影响主流程
        Write-Verbose "动画：启动失败：$($_.Exception.Message)"
        $script:ProgressState = $null
        $script:ProgressJob = $null
        return
    }
    Write-Verbose "动画：启动（job $($script:ProgressJob.Id)）"
}

# Ctrl+C 提示。PowerShell 脚本里没有可用的中断回调：主线程卡在并行探测时，
# 只能靠 .NET 的 CancelKeyPress 处理器即时说话。Add-Type 有一次性编译开销，
# 所以只在进入长阶段前安装，且失败不影响主流程。
function Install-CancelNotice {
    [CmdletBinding()]
    param([string]$Message = '收到 Ctrl+C，正在停止：等待进行中的网络请求结束（可能几秒到几十秒）…')
    if (-not (Test-ProgressInteractive)) { return }
    try {
        if (-not ('CfoConsoleNotice' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
public static class CfoConsoleNotice
{
    private static bool installed;
    private static string message = "";

    public static void Install(string text)
    {
        message = text;
        if (installed) return;
        installed = true;
        Console.CancelKeyPress += (s, e) =>
        {
            try
            {
                Console.Write("\r" + new string(' ', 120) + "\r" + message + Environment.NewLine);
            }
            catch { }
        };
    }
}
'@
        }
        [CfoConsoleNotice]::Install($Message)
    } catch {
        # 提示装不上就算了，不影响中断本身
    }
}

function Update-TaskSpinner {
    [CmdletBinding()]
    param(
        [string]$Label,
        [AllowEmptyString()][string]$Detail
    )
    if (-not $script:ProgressState) { return }
    if ($PSBoundParameters.ContainsKey('Label')) { $script:ProgressState.Label = $Label }
    if ($PSBoundParameters.ContainsKey('Detail')) { $script:ProgressState.Detail = $Detail }
    $script:ProgressState.Text = Format-TaskSpinnerText -Label $script:ProgressState.Label -Detail $script:ProgressState.Detail
}

function Stop-TaskSpinner {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Message = '',
        [string]$Color = 'Gray'
    )
    if (-not $script:ProgressState) {
        if ($Message) { Say $Message $Color }
        return
    }
    $state = $script:ProgressState
    [System.Threading.Monitor]::Enter($script:ProgressLock)
    try { $state.Running = $false }
    finally { [System.Threading.Monitor]::Exit($script:ProgressLock) }

    if ($script:ProgressJob) {
        try { Wait-Job -Job $script:ProgressJob -Timeout 3 | Out-Null } catch { }
        Remove-Job -Job $script:ProgressJob -Force -ErrorAction SilentlyContinue
    }

    [System.Threading.Monitor]::Enter($script:ProgressLock)
    try {
        Write-ClearProgressLine -State $state
        $state.LastWidth = 0
    } finally {
        [System.Threading.Monitor]::Exit($script:ProgressLock)
    }

    $script:ProgressState = $null
    $script:ProgressJob = $null
    if ($Message) { Say $Message $Color }
}
