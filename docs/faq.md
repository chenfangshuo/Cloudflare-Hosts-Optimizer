# FAQ

先看 [README](../README.md) 的"30 秒开始"和 [guide.md](guide.md)；下面按"启动 → 安全 →
选择 → 故障"排。提问时不要贴真实站点清单、passkey 或完整 URL。

## 启动与菜单排障

### 双击后提示没找到 Menu.ps1

你在压缩包预览里直接运行了。先完整解压，再运行解压后**内层目录**里的 `Start.bat`
（资源管理器的"全部解压缩"会先建一个以 zip 名命名的目录）。

### 双击后窗口一闪而过

说明启动失败。可以在终端里执行 `cmd /k Start.bat` 保留输出看错误；常见原因是 PowerShell 7
没装好或 `Start.bat` 被杀毒软件拦截。

### winget 安装后仍提示找不到 pwsh

`Start.bat` 会再检查 `PATH`、`Program Files\PowerShell\7`、`7-preview` 和 `WindowsApps`
四个位置。仍然失败时，关掉窗口重新打开一次再试；还不行就按它给出的
<https://aka.ms/powershell-release?tag=stable> 手动安装。

### 直连下载 CFST 失败

在菜单里改用"系统代理"下载，或在浏览器打开蓝奏云下载页手动下载 zip，再用"从本地 zip
安装"。四种方式的区别见 [guide.md 的下载一节](guide.md#下载--更新-cfst)。

### 为什么不建议"以其他用户运行"

配置目录和 `domains.txt` 按脚本所在目录解析，用别的账户运行可能读到另一套文件；
系统 hosts 的备份在 `%ProgramData%`（各账户共用），沙箱备份在仓库 `backup\targets`。
建议只用当前用户，需要管理员时让 UAC 自己提权。

### 工具放在映射盘 / 网络路径

提权后的进程可能看不到映射盘（`Z:\` 这类只在当前会话存在）。建议放在本地目录；
网络路径请用 UNC（`\\server\share\...`），并确认管理员会话也能访问。

## 会不会导致 PT 站封号？

本工具不改变你的出口 IP：它只改"连到哪个 CF 边缘节点"，流量仍然从你的家宽直接出去，
登录 IP、tracker 上报 IP 都不变。不登录、不带 Cookie、不访问 announce URL、不读取 passkey。

前提是这些域名在代理旁路里；脚本会检查 WinINET 的 `ProxyOverride`，缺失时报警，也会检测
TUN。但它无法完整识别 PAC/WPAD、WinHTTP、应用级代理和 WFP 透明转发。请不要用 VPN、机场、
在线优选网站或公共反向代理访问 PT。完整边界见
[design.md 的请求预算](design.md#请求预算)。具体规则以各站为准。

## 要不要把 tracker 域名加进 domains.txt？

不建议。announce 是客户端每 30 分钟发一次的几十字节请求，优选边缘 IP 对它没有任何可感知
的收益；但映射一旦过期或 zone 开始返回 1034，汇报就会失败，客户端显示红种，要等下次重跑
或回滚才恢复。收益为零、风险非零，所以只填网页域名。

- tracker 在独立子域名（如 `tracker.example.com`）时，直接不写进列表即可。
- NexusPHP 常见的 `example.com/announce.php` 和网页是同一个域名，分不开；这种情况只能靠
  定期重跑、出问题 `-Rollback` 兜底。
- 工具只对列表里的域名发根路径 HEAD，不访问 announce，也不连 tracker 端口。

## 需要关掉 Clash / 代理吗？

不需要。所有 curl 都带 `--noproxy '*'`，CFST 启动前也会清空 `HTTP_PROXY/HTTPS_PROXY`
环境变量。控制台仍会显示"系统代理已开启"，那只是信息提示，不代表探测或测速走了代理。

唯一要避免的是 **TUN / 虚拟网卡模式**：检测到 TUN 时，写入、DryRun、Plan 都会中止
（DryRun/Plan 不写 hosts，但同样会真实请求站点），确认风险后可以加 `-Force`。
`-Doctor` 只打 Cloudflare 公共端点，不受这条限制。

## 为什么"探测候选落地区域"要等几分钟？

这一步最多探测 256 个候选，每个请求超时 6 秒、16 并发，典型 2–6 分钟；慢线路会更久。
它是第 3 个大步骤，标题下面有一行 `| 96/256 · 45s` 的转轮，不是卡死；输出被重定向时改为
每 32 个打印一次。各阶段耗时见 [guide.md 的运行时间](guide.md#运行时间)。

## 有没有适合自动化的输出？

有。用 `-Plan` 输出 JSON（不写 hosts、不需要管理员）：

```powershell
.\Cloudflare-Hosts-Optimizer.ps1 -Plan -PlanPath .\plan.json
```

文件里包含 `Decisions`、`Plan`（最终 hosts 的完整 IP→域名映射，包含保留下来的旧条目）和
`Warnings`；`Decisions` 只包含本次实际验证的域名。定时运行的推荐方式见
[guide.md 的定时运行](guide.md#定时运行)。

## 怎么导入域名？

四种来源：PT-Depiler 备份、Windows 代理旁路、文本、剪贴板。

```powershell
.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip'
.\Import-Domains.ps1 -Source ProxyBypass
.\Import-Domains.ps1 -Source Text -Path .\sites.txt
.\Import-Domains.ps1 -Source Clipboard
```

默认输出 `domains.imported.txt`，不会覆盖 `domains.txt`；检查后用 `-Merge` 合并。导入器
只读取备份里的 `metadata.json`，**绝不读取** `cookies.json` / `userInfo.json`。
命令行默认只打印数量；菜单导入会额外列出前 15 个域名供确认。完整说明见
[guide.md 的域名导入](guide.md#域名导入与合并)。

## 我用的是 PTPP，不是 PT-Depiler，可以吗？

PT-Depiler（PTD）是 PTPP 的 Manifest V3 继任者。本导入器针对 PT-Depiler 的备份结构
（`metadata.json` 的 `sites` / `siteHostMap`）。

如果你还在用 PTPP，最方便的方式是用 `-Source ProxyBypass` 或文本导入；
PTPP 备份的 `userdatas.json` 结构不同，当前不保证支持。

## 为什么默认只写 1 个 IP？

hosts 不是带优先级的故障转移配置。即使按 TTFB 顺序写多行，系统和应用也不保证按文件顺序
使用，更不保证首个失败就自动切换。多行反而可能让某些客户端先尝试一个不可用地址。

所以默认 `-TopN 1`。确实想写多个可以 `-TopN 2`，但请理解这不等于冗余。

## 用 CFST 和不用 CFST 有什么区别？

- CFST 的候选覆盖更广（`ip.txt` 当前 25 个网段），通常更容易找到低延迟/低丢包 IP；
- 内置扫描零第三方依赖，但只随机抽 `-MaxCandidates` 个（默认 192），可能漏掉好 IP；
- 两者共用同一套吞吐决赛和逐域名选择，最终差异主要在候选质量。

完整对比见 [design.md](design.md#cfst-与内置扫描)。内置扫描效果不理想时，调大
`-MaxCandidates`（最大 512）再试。

## 为什么每个站写入的 IP 不一样？

全局吞吐排名只用于挑出前 K 个候选（`-CandidatesPerDomain`，默认 3）。每个域名分别与它当前
的 hosts/DNS 路径对比，选 TTFB 最好的那个；不同 zone 的路由和可用 IP 不同，所以结果可能不同。

## 基线对比是什么？为什么有时不切换？

基线 = 该域名当前的 hosts 映射（没有则走系统 DNS）。只有候选比基线快至少
`-MinImprovementPct`（默认 15%）**且**绝对改善至少 `-MinImprovementMs`（默认 30ms），
或基线失败/类别更差时才切换（判定用未舍入的数值，恰好 15%/30ms 不会被浮点误差误拒）。
基线首次可用、准备切换时，基线与选中的候选各复核一次，候选复测失败就不切换；
基线首次就失败时直接按"基线不可用"处理。复核时如果系统解析换了 IP，本次不切换。
想强制换值可以 `-MinImprovementPct 0 -MinImprovementMs 0`。机制见
[design.md](design.md#为什么逐域名选择基线对比)。

## 为什么下载速度没有变快？

hosts 只影响这些域名的网页解析（以及同域名的 tracker 汇报请求）。PT 的 P2P 传输是
BitTorrent 直连，与 hosts 无关，取决于做种人数、你的 IPv6 连通性和运营商互联质量。
网页变快 ≠ 下载变快。

## 1–2 周不重跑，会不会比不写 hosts 还慢？

时间本身不会让一个 IP 变慢；风险来自 CF 路由、运营商互联和 zone 白名单的变化。当初选中的
IP 一直健康的话，速度接近当时测到的水平；但它变慢、不可达或开始返回 1034 时，hosts 不会
自己更新，DNS 却会自动拿到新地址。

建议每 1–2 周重跑，或用 [定时任务](guide.md#定时运行)；站点打不开时先 `-Rollback`。

## 为什么只做 IPv4？我的 IPv6 呢？

在测试线路上，CF 的 IPv6 全部落到 LAX，3MB 下载只有约 83KB/s，明显不如 IPv4 候选。
hosts 写入 A 记录后，Windows 通常不再使用 DNS 的 AAAA，浏览器会走 IPv4；
**BitTorrent 的 IPv6 对等连接不受影响**。可以用 `-CheckResolved` 核对系统实际返回的地址。

## 为什么所有站都显示 Error 1034 / Edge IP Restricted？

Cloudflare 的部分 zone 会限制哪些边缘 IP 可以服务它。即使某个 IP 属于 Cloudflare，如果不
在该 zone 允许的列表里，就会返回 **1034（Edge IP Restricted）**，页面完全打不开。

v0.2.0 曾把 403 一律当成 WAF 放行，因此可能写入这种 IP。v0.2.1 起：403/503 会读响应体识别
1034/1003 并判为不可用；受限时回退到该域名自己的 DNS A 记录（最多 2 条）；如果胜出的是 DNS
记录，动作是**交还 DNS**（删除托管条目、不写 hosts）；可用的旧映射优先于 DNS 回退。

升级后重新运行即可。如果当前页面已经打不开，先 `-Rollback` 恢复，再运行新版。机制见
[design.md](design.md#为什么-dns-回退赢了也不写-hosts)。

## 某个站验证失败怎么办？

默认保留该站上一次的映射（如果之前写过）并告警；只有明确 `1034/1003` 才会自动丢弃。
连接失败/TLS/超时默认保留，可用 `-DropUnreachable` 显式删除。常见原因：

- 站点不是 Cloudflare 托管；
- 站点当前维护或源站故障（TCP/TLS 能连上但 HTTP 无响应）；
- 站点对 HEAD 请求直接断开。

等站点恢复后重跑即可。不要手工把 CF IP 写进去。

## 报错"多别名行" / "foreign-block" / "ipv6-mapping" 是什么？

这是安全中止，不是 bug：

- **多别名行**：hosts 里有一行同时映射了多个主机名，其中包含你的目标域名。自动注释整行会
  误伤其他主机名，所以拒绝处理，让你手工拆分。
- **foreign-block**：hosts 里有其他工具的托管区块（例如 `# S302 BEGIN/END`），其中包含你的
  目标域名。脚本不会接管别的工具的条目。
- **ipv6-mapping**：目标域名在 hosts 里已有 IPv6 条目，写 IPv4 可能仍然无效。

按报错里的行号处理后重跑。规则见 [design.md](design.md#冲突检查)。

## 报错"编码不支持"怎么办？

hosts 只支持 ASCII / UTF-8（含 BOM）。如果文件是 GBK/ANSI 或 UTF-16，脚本会拒绝改写，以免
损坏原文件。用记事本/VS Code 另存为 UTF-8 后重试。

## 跑不通 / 测不出速度，怎么排查？

先跑 `-Doctor`。它不写 hosts、不需要管理员、不访问目标站（管理员模式下会在备份目录创建
一个临时可写性探针再删掉，这不是"零 IO"）：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Cloudflare-Hosts-Optimizer.ps1 -Doctor
```

它会按 `OK / WARN / FAIL / SKIP` 列出环境、hosts 结构、域名文件、CFST 与 `ip.txt`、
探测/测速端点、代理/TUN、备份目录、机房缓存和计划任务；有 FAIL 时退出码为 1。
最常见的两类：

- **测速端点 FAIL**：换 `-SpeedTestUrl`，或检查网络；
- **区块外冲突 FAIL**：按提示的行号手动处理 hosts 后再运行。

## 测速地址 403 怎么办？

默认测速地址是 `https://speed.cloudflare.com/__down?bytes={bytes}`。如果访问不了，可以用
`-SpeedTestUrl` 换成自建地址，例如参考
[cmliu/CF-Workers-SpeedTestURL](https://github.com/cmliu/CF-Workers-SpeedTestURL)。

工具只校验 https、不带凭据，以及样本是否 HTTP 200、够 `{bytes}` 字节、不重定向；
**它无法证明你的地址真的由 Cloudflare 托管**——那是你选择地址时的责任，选错了测速结果
就不可比。

## 会消耗多少流量？

一次完整运行约 **70MB**（32MB 吞吐初测 + 36MB 决赛，其余是 trace 和 HEAD 请求）。
明细和可调参数见 [guide.md 的流量说明](guide.md#一次运行多少流量)。

## 为什么需要管理员权限？

写入 `C:\Windows\System32\drivers\etc\hosts` 需要管理员；`-DryRun`、`-Plan`、`-Doctor`
都不需要。菜单里点"正式写入"会自己弹 UAC，取消就回到菜单，不会中断。

如果点了没反应，检查 UAC 是不是被取消或被杀毒软件拦截；管理员窗口结束后主窗口会显示
退出码。正式写入（以及 DryRun/Plan 在指定 `-ReportPath` 时）会写报告；**回滚默认不覆盖
`last-report.txt`**，只在 `last-run.json` 里更新运行摘要。

## 怎么完全卸载？

先删掉可能注册过的计划任务（没注册过会显示"不存在（无需删除）"）：

```powershell
.\Cloudflare-Hosts-Optimizer.ps1 -UninstallTask
```

再回滚 hosts：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Cloudflare-Hosts-Optimizer.ps1 -Rollback
```

然后删除整个目录。脚本本身不安装服务或驱动；只有显式运行 `-InstallTask` 才会注册计划任务。
备份在 `%ProgramData%\Cloudflare-Hosts-Optimizer\backup`，机房缓存在
`%LOCALAPPDATA%\Cloudflare-Hosts-Optimizer\colo-cache.json`，都可以一并删除。

## 会覆盖 hosts 里的其他内容吗？

不会。只处理域名列表里的域名和一对标记区块；其他行保持不变（在支持的编码下）。写入前
自动备份；替换前失败不会碰 hosts，替换后读回不一致会自动从备份还原。如果失败发生在
"已经替换、但提交标记没写成"的极小窗口，工具会如实报告"已写入、标记未完成"，
回滚仍能识别这次提交。细节见 [design.md 的 hosts 一节](design.md#hosts-写入与安全规则)。

## 能在 Linux / 路由器 / macOS 上用吗？

目前不支持。脚本依赖 Windows 的代理注册表、`Get-NetAdapter` 和 `ipconfig`。Linux/路由器
场景可以参考 [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)
官方的 `cfst_hosts.sh`，或社区里的 OpenWrt 方案。
