# 参数

日常使用通常只需要 `-DryRun`、`-Rollback`，偶尔加 `-Prune`、`-CheckResolved`。
其余参数主要用于调优或测试。

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-DryRun` | | 只扫描和验证，不修改 hosts |
| `-Plan` | | 不修改 hosts，输出机器可读的 JSON 计划（默认 `.\plan.json`） |
| `-PlanPath` | `.\plan.json` | `-Plan` 的 JSON 输出路径 |
| `-Rollback` | | 用最近一次备份恢复 hosts（不依赖 domains.txt） |
| `-RollbackFrom` | 最近一次 | 与 `-Rollback` 同用，恢复指定的 `hosts-*.bak`，用于退回更早状态 |
| `-Version` | | 打印版本号并退出 |
| `-NoCfst` | | 不查找 cfst.exe，强制内置扫描 |
| `-Force` | | 回滚时允许覆盖被其他程序改过的 hosts；或允许在 TUN 环境下继续 |
| `-Prune` | | 删除不再出现在域名列表中的历史托管映射 |
| `-CheckResolved` | | 写入后解析每个域名，报告系统实际返回的地址 |
| `-ExperimentalRanges` | | 允许扫描 CF 官方列表之外的 104.28.0.0/14 |
| `-TopN` | 1 | 切换后每个域名最多写入的 IP 数（未切换时保留基线） |
| `-CandidatesPerDomain` | 3 | 每个域名参与对比的全局候选数（1–5） |
| `-BackfillCandidates` | 1 | 前 K 个都不可用时补测的候选数（0–5） |
| `-MaxDomainProbes` | 6 | 每域名候选探测硬上限（不含基线/DNS） |
| `-VerifyTimeoutSec` | 5 | 单次域名验证超时（秒） |
| `-MinImprovementPct` | 15 | 相对基线至少改善多少百分比才切换 |
| `-MinImprovementMs` | 30 | 切换所需的最小绝对改善（毫秒），避免噪声内切换 |
| `-DropUnreachable` | | 旧映射连接失败时也删除（默认保留并告警） |
| `-NoColoCache` | | 不使用上次的机房缓存，每次全量探测 |
| `-ColoCachePath` | `%LOCALAPPDATA%\Cloudflare-Hosts-Optimizer\colo-cache.json` | 机房缓存路径 |
| `-ColoCacheMaxAgeDays` | 14 | 缓存有效天数；0 等于不使用 |
| `-Domains` | | 直接指定域名（严格模式：拒绝 URL/端口/路径） |
| `-DomainsFile` | `.\domains.txt` | 域名文件路径 |
| `-CfstPath` | 自动查找 | cfst.exe 路径，可传文件或目录 |
| `-SpeedTestUrl` | `https://speed.cloudflare.com/__down?bytes={bytes}` | 吞吐测速地址（只允许 https） |
| `-HostsPath` | 系统 hosts | 高级选项：测试/沙箱用 |
| `-ReportPath` | 正常运行时 `.\last-report.txt` | 报告文件；DryRun 默认不写 |
| `-ScanSamples` | 2 | 内置扫描每个 IP 的探测次数 |
| `-MaxCandidates` | 192 | 内置扫描的候选 IP 数 |
| `-ThroughputCandidates` | 32 | 参与吞吐初测的 IP 数 |
| `-ThroughputSamples` | 1 | 初测每个 IP 的采样次数 |
| `-ThroughputBytes` | 1000000 | 初测下载字节数 |
| `-RefineTop` | 6 | 吞吐前 N 名进入决赛 |
| `-VerifyDelayMs` | 400 | 域名验证之间的间隔 |

## 常用组合

```powershell
# 只看计划，不写 hosts
.\Cloudflare-Hosts-Optimizer.ps1 -DryRun

# 输出 JSON 计划（供面板/脚本消费，不写 hosts）
.\Cloudflare-Hosts-Optimizer.ps1 -Plan -PlanPath .\plan.json

# 缩短运行时间
.\Cloudflare-Hosts-Optimizer.ps1 -ThroughputCandidates 16 -MaxDomainProbes 4

# 不用 CFST，内置扫描
.\Cloudflare-Hosts-Optimizer.ps1 -NoCfst -MaxCandidates 128

# 写入后核对系统实际解析结果
.\Cloudflare-Hosts-Optimizer.ps1 -CheckResolved

# 删除已经从 domains.txt 移除的历史条目
.\Cloudflare-Hosts-Optimizer.ps1 -Prune

# 回到更早的备份（先看备份目录里有哪些 hosts-*.bak）
.\Cloudflare-Hosts-Optimizer.ps1 -Rollback -RollbackFrom 'C:\ProgramData\Cloudflare-Hosts-Optimizer\backup\hosts-20261029-040000-abcd1234.bak'

# 强制每次全量探测机房（不使用缓存）
.\Cloudflare-Hosts-Optimizer.ps1 -NoColoCache
```
