# Cloudflare-Hosts-Optimizer

优选 Cloudflare 边缘 IP 并安全写入 Windows hosts，让经 Cloudflare 代理的站点（PT 站、论坛等）网页打开更快。

> 不代理、不登录、不改出口 IP；严格校验 hosts，增量更新，一键回滚。

Windows 10/11 · PowerShell 7+ · 系统自带 `curl.exe` · CFST 可选

[English](README.en.md) · [下载发布包](https://github.com/chenfangshuo/Cloudflare-Hosts-Optimizer/releases)

**为什么会有这个脚本。** 我这边访问 PT 站经常十几秒才打开。用
[CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) 优选后手动写 hosts 确实能改善，
但 ping 最低的 IP 有时一访问就是 1034（这个 IP 不被该站接受，页面直接打不开），CFST 的默认测速
地址也已经不由作者维护。所以干脆把「测延迟 → 测吞吐 → 逐站验证 → 写 hosts → 可回滚」串成一次
运行。**我这边某个 PT 站首页从 >10s 降到 3s 左右；单站点实测 TTFB 1.75s → 0.69s。**

## 快速开始

**不想敲命令：** 下载发布包解压后双击 `Start.bat`。它会检查 PowerShell 7（没有就用
winget 安装），然后给出菜单：Doctor、导入/编辑域名、查看域名、DryRun、写入 hosts、
回滚、下载 CFST、定时任务。详见 [docs/launcher.md](docs/launcher.md)。

下面的命令行走法是同样的功能，适合脚本化和排查。

**1）[准备域名](#准备域名)**

复制 `domains.example.txt` 为 `domains.txt`，每行一个域名。建议只填**确认由 Cloudflare
代理**的站点——填错了也不会写坏，逐站验证会跳过它，只是白跑一次：

```powershell
curl.exe -sI https://example.com | findstr /i "server:"
```

返回 `server: cloudflare` 是线索，不是绝对保证；不是 CF 的站点会在逐站验证时被跳过。

**2）可选：放好 CFST（效果更好）**

菜单里可以直接「下载 / 更新 CFST」；命令行等价于：

```powershell
.\Install-Cfst.ps1              # 直连 GitHub
.\Install-Cfst.ps1 -UseProxy    # 走系统代理（Clash 的系统代理模式即可）
.\Install-Cfst.ps1 -FromFile .\cfst_windows_amd64.zip   # 手动下载的 zip
```

它会从 [CloudflareSpeedTest releases](https://github.com/XIU2/CloudflareSpeedTest/releases)
下载 `cfst.exe` 和 `ip.txt` 到脚本旁的 `cfst\` 目录（发布包已经建好这个目录）。CFST 是
GPL-3.0 第三方软件，本工具不包含也不修改它。国内访问 GitHub 不稳时，可以在浏览器打开
作者提供的[蓝奏云](https://xiu.lanzoub.com/b0742hkxe)下载 zip，再用 `-FromFile` 安装。

```text
Cloudflare-Hosts-Optimizer\
  cfst\
    cfst.exe
    ip.txt
```

不放也能用，脚本会自动回退到内置扫描；覆盖和速度差异见
[CFST vs 内置扫描](#cfst-vs-内置扫描)。

发布包解压后就是这个结构。Windows 的「全部解压缩」会先建一个以压缩包命名的目录，
里面才是 `Cloudflare-Hosts-Optimizer\`；进入内层目录运行脚本即可。

**3）先看结果**（不需要管理员，不修改 hosts）

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Cloudflare-Hosts-Optimizer.ps1 -DryRun
```

**4）正式写入**（管理员 PowerShell）

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Cloudflare-Hosts-Optimizer.ps1
```

**5）出问题一键回滚**

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Cloudflare-Hosts-Optimizer.ps1 -Rollback
```

**6）跑不通先自检**

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Cloudflare-Hosts-Optimizer.ps1 -Doctor
```

只读检查环境、hosts、CFST、探测/测速端点、代理/TUN、备份和计划任务，不需要管理员，
也不会访问目标站点。有失败项时退出码为 1。

第一次运行约 **8–15 分钟**。每个大步骤会先打印一行 `[n/6] 步骤名 · 预计时间`，过程中底部
有一行转轮动画（例如 `| 96/256 · 45s`），步骤结束打印实际用时，不会看起来像卡死。
各阶段耗时见[运行时间](#大概要跑多久)。

需要给面板/脚本消费结果时，用 `-Plan -PlanPath .\plan.json` 输出 JSON（不写 hosts）。

**7）定时运行（可选）**

每 14 天自动跑一次 DryRun（只写 `last-report.txt`，不改 hosts、不需要管理员）：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Cloudflare-Hosts-Optimizer.ps1 -InstallTask -TaskMode DryRun
```

改成 `-TaskMode AutoApply` 会在任务里自动写入 hosts（需要管理员）；删除用 `-UninstallTask`。
频率、时间和风险见 [docs/scheduling.md](docs/scheduling.md)。

## 准备域名

`domains.txt` 每行一个域名，`#` 开头为注释；已加入 `.gitignore`，站点清单不会进入版本库。
只填正文站点的网页域名：**不要填 `tracker.example.com` 这类专门的汇报子域名**——announce 是
每 30 分钟一次的几十字节请求，优选没有收益；映射一旦过期或变成 1034，反而会让汇报失败、红种。

可以手动填写，也可以从下面这些来源导入：

| 来源 | 命令 |
| --- | --- |
| PT-Depiler 备份（推荐） | `.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip'` |
| Windows 代理旁路 | `.\Import-Domains.ps1 -Source ProxyBypass` |
| 文本 | `.\Import-Domains.ps1 -Source Text -Path .\sites.txt` |
| 剪贴板 | `.\Import-Domains.ps1 -Source Clipboard` |

导入器不访问网络、不登录；PT-Depiler 备份只打开 `metadata.json`，**绝不读取**
`cookies.json`、`userInfo.json`、`downloadHistory.json`。各来源的参数和注意事项见
[docs/importing.md](docs/importing.md)。

### 检查并合并（重要）

导入默认只写 `domains.imported.txt`，**不会覆盖 `domains.txt`**。先打开这个文件逐行检查：

- 只保留确认由 Cloudflare 代理的站点；
- 代理旁路列表可能混有非 PT 域名（test-ipv6、Steam 等）；
- 不确定的域名先留在列表里跑 `-DryRun`，看它是否被逐站验证跳过。

确认后再合并：

```powershell
# 先备份、幂等、不会重复；不覆盖原有内容
.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip' -Merge
```

也可以手工把需要的行复制进 `domains.txt`。**不要**把整份备份或整个旁路列表直接合并进去。

## 运行效果

我这边的真实数字：单站点运行时 TTFB 1.75s → 0.69s（-60%）。下面是多站点的示例输出，
域名和部分数字已替换；实际输出还会多出延迟扫描和吞吐测速的表格。

```text
Cloudflare-Hosts-Optimizer 0.4.1 · 写入 hosts · 12 个域名
hosts: C:\Windows\System32\drivers\etc\hosts

[1/6] 检查环境与端点  ·  约 5 秒
代理：已开启（WinINET 127.0.0.1:7890）
浏览器等 WinINET 程序走它；本工具的探测和测速带 --noproxy，不走它。
TUN / WFP / PAC 这类透明转发不受 --noproxy 影响，见下面的网卡检查。
旁路：目标域名都在 ProxyOverride 中
浏览器开着代理时也会直连，hosts 映射可以生效。
网卡：未发现已知 TUN 虚拟网卡
只说明没有已知 TUN，不排除 WFP / 透明代理。
探测端点：speed.cloudflare.com
延迟扫描和机房判断用的 trace 地址。
测速端点：speed.cloudflare.com，HTTP 200，65536 字节
只确认端点可用，不参与排名。
完成 · 用时 5 秒

[2/6] 延迟筛选  ·  约 1–3 分钟
使用 CFST 做全量延迟扫描（可能需要 1–3 分钟）：...\cfst\cfst.exe
延迟/丢包筛选后可用 IP：1631，最佳 162.159.146.94（133ms）
完成 · 用时 1 分 32 秒

[3/6] 探测机房  ·  约 2–6 分钟
探测候选落地区域（256 个，可能需要几分钟）...
分层抽样 32 个（SJC x8, LAX x8, HKG x4, FRA x1, ...）
...
[5/6] 逐站验证  ·  约 1–3 分钟
逐域名验证与选择（基线 = 当前 hosts/DNS 路径）...
pt.example.com          切换 104.17.143.151 -> 162.159.160.5  [复核确认]
forum.example.org       保留 104.17.131.149  [未达阈值]
完成 · 用时 21 秒

[6/6] 写入 hosts  ·  几秒
已写入 hosts（备份：C:\ProgramData\Cloudflare-Hosts-Optimizer\backup\hosts-20261029-120000-xxxxxxxx.bak）
完成 · 用时 1 秒

结果：更新 1 · 保留 11 · 用时 3 分 20 秒

==== 逐域名决策 ====
Domain            BaselineIP      BaseState BaseTTFB ChosenIP        ChosenTTFB BestTTFB ImprovePct Reason    Action
------            ----------      --------- -------- --------        ---------- -------- ---------- ------    ------
pt.example.com    104.17.143.151  ok            1.01 162.159.160.5        0.62     0.62      39.30 复核确认  更新
forum.example.org 104.17.131.149  ok            0.57 104.17.131.149       0.57     0.53       7.30 未达阈值  保留
```

## 它怎么选 IP

1. CFST（或内置扫描）先按延迟/丢包筛掉大部分 IP。
2. 按落地机房分层抽样，避免候选全落在 HKG。
3. 独立吞吐初测 + 3 × 2MB 决赛，只认决赛成绩。
4. 每个域名以当前 hosts/DNS 为基线逐站 HEAD 验证；准备切换时基线与候选各复核一次。
5. 只有快 ≥15%（`-MinImprovementPct`）且 ≥30ms（`-MinImprovementMs`），或基线不可用/类别更差才切换。

为什么这么设计、1034 回退、IPv6 取舍等，见 [docs/how-it-works.md](docs/how-it-works.md)。

## 大概要跑多久

典型家用宽带（CFST + 十几个域名）约 **8–15 分钟**：

| 阶段 | 典型耗时 | 说明 |
| --- | --- | --- |
| CFST 延迟/丢包扫描 | 1–3 分钟 | `-NoCfst` 内置扫描通常更快但覆盖小 |
| 探测候选落地区域（256 个） | 2–6 分钟 | 每个候选最多 6 秒、16 并发；显示转轮动画和 x/y 进度 |
| ↳ 14 天内有缓存时 | 约 1 分钟 | 覆盖上次的机房后提前结束；过期或区域变化时自动全量探测 |
| 吞吐初测 + 决赛 | 1–3 分钟 | 约 70MB 下载，取决于带宽 |
| 逐域名验证与复核 | 1–3 分钟 | 每站约 6–10 次 HEAD，间隔 400ms |

想缩短时间：

```powershell
.\Cloudflare-Hosts-Optimizer.ps1 -ThroughputCandidates 16 -MaxDomainProbes 4
.\Cloudflare-Hosts-Optimizer.ps1 -NoCfst -MaxCandidates 128
```

## 安全边界（PT 站必看）

- 不登录、不带 Cookie、不访问 announce URL、不读取 passkey；对目标站只做少量 HEAD
  （每域名典型 6–10 次、最坏 11 次；准备切换时同一 IP 最多 2 次）。请求预算会随候选数和
  `-MaxDomainProbes` 一起涨，所以不建议调高。
- **不改变出口 IP**：前提是这些域名在代理旁路里。脚本会检查 WinINET 旁路和 TUN，
  但无法完整识别 PAC/WPAD、WinHTTP、应用级代理和 WFP 透明转发。
- 即使 Clash 开着也没关系：所有 curl 都带 `--noproxy '*'`，CFST 启动前清空代理环境变量；
  探测和测速强制直连。
- 不使用 VPN、机场、在线优选网站或公共反向代理访问 PT。
- hosts 只影响这些域名的网页解析；announce 不会因此变快，也不建议把 tracker 子域名单独加进
  列表（原因见 [FAQ](docs/faq.md#要不要把-tracker-域名加进-domainstxt)）；**P2P 和 IPv6
  对等连接不受影响**。

具体规则以各站为准；更多问答见 [docs/faq.md](docs/faq.md)。

## CFST vs 内置扫描

| | CFST（`cfst\cfst.exe`） | 内置扫描（`-NoCfst` / 未找到） |
| --- | --- | --- |
| 候选覆盖 | `ip.txt` 当前 25 个网段；不含 172.68–172.71（内置扫描覆盖），额外包含 104.28.0.0/14（需 `-ExperimentalRanges`） | 随机抽 `-MaxCandidates` 个（默认 192） |
| 延迟测量 | TCPing（TCP RTT） | HTTPS `cdn-cgi/trace`（含 TLS） |
| 依赖 | 第三方 GPL-3.0 二进制 | 仅 PowerShell + 系统 `curl.exe` |
| 速度 | 快 | 几十秒到一两分钟 |

**为什么不直接用 CFST 的结果写 hosts。** CFST 给的是「本机到各个 IP」的速度排名，它不会告诉你
这个 IP 对某个站点能不能用——同一个 IP 可能 A 站正常、B 站 1034；而它的下载测速依赖 `-url`，
默认地址已不由作者维护（[issue #168](https://github.com/XIU2/CloudflareSpeedTest/issues/168)），
当前版本对非 200 响应直接判失败。所以这里只借它的延迟/丢包筛查，吞吐自己测，能不能用逐站验证。
两者共用后续的机房分层、吞吐决赛和逐域名选择；CFST 只用于延迟/丢包，**不做下载测速**。
覆盖、参数和已知坑见 [docs/how-it-works.md](docs/how-it-works.md#cfst-与内置扫描)。

## 常用参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-DryRun` | | 只扫描和验证，不修改 hosts |
| `-Plan` | | 不修改 hosts，输出机器可读的 JSON 计划 |
| `-PlanPath` | `.\plan.json` | `-Plan` 的输出路径 |
| `-Rollback` | | 用最近一次备份恢复 hosts（不依赖 domains.txt） |
| `-RollbackFrom` | 最近一次 | 与 `-Rollback` 同用，恢复到指定的 `hosts-*.bak` |
| `-Prune` | | 删除不再出现在域名列表中的历史托管映射 |
| `-CheckResolved` | | 写入后解析每个域名，报告系统实际返回的地址 |
| `-Doctor` | | 只读自检（不写 hosts、不需要管理员） |
| `-InstallTask` | | 注册计划任务（默认 DryRun，每 14 天） |
| `-UninstallTask` | | 删除计划任务 |
| `-NoCfst` | | 强制内置扫描 |
| `-TopN` | 1 | 每个域名最多写入的 IP 数 |
| `-MinImprovementPct` | 15 | 相对基线至少改善多少百分比才切换 |
| `-MinImprovementMs` | 30 | 切换所需的最小绝对改善（毫秒） |
| `-MaxDomainProbes` | 6 | 每域名候选探测硬上限 |
| `-NoColoCache` | | 不用机房缓存，每次全量探测 |
| `-CfstPath` | 自动查找 | cfst.exe 路径，可传目录 |

完整参数（含测速、超时、沙箱选项）见 [docs/parameters.md](docs/parameters.md)。

## hosts 安全

- 只接受“没有标记”或“恰好一对 BEGIN/END”；缺失、重复、嵌套、孤立 END 直接中止。
- 编码只支持 ASCII / UTF-8；多别名行、IPv6 映射、其他工具的托管区块 → 中止并报告行号。
- 验证失败默认保留旧映射；明确 1034/1003 才自动丢弃；不在本次列表默认保留，`-Prune` 才删除。
- 写入：互斥锁 + 提交前哈希检查 + 备份清单 + 原子替换 + 读回校验；`-Rollback` 可恢复，
  `-RollbackFrom` 可退回到更早的备份。

完整规则和备份/回滚细节见 [docs/hosts-safety.md](docs/hosts-safety.md)。

## 常见问题

见 [docs/faq.md](docs/faq.md)。几个最常问的：

- 网页变快 ≠ 下载变快：hosts 不影响 P2P 传输。
- 写入 A 记录后，Windows 通常不再使用 DNS 的 AAAA；应用自带解析器可能不同。
- hosts 多行不保证优先级或故障转移，所以默认只写 1 个 IP。
- CF 路由会变，建议每 1–2 周或感觉变慢时重跑；也可以 `-InstallTask` 自动跑。
- 跑不通、测不出速度，先跑 `-Doctor`。

## 开发与测试

```powershell
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path .\tests -Output Detailed
```

全部离线测试（临时目录、合成备份，不访问网络、不碰真实 hosts）；CI 在 `windows-latest`
上运行语法检查、PSScriptAnalyzer 和 Pester。

贡献前请看 [CONTRIBUTING.md](CONTRIBUTING.md)；安全问题用 [SECURITY.md](SECURITY.md)
里的私密报告渠道，不要开公开 issue。

## 致谢

- [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) — 优选引擎（GPL-3.0）
- [PT-Depiler](https://github.com/pt-plugins/PT-depiler) — 备份导入的字段结构参考
- [cmliu/CF-Workers-SpeedTestURL](https://github.com/cmliu/CF-Workers-SpeedTestURL) — 自建测速地址

## License

[MIT](LICENSE)。本仓库不包含 CloudflareSpeedTest 的代码或二进制。

---

## English

A Windows PowerShell tool that picks the fastest Cloudflare edge IPs and writes them into
the hosts file, for Cloudflare-proxied sites (PT forums, etc.).

It uses CloudflareSpeedTest for latency/loss screening only, measures throughput independently,
samples candidates across edge colos, verifies every domain with HEAD requests (one extra
confirmation probe per IP when switching), and manages hosts entries in a tagged, idempotent,
reversible block. Domain lists can be imported from a PT-Depiler backup, the Windows proxy
bypass list, text, or the clipboard.

Requirements: Windows 10/11, PowerShell 7+, curl.exe. CFST is optional and not bundled.
