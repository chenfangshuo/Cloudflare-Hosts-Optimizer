# 定时运行

CF 路由、运营商互联和 zone 白名单都会变，建议每 1–2 周重跑一次。这里给三种用法：

| 方案 | 是否改 hosts | 需要管理员 | 适合 |
| --- | --- | --- | --- |
| A：定时 DryRun | 否 | 否 | 想先看结果、人工确认 |
| B：`-Plan` + 自己的监控 | 否 | 否 | 给面板/脚本消费 JSON |
| C：定时自动写入 | 是 | 是 | 已经稳定跑过几次、不想每次手动 |

## 先说明：下面的代码怎么运行

下面的 `Register-*.ps1` 是**注册计划任务的一次性脚本**，不是每次都要执行的命令：

1. 用记事本/VS Code 新建文件，把代码粘进去；
2. 改掉第一行的 `$root`（脚本所在目录，必须是绝对路径）；
3. 保存为 `Register-DryRunTask.ps1` 或 `Register-AutoApplyTask.ps1`；
4. 打开 PowerShell，运行：

```powershell
pwsh -NoProfile -File .\Register-DryRunTask.ps1
```

5. 用 `Start-ScheduledTask` 立即测试一次，再去任务计划程序或报告里看结果。

`domains.txt` 必须已经在 `$root` 下；计划任务不会帮你创建它。

如果任务启动失败，先检查 `pwsh.exe` 路径：

```powershell
(Get-Command pwsh).Source
```

把 `-Execute 'pwsh.exe'` 换成上面的完整路径即可（计划任务的 PATH 可能和你的终端不同）。

## 方案 A：定时 DryRun（保守，推荐）

保存为 `Register-DryRunTask.ps1`，用**普通 PowerShell**运行一次，不需要管理员：

```powershell
$root = 'C:\path\to\Cloudflare-Hosts-Optimizer'
$report = Join-Path $root 'last-report.txt'

$action = New-ScheduledTaskAction -Execute 'pwsh.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$root\Cloudflare-Hosts-Optimizer.ps1`" -DryRun -ReportPath `"$report`""

$trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 2 -DaysOfWeek Sunday -At 10am

Register-ScheduledTask -TaskName 'Cloudflare-Hosts-Optimizer DryRun' `
  -Action $action -Trigger $trigger `
  -Description '每两周生成一次优选计划，不修改 hosts' -Force
```

立即测试并查看结果：

```powershell
Start-ScheduledTask -TaskName 'Cloudflare-Hosts-Optimizer DryRun'
Get-Content .\last-report.txt
```

确认报告没问题后，再用**管理员 PowerShell**手动正式写入。这个方案的缺点就是需要你手动执行最后一步。

## 方案 B：`-Plan` + 自己的监控

需要给面板/脚本消费结果时，用 JSON：

```powershell
.\Cloudflare-Hosts-Optimizer.ps1 -Plan -PlanPath .\plan.json
```

`plan.json` 里的 `Decisions`、`Plan`、`Warnings` 可以直接被其他程序读取。它同样不会
修改 hosts，也不需要管理员。

## 方案 C：定时自动写入 hosts（有风险）

适合已经手动跑过 2–3 次、域名列表不常变、能接受“出问题时自己回滚”的人。
它仍然逐站验证、拒绝 1034、未达改善门槛就保留旧映射，不是盲目写入；但计划任务运行时
你不在场，所以风险要自己承担。

保存为 `Register-AutoApplyTask.ps1`，用**管理员 PowerShell**运行一次：

```powershell
$root = 'C:\path\to\Cloudflare-Hosts-Optimizer'
$report = Join-Path $root 'last-report.txt'

$action = New-ScheduledTaskAction -Execute 'pwsh.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$root\Cloudflare-Hosts-Optimizer.ps1`" -ReportPath `"$report`""

$trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 2 -DaysOfWeek Sunday -At 4am

# 以当前管理员账户运行；只在登录时执行（Interactive），不保存密码
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
  -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName 'Cloudflare-Hosts-Optimizer AutoApply' `
  -Action $action -Trigger $trigger -Principal $principal `
  -Description '每两周自动优选并写入 hosts（有风险，保留报告和备份）' -Force
```

立即测试一次：

```powershell
Start-ScheduledTask -TaskName 'Cloudflare-Hosts-Optimizer AutoApply'
Get-Content .\last-report.txt
```

确认站点正常；如果某个站打不开，先回滚：

```powershell
.\Cloudflare-Hosts-Optimizer.ps1 -Rollback
```

### 风险（务必看）

- **你不在场**：任务运行时如果某个 zone 返回 1034、或选到不合适的 IP，站点可能短暂
  打不开；工具会保留旧映射/备份，但需要你事后处理。
- **不是持续监控**：它只是每两周刷新一次，不能保证这期间 CF 路由不变。
- **环境依赖**：笔记本休眠、断网、代理/TUN 开启时任务可能失败或中止（检测到 TUN
  默认中止，这是有意的）。
- **账户要求**：写 hosts 需要管理员；任务以当前管理员账户运行，**不要用 SYSTEM**。
- **不要乱加参数**：不要加 `-Force` 或 `-DropUnreachable`，除非你清楚后果。
- **只在登录时运行**：`Interactive` 不会在你注销后执行；如果要注销后也跑，需要保存
  凭据，风险和复杂度都更高，不推荐。

### 降低风险

- 频率保持 2 周一次，不要每天跑；
- 时间选凌晨或不用网的时候；
- 固定 `-ReportPath`，每隔一段时间看一眼；
- 先手动跑 2–3 次，确认 `domains.txt` 稳定；
- 出问题用 `-Rollback`，备份在 `%ProgramData%\Cloudflare-Hosts-Optimizer\backup`。

## 不管用哪种方案

- 计划任务里的路径都写绝对路径；
- 工具的所有探测都强制直连，不需要给计划任务配代理；
- 用 `-HostsPath` 做沙箱时，备份在独立的 `targets\<hash>` 子目录，不会和系统 hosts
  的备份混在一起。
