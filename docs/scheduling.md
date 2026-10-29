# 定时运行

CF 路由和运营商互联会变，建议每 1–2 周重跑一次。推荐“**非管理员 DryRun + 人工确认**”，
不要把自动写 hosts 的任务交给计划任务。

## 方案 A：计划任务跑 DryRun

以当前用户身份创建（不需要管理员）：

```powershell
$root = 'C:\path\to\pt-cf-optimize'
$report = Join-Path $root 'last-report.txt'

$action = New-ScheduledTaskAction -Execute 'pwsh.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$root\pt-cf-optimize.ps1`" -DryRun -ReportPath `"$report`""

$trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 2 -DaysOfWeek Sunday -At 10am

Register-ScheduledTask -TaskName 'pt-cf-optimize DryRun' `
  -Action $action -Trigger $trigger `
  -Description '每两周生成一次优选计划，不修改 hosts' -Force
```

之后看 `last-report.txt`；确认没问题，再用管理员 PowerShell 手动正式写入。

## 方案 B：`-Plan` + 自己的监控

需要给面板/脚本消费时，用 JSON：

```powershell
.\pt-cf-optimize.ps1 -Plan -PlanPath .\plan.json
```

`plan.json` 里的 `Decisions`、`Plan`、`Warnings` 可以直接被其他程序读取。它同样不会
修改 hosts，也不需要管理员。

## 注意

- 不要用 SYSTEM 或管理员计划任务自动写入 hosts；出问题时没有人工确认。
- 计划任务里的路径要写绝对路径；`domains.txt` 放在脚本目录。
- 工具的所有探测都强制直连，不需要给计划任务配代理。
- 如果使用 `-HostsPath` 做沙箱，备份会在独立的 `targets\<hash>` 子目录，不会和系统
  hosts 的备份混在一起。
