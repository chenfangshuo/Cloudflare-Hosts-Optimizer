# 定时运行

CF 路由、运营商互联和 zone 白名单都会变，建议每 1–2 周重跑一次。脚本内置计划任务注册，
不用再手写 `Register-ScheduledTask`。

| 模式 | 是否改 hosts | 需要管理员 | 适合 |
| --- | --- | --- | --- |
| `DryRun`（默认） | 否，只写 `last-report.txt` | 否 | 想先看结果、人工确认 |
| `AutoApply` | 是 | 是（注册和运行都需要） | 已经稳定手动跑过几次、不想每次手动 |

## 一条命令安装

**DryRun**（推荐，普通 PowerShell 即可）：

```powershell
.\Cloudflare-Hosts-Optimizer.ps1 -InstallTask -TaskMode DryRun
```

默认每 14 天运行一次，时间 10:00。想改频率和时间：

```powershell
.\Cloudflare-Hosts-Optimizer.ps1 -InstallTask -TaskMode DryRun -TaskIntervalDays 7 -TaskAt '09:30'
```

**AutoApply**（管理员 PowerShell）：

```powershell
.\Cloudflare-Hosts-Optimizer.ps1 -InstallTask -TaskMode AutoApply
```

AutoApply 默认 04:00 运行。安装前会校验 `domains.txt` 存在且没有非法项——否则任务每次
都会失败。

## 查看

```powershell
Get-ScheduledTask -TaskName 'Cloudflare-Hosts-Optimizer*' | Get-ScheduledTaskInfo
```

或直接跑 `.\Cloudflare-Hosts-Optimizer.ps1 -Doctor`，它会把任务状态、下次运行时间和上次
结果列在「计划」一组里，并检查任务指向的脚本是否还存在。

立即测试一次：

```powershell
Start-ScheduledTask -TaskName 'Cloudflare-Hosts-Optimizer DryRun'
Get-Content .\last-report.txt
```

## 卸载

```powershell
.\Cloudflare-Hosts-Optimizer.ps1 -UninstallTask
```

不带 `-TaskName` 时删除 DryRun 和 AutoApply 两个默认任务；只删一个就加
`-TaskName 'Cloudflare-Hosts-Optimizer AutoApply'`。任务本来就不存在时视为成功。

## 参数

| 参数 | 说明 |
| --- | --- |
| `-TaskMode` | `DryRun`（默认）或 `AutoApply` |
| `-TaskIntervalDays` | 间隔天数，1–30，默认 14 |
| `-TaskAt` | 运行时间 `HH:mm`，默认 DryRun 10:00、AutoApply 04:00 |
| `-TaskName` | 自定义任务名；`-UninstallTask` 时只删指定的一个 |
| `-TaskForce` | 覆盖已存在的同名任务（与全局 `-Force` 无关） |

## 会被带进任务的参数

注册任务时，命令行里显式给出的这些参数会一并写进任务：

`-NoCfst`、`-ExperimentalRanges`、`-NoColoCache`、`-ColoCachePath`、
`-ColoCacheMaxAgeDays`、`-TopN`、`-CandidatesPerDomain`、`-BackfillCandidates`、
`-MaxDomainProbes`、`-VerifyTimeoutSec`、`-MinImprovementPct`、`-MinImprovementMs`、
`-DomainsFile`、`-CfstPath`、`-SpeedTestUrl`、`-ProbeUrl`、`-ScanSamples`、
`-MaxCandidates`、`-ThroughputCandidates`、`-ThroughputSamples`、`-ThroughputBytes`、
`-RefineTop`、`-VerifyDelayMs`、`-CheckResolved`。

`-Force`、`-DropUnreachable`、`-Prune` 永远不会写进任务；`-Domains` 也不支持（域名数组
没法安全地放进命令行，而且会暴露站点清单）。请用 `domains.txt` 或 `-DomainsFile`。

## 风险（AutoApply 务必看）

- **你不在场**：任务运行时如果某个 zone 返回 1034、或选到不合适的 IP，站点可能短暂
  打不开；工具会保留旧映射和备份，但需要你事后处理。
- **不是持续监控**：它只是定期刷新，不能保证这期间 CF 路由不变。
- **环境依赖**：休眠、断网、代理/TUN 开启时任务可能失败或中止（检测到 TUN 默认中止）。
  任务已设置为允许电池运行、错过时间后补跑、超时 2 小时。
- **账户要求**：写 hosts 需要管理员；任务以当前管理员账户 `Interactive` 运行，不用 SYSTEM。
- **只在登录时运行**：`Interactive` 不会在你注销后执行；要注销后也跑需要保存凭据，
  风险和复杂度都更高，不推荐。
- **脚本目录**：AutoApply 以最高权限运行，脚本却放在普通用户可写的目录。任何能以你的
  身份写文件的程序都能改脚本、等下次任务触发时提权。介意的话，把工具放到只有管理员
  可写的目录。
- **移动过目录**：任务里记的是绝对路径，移动后要重新 `-InstallTask`（先 `-UninstallTask`）；
  `-Doctor` 会提示任务指向的脚本不存在。

## 降低风险

- 频率保持 2 周一次，不要每天跑；
- 时间选凌晨或不用网的时候；
- 固定 `-ReportPath`（默认 `last-report.txt`），隔一段时间看一眼；
- 先手动跑 2–3 次，确认 `domains.txt` 稳定；
- 出问题用 `-Rollback`，备份在 `%ProgramData%\Cloudflare-Hosts-Optimizer\backup`。

## 不用内置命令时

需要自定义触发器（例如「只在每周日 4 点」或「空闲时」）可以直接用任务计划程序，或者
给面板/脚本消费 JSON：

```powershell
.\Cloudflare-Hosts-Optimizer.ps1 -Plan -PlanPath .\plan.json
```

`plan.json` 里的 `Decisions`、`Plan`、`Warnings` 可以直接被其他程序读取，不写 hosts、
不需要管理员。

任务参数的最小写法：

```text
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\Cloudflare-Hosts-Optimizer\Cloudflare-Hosts-Optimizer.ps1" -DryRun -ReportPath "C:\path\to\Cloudflare-Hosts-Optimizer\last-report.txt"
```

路径都用绝对路径；计划任务的 PATH 可能和终端不同，`pwsh.exe` 建议写完整路径
（`(Get-Command pwsh).Source`）。
