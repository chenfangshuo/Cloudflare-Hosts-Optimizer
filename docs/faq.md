# FAQ

## 会不会导致 PT 站封号？

本工具不改变你的出口 IP：它只改"连到哪个 CF 边缘节点"，流量仍然从你的家宽直接出去，
登录 IP、tracker 上报 IP 都不变。

前提是这些域名在代理旁路里。脚本会检查 WinINET 的 `ProxyOverride`，缺失时报警；
也会检测 TUN 网卡。但它无法完整识别 PAC/WPAD、WinHTTP、应用级代理和 WFP 透明转发。
请不要用 VPN、机场、在线优选网站或公共反向代理访问 PT。

验证阶段每域名每 IP 最多发 2 次 HEAD（准备切换时复核一次），不登录、不带 Cookie、
不访问 announce URL。具体规则以各站为准。

## 需要关掉 Clash / 代理吗？

不需要。脚本里所有 curl 都带 `--noproxy '*'`，CFST 启动前也会清空
`HTTP_PROXY/HTTPS_PROXY` 环境变量。控制台仍会显示“系统代理已开启”，那只是信息提示，
不代表探测或测速走了代理。

唯一要避免的是 **TUN / 虚拟网卡模式**。检测到 TUN 时，非 DryRun 会中止；
确认风险后可以加 `-Force`。

## 为什么“探测候选落地区域”要等几分钟？

这一步最多探测 256 个候选，每个请求超时 6 秒、16 并发，典型 2–6 分钟；慢线路会更久。
现在每 32 个会打印一次“已探测 x/256”，不是卡死。完整运行的耗时见 README 的
“大概要跑多久”。

## 怎么导入域名？

四种来源：

```powershell
# PT-Depiler 备份（推荐；建议关闭备份加密后导出）
.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip'

# Windows 系统代理旁路列表（零文件、零网络）
.\Import-Domains.ps1 -Source ProxyBypass

# 文本 / 剪贴板
.\Import-Domains.ps1 -Source Text -Path .\sites.txt
.\Import-Domains.ps1 -Source Clipboard
```

默认输出 `domains.imported.txt`，不会覆盖 `domains.txt`。检查后用
`-Merge` 合并，或手工复制。完整说明（PTD 选项、隐私边界、合并流程）见
[importing.md](importing.md)。

导入器只读取 PT-Depiler 备份里的 `metadata.json`，**绝不读取 `cookies.json` /
`userInfo.json`**；控制台只打印数量，不打印域名、passkey 或完整 URL。

## 我用的是 PTPP，不是 PT-Depiler，可以吗？

PT-Depiler（PTD）是 PTPP 的 Manifest V3 继任者。本导入器针对 PT-Depiler 的备份结构
（`metadata.json` 的 `sites` / `siteHostMap`）。

如果你还在用 PTPP，最方便的方式是用 `-Source ProxyBypass` 或文本导入；
PTPP 备份的 `userdatas.json` 结构不同，当前不保证支持。

## 为什么默认只写 1 个 IP？

hosts 不是带优先级的故障转移配置。即使按 TTFB 顺序写多行，系统和应用也不保证
按文件顺序使用，更不保证首个失败就自动切换。多行反而可能让某些客户端先尝试一个不可用地址。

所以默认 `-TopN 1`。确实想写多个可以 `-TopN 2`，但请理解这不等于冗余。

## 用 CFST 和不用 CFST 有什么区别？

见 README 的对比表。简言之：

- CFST 的候选覆盖更广（`ip.txt` 当前 25 个网段），通常更容易找到低延迟/低丢包 IP；
- 内置扫描零第三方依赖，但只随机抽 `-MaxCandidates` 个（默认 192），可能漏掉好 IP；
- 两者共用同一套吞吐决赛和逐域名选择，最终差异主要在候选质量。

如果内置扫描效果不理想，调大 `-MaxCandidates`（最大 512）再试。

## 为什么每个站写入的 IP 不一样？

全局吞吐排名只用于挑出前 K 个候选（`-CandidatesPerDomain`，默认 3）。
每个域名会分别与它当前的 hosts/DNS 路径对比，选 TTFB 最好的那个；
不同 zone 的路由和可用 IP 不同，所以结果可能不同。

## 基线对比是什么？为什么有时不切换？

基线 = 该域名当前的 hosts 映射（没有则走系统 DNS）。只有候选比基线快至少
`-MinImprovementPct`（默认 15%）**且**绝对改善至少 `-MinImprovementMs`（默认 30ms），
或基线失败/类别更差时才切换。准备切换时，基线与选中的候选各复核一次，候选复测失败
就不切换；时间统计都扣掉了 DNS 解析时间，基线和候选是同一口径。
如果想让某个站强制换值，可以 `-MinImprovementPct 0 -MinImprovementMs 0`。

## 为什么下载速度没有变快？

hosts 只影响这些域名的网页和 tracker 通告。PT 的 P2P 传输是 BitTorrent 直连，
与 hosts 无关，取决于做种人数、你的 IPv6 连通性和运营商互联质量。
网页变快 ≠ 下载变快。

## 为什么只做 IPv4？我的 IPv6 呢？

在测试线路上，CF 的 IPv6 全部落到 LAX，3MB 下载只有约 83KB/s，明显不如 IPv4 候选。

hosts 写入 A 记录后，Windows 通常不再使用 DNS 的 AAAA，浏览器会走 IPv4。
**BitTorrent 的 IPv6 对等连接不受影响**。可以用 `-CheckResolved` 核对系统实际返回的地址。

## 为什么所有站都显示 Error 1034 / Edge IP Restricted？

Cloudflare 的部分 zone 会限制哪些边缘 IP 可以服务它。即使某个 IP 属于 Cloudflare，
如果不在该 zone 允许的列表里，就会返回 **1034（Edge IP Restricted）**，页面完全打不开。

v0.2.0 曾把 403 一律当成 WAF 放行，因此可能写入这种 IP。v0.2.1 起：

- 403/503 会读取响应体，识别 1034/1003 并判定为不可用；
- 受限时回退到该域名自己的 DNS A 记录（最多 2 条）；
- 如果胜出的是 DNS 记录，动作是**交还 DNS**：删除托管条目、不写 hosts，避免把临时 IP
  固定下来；区块外已有的旧条目/手工条目不会被删除，仍会生效，脚本会告警；
- 上次写坏的旧映射只有在明确 `1034/1003` 时才会自动丢弃；连接失败默认保留并告警；
- 可用的旧映射优先于 DNS 回退。

升级后重新运行即可。如果当前页面已经打不开，先 `-Rollback` 恢复，再运行新版。

## 某个站验证失败怎么办？

脚本默认保留该站上一次的映射（如果之前写过）并告警；只有明确 `1034/1003`
（边缘 IP 受限）才会自动丢弃。连接失败/TLS/超时默认保留，可用 `-DropUnreachable`
显式删除。常见原因：

- 站点不是 Cloudflare 托管；
- 站点当前维护或源站故障（TCP/TLS 能连上但 HTTP 无响应）；
- 站点对 HEAD 请求直接断开。

等站点恢复后重跑即可。不要手工把 CF IP 写进去。

## 报错"多别名行" / "foreign-block" / "ipv6-mapping" 是什么？

这是安全中止，不是 bug：

- **多别名行**：hosts 里有一行同时映射了多个主机名，其中包含你的目标域名。
  自动注释整行会误伤其他主机名，所以脚本拒绝处理，让你手工拆分。
- **foreign-block**：hosts 里有其他工具的托管区块（例如 `# S302 BEGIN/END`），
  其中包含你的目标域名。脚本不会接管别的工具的条目。
- **ipv6-mapping**：目标域名在 hosts 里已有 IPv6 条目，写 IPv4 可能仍然无效。

按报错里的行号处理后重跑。

## 报错"编码不支持"怎么办？

hosts 只支持 ASCII / UTF-8（含 BOM）。如果文件是 GBK/ANSI 或 UTF-16，
脚本会拒绝改写，以免损坏原文件。用记事本/VS Code 另存为 UTF-8 后重试。

## 测速地址 403 怎么办？

默认测速地址是 `https://speed.cloudflare.com/__down?bytes={bytes}`。
如果访问不了，可以用 `-SpeedTestUrl` 换成自建地址，例如参考
[cmliu/CF-Workers-SpeedTestURL](https://github.com/cmliu/CF-Workers-SpeedTestURL)。

自定义地址必须：https、由 Cloudflare 托管、返回 HTTP 200、至少返回 `{bytes}` 字节、
不重定向、不带凭据。否则样本会被判定为无效。

## 会消耗多少流量？

一次完整运行大致：

- 延迟扫描：每个候选几十字节的 trace 请求。
- 吞吐初测：32 × 1MB ≈ 32MB。
- 决赛：6 × 3 × 2MB ≈ 36MB。
- 站点验证：每域名 1 次基线 HEAD + 前 K 个候选 + 补位 + 旧映射 + DNS 回退
  + 切换前复核 2 次；典型约 6–10 次、最坏 11 次 HEAD。403/503 还会额外发 1 次
  小 GET（≤64KB）识别 1034；HEAD/GET 本身流量可忽略。

合计约 70MB，可通过 `-ThroughputCandidates`、`-ThroughputBytes`、`-RefineTop` 调整。

## 为什么需要管理员权限？

写入 `C:\Windows\System32\drivers\etc\hosts` 需要管理员。`-DryRun` 不需要。

## 怎么完全卸载？

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\pt-cf-optimize.ps1 -Rollback
```

然后删除整个目录。脚本不会安装服务、驱动或计划任务。
备份在 `%ProgramData%\pt-cf-optimize\backup`，可一并删除。

## 会覆盖 hosts 里的其他内容吗？

不会。只处理域名列表里的域名和一对标记区块；其他行保持不变（在支持的编码下）。
写入前自动备份，失败自动还原，可以随时 `-Rollback`。

## 能在 Linux / 路由器 / macOS 上用吗？

目前不支持。脚本依赖 Windows 的代理注册表、`Get-NetAdapter` 和 `ipconfig`。
Linux/路由器场景可以参考
[XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) 官方的
`cfst_hosts.sh`，或社区里的 OpenWrt 方案。
