# 使用与参数指南

这一份讲清楚：菜单怎么点、域名怎么填、CFST 怎么装、任务怎么定时、参数都是什么。
只想先跑起来，看 [README 的 30 秒开始](../README.md#30-秒开始)；为什么这么设计，看
[工作原理与安全机制](design.md)。

## 双击启动（Start.bat）

### 启动步骤

1. 下载发布包，解压到本地目录（不要在压缩包里直接运行）。
2. 双击 `Start.bat`。Windows 的「全部解压缩」会先建一个以 zip 名命名的目录，里面才是
   `Cloudflare-Hosts-Optimizer\`，**进入内层目录**再运行。
3. `Start.bat` 会依次找 `pwsh.exe`：`PATH` → `%ProgramFiles%\PowerShell\7\` →
   `%ProgramFiles%\PowerShell\7-preview\` → `%LOCALAPPDATA%\Microsoft\WindowsApps\`。
   四个位置都没有时，如果系统有 winget，会询问是否安装 `Microsoft.PowerShell`；装完
   在同一窗口重新检查并实际跑一次 `pwsh -Version` 验证。仍然失败会给出
   <https://aka.ms/powershell-release?tag=stable>，手动安装后重新打开窗口再运行。

### 菜单怎么用

- `↑`/`↓` 移动，`Enter` 确认，`Esc` 返回（主菜单里是退出）。
- `1`–`9` 直达前九项；第 10 项「回滚」用方向键移过去；`0` 退出 / 返回。
- 菜单就地重绘；选定后先擦掉整块菜单再执行动作，Doctor、DryRun 的输出从干净的位置开始。
- 每次回到菜单会清屏，菜单上方不会堆积旧输出；要回看用「查看上次报告」。
- 默认焦点：第一次打开时没有域名停在「导入」、已有域名停在「DryRun」；执行过动作或
  从子菜单返回后停在「0 退出」，连续按 `Enter` 不会重复启动 DryRun。编号不变，按 8 仍可直达。
- 输出被重定向、在管道里运行，或终端不支持 VT 时，自动退回「输入编号」模式；也可以用
  `$env:CFO_PLAIN_MENU='1'` 强制。

状态栏分两行：`上次运行：时间 · 模式 · 退出码` 和 `最近提交：写入/回滚 · 时间`。
没有域名时会提示先按 1 导入；CFST 未安装时会提示可以直接按 8 试跑。

### 首次启动

```text
Cloudflare-Hosts-Optimizer 0.5.5
域名 12 个 · hosts 已写入 10 个 · CFST 已安装
上次运行：2026-11-01 10:28 · 写入 · 退出码 0
最近提交：写入 · 2026-11-01 10:28
当前是普通权限；写入 hosts / 回滚时会单独弹出 UAC。

  1) 导入 / 编辑域名
  2) 查看域名（列表与已写入）
  3) 下载 / 更新 CFST
  4) 定时任务
  5) 查看上次报告
  6) 打开 README
  7) 环境自检 (Doctor)
  8) 只看结果 (DryRun，不改 hosts)
  9) 正式写入 hosts
 10) 回滚到上次备份
  0) 退出
```

### 菜单项

| 项 | 作用 | 管理员 |
| --- | --- | --- |
| 1 导入 / 编辑域名 | 从 PT-Depiler 备份、代理旁路、文本、剪贴板导入；或用记事本直接编辑 `domains.txt` | 否 |
| 2 查看域名（列表与已写入） | 显示 `domains.txt`、hosts 托管区块，以及只在一边的差集 | 否 |
| 3 下载 / 更新 CFST | 见[下面的下载一节](#下载--更新-cfst) | 否 |
| 4 定时任务 | 安装 DryRun / AutoApply 任务，或卸载 | AutoApply 需要 |
| 5 查看上次报告 | 显示 `last-report.txt`：80 行以内全看，更长时取头部 + 最后 40 行 | 否 |
| 6 打开 README | 用记事本打开仓库根目录的 `README.md` | 否 |
| 7 环境自检 (Doctor) | 只读检查环境、hosts、域名、CFST、端点、代理/TUN、备份、计划任务 | 否 |
| 8 只看结果 (DryRun，不改 hosts) | 完整跑一遍但不写 hosts（菜单里会顺带写报告） | 否 |
| 9 正式写入 hosts | 写入系统 hosts | 是（弹 UAC） |
| 10 回滚到上次备份 | 用最近一次备份恢复 hosts | 是（弹 UAC） |
| 0 退出 | 主菜单退出，子菜单返回 | 否 |

### 提权（UAC）

菜单本身以普通权限运行。只有「正式写入 hosts」「回滚到上次备份」「安装 AutoApply 任务」
会调用 `Start-Process -Verb RunAs` 打开管理员窗口：

- 会先弹 UAC，取消则回到菜单，不会中断；
- 管理员窗口跑完后提示「执行完毕（退出码 N），按 Enter 关闭此窗口」，按回车窗口自动关闭、
  回到菜单；结束后主窗口也会显示管理员窗口的退出码；
- 结果同时写进 `last-report.txt`，菜单里可以查看。

「定时任务」子菜单会先列出已注册任务（名称、状态、下次运行、上次结果）；查询失败时显示
「任务状态：未知（查询失败…）」，不会当成没有任务。安装 AutoApply 会先确认（它会按计划
自动写入 hosts）；安装同名任务时会确认是否覆盖，确认后才用 `-TaskForce`。两种确认合并成
一次提问，取消则不执行。

## 域名导入与合并

`domains.txt` 每行一个域名，`#` 开头为注释；已加入 `.gitignore`，站点清单不会进版本库。
填什么、不填什么见 [README 的填域名与注意事项](../README.md#填域名与注意事项)。

> 快速判断是否由 Cloudflare 代理：`curl.exe -sI https://example.com | findstr /i "server:"`，
> 返回 `server: cloudflare` 是线索，不是绝对保证；不是 CF 的站点会在逐站验证时被跳过。

四种来源：

| 来源 | 命令 |
| --- | --- |
| PT-Depiler 备份（推荐） | `.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip'` |
| Windows 代理旁路 | `.\Import-Domains.ps1 -Source ProxyBypass` |
| 文本 | `.\Import-Domains.ps1 -Source Text -Path .\sites.txt` |
| 剪贴板 | `.\Import-Domains.ps1 -Source Clipboard` |

导入器只把主机名写进文件：不访问网络、不登录、不带 Cookie，也不读取 passkey。

### 输出与合并

默认输出 `domains.imported.txt`，**不会覆盖 `domains.txt`**。先打开检查，再合并：

```powershell
# 先备份、幂等、不会重复
.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip' -Merge
```

也可以手工把需要的行复制进 `domains.txt`。

### 从 PT-Depiler 备份（推荐）

在 PT-Depiler 里导出备份（建议**关闭备份加密**，导入器不处理密码），路径指向 zip 即可。
默认读取 `metadata.json`，取每个站点的 `url` 主机名；离线站点默认跳过。

```powershell
# 同时导入 siteHostMap 里的备用/CDN 主机名
.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip' -IncludeAlternates

# 包含离线站点
.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip' -IncludeOffline
```

**隐私边界**：只打开 `metadata.json`，绝不读取 `cookies.json`、`userInfo.json`、
`downloadHistory.json`；控制台只打印数量，不打印域名、passkey 或完整 URL。
为避免异常备份，导入器会拒绝重复的 `metadata.json` 和超过 8MB 的解压内容。

如果你用的是 PTPP（PT-Depiler 的前身），备份结构不同，当前不保证支持；改用
`-Source ProxyBypass`、文本或剪贴板导入。

### 从 Windows 代理旁路列表

已经把所有 PT 域名加进代理旁路的话，这一步零文件、零网络。列表可能包含非 PT 域名
（例如 test-ipv6、Steam），请人工筛选。

### 从文本或剪贴板

文本和剪贴板来源会提取里面的 URL 和裸主机名；URL 路径不会被误当成域名。

### 检查重点

- 只保留确认由 Cloudflare 代理的站点；
- 代理旁路列表可能混有非 PT 域名；
- 不确定的域名先跑 `-DryRun`，看它是否被逐站验证跳过；
- 不要把整份备份或整个旁路列表直接 `-Merge` 进去。

## 下载 / 更新 CFST

CFST（CloudflareSpeedTest）是第三方 GPL-3.0 软件，本工具**不打包**它，只在你选择时下载。
它有更广的候选覆盖，装不装都能用；差异见 [design.md 的对比表](design.md#cfst-与内置扫描)。

| 方式 | 说明 |
| --- | --- |
| 直连 GitHub | 默认。会清空 `HTTP_PROXY`/`HTTPS_PROXY` 等环境变量并加 `--noproxy '*'`，确保是真直连 |
| 系统代理 | 读取 Windows「Internet 选项」里的 HTTP 代理（Clash 的“系统代理”模式） |
| 蓝奏云下载页 | 在浏览器打开作者提供的下载入口，手动下载 zip 后用下一项安装 |
| 从本地 zip 安装 | 只接受 zip，并做和自动下载相同的校验 |

命令行等价：

```powershell
.\Install-Cfst.ps1              # 直连 GitHub
.\Install-Cfst.ps1 -UseProxy    # 走系统代理
.\Install-Cfst.ps1 -FromFile .\cfst_windows_amd64.zip   # 手动下载的 zip
```

装到脚本旁的 `cfst\`，发布包已经建好这个目录（里面只有一份说明文件）：

```text
Cloudflare-Hosts-Optimizer\
  cfst\
    cfst.exe
    ip.txt
```

蓝奏云地址：<https://xiu.lanzoub.com/b0742hkxe>（作者在其官方 README 中列出）。

下载后会校验 zip 结构（根级 `cfst.exe` + `ip.txt`）、大小、压缩比、`MZ` 头和 `ip.txt`
里的 CIDR；显示来源和 SHA256。上游没有发布校验值或签名，SHA256 只用于记录/比对。

## 运行时间

典型家用宽带（CFST + 十几个域名）约 **8–15 分钟**：

| 阶段 | 典型耗时 | 说明 |
| --- | --- | --- |
| CFST 延迟/丢包扫描 | 1–3 分钟 | `-NoCfst` 内置扫描通常更快但覆盖小 |
| 探测候选落地区域（256 个） | 2–6 分钟 | 每个候选最多 6 秒、16 并发；显示转轮和 x/y 进度 |
| ↳ 14 天内有缓存时 | 约 1 分钟 | 覆盖上次的机房后提前结束；过期或区域变化时自动全量探测 |
| 吞吐初测 + 决赛 | 1–3 分钟 | 约 70MB 下载，取决于带宽 |
| 逐域名验证与复核 | 1–3 分钟 | 每站约 6–10 次 HEAD，间隔 400ms |

每个大步骤先打印一行 `[n/6] 步骤名 · 预计时间`，过程中底部有一行转轮动画
（例如 `| 96/256 · 45s`），步骤结束打印实际用时；输出被重定向时改为每 32 个打印一次。

想缩短时间：

```powershell
.\Cloudflare-Hosts-Optimizer.ps1 -ThroughputCandidates 16 -MaxDomainProbes 4
.\Cloudflare-Hosts-Optimizer.ps1 -NoCfst -MaxCandidates 128
```

### 一次运行多少流量

- 延迟扫描：每个候选几十字节的 trace 请求。
- 吞吐初测：32 × 1MB ≈ 32MB；决赛 6 × 3 × 2MB ≈ 36MB。
- 站点验证：每域名典型 6–10 次、最坏 11 次 HEAD；403/503 额外 1 次 ≤64KB 的 GET。

合计约 **70MB**，可用 `-ThroughputCandidates`、`-ThroughputBytes`、`-RefineTop` 调整。

## 定时运行

CF 路由、运营商互联和 zone 白名单都会变，建议每 1–2 周重跑一次。脚本内置计划任务注册，
不用手写 `Register-ScheduledTask`。

| 模式 | 是否改 hosts | 需要管理员 | 适合 |
| --- | --- | --- | --- |
| `DryRun`（默认） | 否，只写 `last-report.txt` | 否 | 想先看结果、人工确认 |
| `AutoApply` | 是 | 是（注册和运行都需要） | 已经稳定手动跑过几次、不想每次手动 |

### 安装

```powershell
# DryRun（推荐，普通 PowerShell 即可）
.\Cloudflare-Hosts-Optimizer.ps1 -InstallTask -TaskMode DryRun

# 改频率和时间
.\Cloudflare-Hosts-Optimizer.ps1 -InstallTask -TaskMode DryRun -TaskIntervalDays 7 -TaskAt '09:30'

# AutoApply（管理员 PowerShell）
.\Cloudflare-Hosts-Optimizer.ps1 -InstallTask -TaskMode AutoApply
```

默认每 14 天一次：DryRun 10:00、AutoApply 04:00。安装前会校验 `domains.txt` 存在且没有
非法项——否则任务每次都会失败。任务设置为允许电池运行、错过时间后补跑（`StartWhenAvailable`）、
同一任务不并发、超时 2 小时。

### 查看

```powershell
Get-ScheduledTask -TaskName 'Cloudflare-Hosts-Optimizer*' | Get-ScheduledTaskInfo
```

或跑 `-Doctor`：它会把任务状态、下次运行时间和上次结果列在「计划」一组里，并检查任务指向
的脚本是否还存在。立即测试一次：

```powershell
Start-ScheduledTask -TaskName 'Cloudflare-Hosts-Optimizer DryRun'
Get-Content .\last-report.txt
```

### 卸载

```powershell
.\Cloudflare-Hosts-Optimizer.ps1 -UninstallTask
```

不带 `-TaskName` 时删除 DryRun 和 AutoApply 两个默认任务；只删一个就加
`-TaskName 'Cloudflare-Hosts-Optimizer AutoApply'`。任务本来就不存在时视为成功。

### 会被带进任务的参数

注册任务时，命令行里显式给出的这些参数会一并写进任务：

`-NoCfst`、`-ExperimentalRanges`、`-NoColoCache`、`-ColoCachePath`、
`-ColoCacheMaxAgeDays`、`-TopN`、`-CandidatesPerDomain`、`-BackfillCandidates`、
`-MaxDomainProbes`、`-VerifyTimeoutSec`、`-MinImprovementPct`、`-MinImprovementMs`、
`-DomainsFile`、`-CfstPath`、`-SpeedTestUrl`、`-ProbeUrl`、`-ScanSamples`、
`-MaxCandidates`、`-ThroughputCandidates`、`-ThroughputSamples`、`-ThroughputBytes`、
`-RefineTop`、`-VerifyDelayMs`、`-CheckResolved`。

`-Force`、`-DropUnreachable`、`-Prune` 永远不会写进任务；`-Domains` 也不支持（域名数组
没法安全地放进命令行，而且会暴露站点清单）。请用 `domains.txt` 或 `-DomainsFile`。

### 风险（AutoApply 务必看）

- **你不在场**：任务运行时如果某个 zone 返回 1034、或选到不合适的 IP，站点可能短暂
  打不开；工具会保留旧映射和备份，但需要你事后处理。
- **不是持续监控**：它只是定期刷新，不能保证这期间 CF 路由不变。
- **环境依赖**：休眠、断网、代理/TUN 开启时任务可能失败或中止（检测到 TUN 默认中止）。
- **账户要求**：写 hosts 需要管理员；任务以当前管理员账户 `Interactive` 运行，不用 SYSTEM。
- **只在登录时运行**：`Interactive` 不会在你注销后执行；要注销后也跑需要保存凭据，
  风险和复杂度都更高，不推荐。
- **脚本目录**：AutoApply 以最高权限运行，脚本却放在普通用户可写的目录。任何能以你的
  身份写文件的程序都能改脚本、等下次任务触发时提权。介意的话，把工具放到只有管理员
  可写的目录。
- **移动过目录**：任务里记的是绝对路径，移动后要重新 `-InstallTask`（先 `-UninstallTask`）；
  `-Doctor` 会提示任务指向的脚本不存在。

降低风险：频率保持 2 周一次；时间选凌晨或不用网的时候；先手动跑 2–3 次确认列表稳定；
隔一段时间看一眼报告；出问题用 `-Rollback`。

### 自定义触发器 / 消费 JSON

需要「只在每周日 4 点」或「空闲时」这类触发器，直接在任务计划程序里新建即可，或者用
`-Plan` 输出 JSON 给面板/脚本消费（不写 hosts、不需要管理员）：

```powershell
.\Cloudflare-Hosts-Optimizer.ps1 -Plan -PlanPath .\plan.json
```

`plan.json` 里包含 `Decisions`、`Plan`（最终 IP→域名映射，含保留的旧条目）和 `Warnings`。

手写任务时路径都用绝对路径，`pwsh.exe` 建议写完整路径（`(Get-Command pwsh).Source`）：

```text
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\Cloudflare-Hosts-Optimizer\Cloudflare-Hosts-Optimizer.ps1" -DryRun -ReportPath "C:\path\to\Cloudflare-Hosts-Optimizer\last-report.txt"
```

## 参数参考

日常通常只需要 `-DryRun`、`-Rollback`，偶尔加 `-Prune`、`-CheckResolved`；其余参数用于调优或测试。

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-DryRun` | | 只扫描和验证，不修改 hosts |
| `-Plan` | | 不修改 hosts，输出机器可读的 JSON 计划（默认 `.\plan.json`） |
| `-PlanPath` | `.\plan.json` | `-Plan` 的 JSON 输出路径 |
| `-Rollback` | | 用最近一次备份恢复 hosts（不依赖 domains.txt） |
| `-RollbackFrom` | 最近一次 | 与 `-Rollback` 同用，恢复指定的 `hosts-*.bak`，用于退回更早状态 |
| `-Version` | | 打印版本号并退出 |
| `-Doctor` | | 只读自检，有失败项退出码 1 |
| `-InstallTask` | | 注册计划任务并退出（默认 DryRun，不需要管理员） |
| `-UninstallTask` | | 删除计划任务并退出；不带 `-TaskName` 时删两个默认任务 |
| `-TaskMode` | `DryRun` | 计划任务模式：`DryRun` 只写报告，`AutoApply` 自动写入 hosts（需管理员） |
| `-TaskIntervalDays` | 14 | 计划任务间隔天数（1–30） |
| `-TaskAt` | DryRun `10:00` / AutoApply `04:00` | 计划任务运行时间（`HH:mm`） |
| `-TaskName` | 自动 | 自定义任务名；`-UninstallTask` 时可以只删指定的一个 |
| `-TaskForce` | | 覆盖已存在的同名计划任务（与 `-Force` 无关） |
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
| `-CfstPath` | 自动查找 | cfst.exe 路径，可传文件或目录（传目录时取里面的 cfst.exe） |
| `-SpeedTestUrl` | `https://speed.cloudflare.com/__down?bytes={bytes}` | 吞吐测速地址（只允许 https，必须带 `{bytes}` 才会预检） |
| `-ProbeUrl` | `https://speed.cloudflare.com/cdn-cgi/trace` | 延迟扫描和机房探测的 trace 地址；必须是 Cloudflare 托管域名、443 端口 |
| `-HostsPath` | 系统 hosts | 高级选项：测试/沙箱用（指向临时文件，不需要管理员） |
| `-ReportPath` | 正常运行时 `.\last-report.txt` | 报告文件；**裸命令行 DryRun 默认不写**，菜单和计划任务会带上它 |
| `-ScanSamples` | 2 | 内置扫描每个 IP 的探测次数 |
| `-MaxCandidates` | 192 | 内置扫描的候选 IP 数 |
| `-ThroughputCandidates` | 32 | 参与吞吐初测的 IP 数 |
| `-ThroughputSamples` | 1 | 初测每个 IP 的采样次数 |
| `-ThroughputBytes` | 1000000 | 初测下载字节数 |
| `-RefineTop` | 6 | 吞吐前 N 名进入决赛 |
| `-VerifyDelayMs` | 400 | 域名验证之间的间隔 |

### 常用组合

```powershell
# 只看计划，不写 hosts
.\Cloudflare-Hosts-Optimizer.ps1 -DryRun

# 输出 JSON 计划（供面板/脚本消费，不写 hosts）
.\Cloudflare-Hosts-Optimizer.ps1 -Plan -PlanPath .\plan.json

# 缩短运行时间 / 不用 CFST
.\Cloudflare-Hosts-Optimizer.ps1 -ThroughputCandidates 16 -MaxDomainProbes 4
.\Cloudflare-Hosts-Optimizer.ps1 -NoCfst -MaxCandidates 128

# 写入后核对系统实际解析结果 / 删除已移出列表的历史条目
.\Cloudflare-Hosts-Optimizer.ps1 -CheckResolved
.\Cloudflare-Hosts-Optimizer.ps1 -Prune

# 回到更早的备份（先看备份目录里有哪些 hosts-*.bak）
.\Cloudflare-Hosts-Optimizer.ps1 -Rollback -RollbackFrom 'C:\ProgramData\Cloudflare-Hosts-Optimizer\backup\hosts-20261029-040000-abcd1234.bak'

# 强制每次全量探测机房（不使用缓存）
.\Cloudflare-Hosts-Optimizer.ps1 -NoColoCache
```

## 数据位置

| 内容 | 位置 |
| --- | --- |
| 域名列表 | `<工具目录>\domains.txt` |
| 导入中间产物 | `<工具目录>\domains.imported.txt` |
| 运行报告 | `<工具目录>\last-report.txt` |
| 运行摘要（最近运行/最近提交） | `<工具目录>\last-run.json` |
| 备份 | `%ProgramData%\Cloudflare-Hosts-Optimizer\backup` |
| 机房缓存 | `%LOCALAPPDATA%\Cloudflare-Hosts-Optimizer\colo-cache.json` |
| CFST | `<工具目录>\cfst\cfst.exe` + `ip.txt` |

`last-run.json` 只用于菜单展示，不参与回滚授权；备份的 manifest 和回滚规则见
[design.md 的 hosts 一节](design.md#hosts-写入与安全规则)。
