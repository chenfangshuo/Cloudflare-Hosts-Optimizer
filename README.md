# pt-cf-optimize

优选 Cloudflare 边缘 IP 并安全写入 Windows hosts，适合访问 PT 站、论坛等由 Cloudflare 托管的站点。
支持从 **PT-Depiler 备份 / 代理旁路列表 / 文本 / 剪贴板** 导入域名。

> 不代理、不登录、不改出口 IP。严格校验 hosts，增量更新，可一键回滚。

## 它解决什么问题

使用 Cloudflare 的站点在中国大陆访问时，默认经常落到 LAX/SJC 等远端机房，握手 200–340ms。
把域名指向一个实测更快的 CF 边缘 IP 可以改善网页和 tracker 的响应。

直接照搬"优选 IP 写 hosts"的脚本有几个坑：

1. **CFST 的默认测速地址可能失效**。例如 `cf.xiu2.xyz/url` 返回 403 时，会把 403 小页面
   算成虚高速度（作者在某条联通线路上实测 15 MB/s，独立 3MB 复测只有 0.48 MB/s）。
2. **延迟最低 ≠ 实际最快**。HKG 边缘握手可能只要 130ms，但大流量丢包严重，3MB 下载可能卡死。
3. **不是所有站都适合写 hosts**。非 CF 站点、DNS 被污染的站点、当前故障的站点，
   盲目写入会让原本能用的站打不开。
4. **hosts 是全局文件**。手工改容易破坏其他条目，也很难回滚。

## 特性

- **Windows 原生**：PowerShell 7 + 系统自带 `curl.exe`，无需 WSL、Python 或 Node。
- **CFST 只做延迟/丢包筛选**（`-dd`），吞吐量由本脚本独立实测，不信任第三方测速地址。
- **按落地机房分层抽样**（LAX / SJC / HKG / FRA …），避免候选被单一机房占满。
- **决赛只使用决赛成绩**：3 × 2MB、串行测速；样本必须退出码 0、HTTP 200/206、
  字节数达标、实际远端 IP 匹配；决赛失败的 IP 直接淘汰，不保留初测高分。
- **逐域名 HEAD 验证**：2xx/3xx/401/403 视为可连通，403 标记为 WAF/受限；
  会读取 403/503 的响应体，识别 Cloudflare **Error 1034 / 1003（Edge IP Restricted）**
  并判定为不可用；验证失败的域名保留上一次的映射。
- **边缘受限回退**：如果目标 zone 不允许任意 CF IP，工具会回退到该域名自己的
  DNS A 记录（最多 2 条），而不是把站点写挂。
- **严格的 hosts 校验**：标记不完整/重复、无法识别的编码、多别名行、IPv6 映射、
  其他工具的托管区块，都会直接拒绝改写。
- **事务式写入**：互斥锁、提交前哈希检查、备份清单、临时文件 + 原子替换、读回校验。
- **回滚不依赖域名配置**：`-Rollback` 在 `domains.txt` 缺失时仍可用。
- **域名导入**：PT-Depiler 备份、Windows 代理旁路、文本/剪贴板；导入阶段不访问网络。
- **默认每个域名只写 1 个 IP**：hosts 不是带优先级的故障转移配置。

## 要求

- Windows 10 / 11
- PowerShell 7+（`pwsh`）
- `curl.exe`（Windows 10 1803+ 自带；优先使用 `%SystemRoot%\System32\curl.exe`）
- 可选：[CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest/releases) 的 `cfst.exe`

## 安装

```powershell
git clone <repo-url>
cd pt-cf-optimize
```

可选：把 CFST 压缩包里的 `cfst.exe` 和 `ip.txt` 放到 `cfst\` 目录：

```
pt-cf-optimize\
  cfst\
    cfst.exe
    ip.txt
```

不放也能用，脚本会自动回退到内置扫描。

## 导入域名

### 从 PT-Depiler 备份（推荐）

1. 在 PT-Depiler 里导出备份（建议**关闭备份加密**，导入器不处理密码）。
2. 运行：

```powershell
.\Import-Domains.ps1 -Source Depiler -Path 'C:\path\to\PTD_backup.zip'
```

默认只读取备份 ZIP 里的 `metadata.json`，取每个站点的 `url` 主机名；
离线站点默认跳过。可选：

```powershell
# 同时导入 siteHostMap 里的备用/CDN 主机名
.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip' -IncludeAlternates

# 包含离线站点
.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip' -IncludeOffline
```

**隐私边界**：导入器只打开 `metadata.json`，绝不读取 `cookies.json`、`userInfo.json`、
`downloadHistory.json`；控制台只打印数量，不打印域名、passkey 或完整 URL。

### 从 Windows 代理旁路列表

如果你已经把所有 PT 域名加进了代理旁路，这一步是零文件、零网络的：

```powershell
.\Import-Domains.ps1 -Source ProxyBypass
```

列表可能包含非 PT 域名（例如 test-ipv6、Steam），请人工筛选。

### 从文本或剪贴板

```powershell
.\Import-Domains.ps1 -Source Text -Path .\sites.txt
.\Import-Domains.ps1 -Source Clipboard
```

会提取文本里的 URL 和裸主机名；URL 路径不会被误当成域名。

### 检查并合并

默认输出 `domains.imported.txt`，**不会覆盖 domains.txt**。人工检查后可以：

```powershell
# 合并新增域名到 domains.txt（先备份、幂等）
.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip' -Merge
```

或者手工把需要的行复制进 `domains.txt`。

## 快速开始

```powershell
# 1) 先看结果，不修改 hosts（不需要管理员）
pwsh -NoProfile -ExecutionPolicy Bypass -File .\pt-cf-optimize.ps1 -DryRun

# 2) 以管理员身份正式写入
pwsh -NoProfile -ExecutionPolicy Bypass -File .\pt-cf-optimize.ps1

# 3) 出问题时一键回滚
pwsh -NoProfile -ExecutionPolicy Bypass -File .\pt-cf-optimize.ps1 -Rollback
```

`-DryRun` **不修改 hosts**，也不写持久报告（除非显式给 `-ReportPath`）；CFST 的输出会放在
临时目录并清理。它仍会做网络探测，一次完整运行大约消耗 70MB 流量
（32 个候选 × 1MB 初测 + 前 6 名 × 3 × 2MB 决赛）。

## 配置域名

`domains.txt` 每行一个域名，`#` 开头为注释。只填**确认由 Cloudflare 代理**的域名：

```powershell
curl.exe -sI https://example.com | findstr /i "server:"
```

返回 `server: cloudflare` 是线索，不是充分必要条件（其他 CDN 也可能返回类似头）。
不是 CF 的站点会被逐站验证自动跳过，但属于"尽力而为"，不是绝对保证。

`domains.txt` 已加入 `.gitignore`，站点清单不会进入版本库。

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-DryRun` | | 只扫描和验证，不修改 hosts |
| `-Rollback` | | 用最近一次备份恢复 hosts（不依赖 domains.txt） |
| `-Version` | | 打印版本号并退出 |
| `-NoCfst` | | 不查找 cfst.exe，强制内置扫描 |
| `-Force` | | 回滚时允许覆盖被其他程序改过的 hosts；或允许在 TUN 环境下继续 |
| `-Prune` | | 删除不再出现在域名列表中的历史托管映射 |
| `-CheckResolved` | | 写入后解析每个域名，报告系统实际返回的地址 |
| `-ExperimentalRanges` | | 允许扫描 CF 官方列表之外的 104.28.0.0/14 |
| `-TopN` | 1 | 每个域名写入的 IP 数（1–3） |
| `-Domains` | | 直接指定域名（严格模式：拒绝 URL/端口/路径） |
| `-DomainsFile` | `.\domains.txt` | 域名文件路径 |
| `-CfstPath` | 自动查找 | cfst.exe 路径 |
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

## hosts 安全规则

- **标记**：只接受"没有标记"或"恰好一对 BEGIN/END 且顺序正确"。缺失 END、重复、
  嵌套、孤立 END → 中止并报告行号。
- **多别名行**：托管区块外，如果某行包含受管域名且该行有多个主机名 → 中止，
  要求人工处理；不会自动注释整行。
- **IPv6 映射**：受管域名在 hosts 里已有 IPv6 条目 → 中止，避免"写了 IPv4 却仍走 IPv6"。
- **其他工具的区块**：检测到 `# XXX BEGIN ... / # XXX END ...` 且其中包含受管域名 → 中止，
  不接管其他工具的条目。
- **编码**：只支持 ASCII / UTF-8（含 BOM）。UTF-16、GBK/ANSI 等无法可靠识别的编码 → 拒绝，
  不会冒险改写。
- **增量**：验证成功 → 更新；验证失败 → 保留上一次映射；不在本次列表 → 默认保留，
  `-Prune` 才删除。
- **备份**：`%ProgramData%\pt-cf-optimize\backup`（不可写时回退项目目录），
  文件名含时间戳和 GUID，附带 JSON 清单（pre/post 哈希）；按文件名选最近，
  不依赖 LastWriteTime；保留最近 10 份 + 一份首次接管快照。
- **写入**：全局互斥锁 → 提交前哈希检查 → 临时文件 → 原子替换 → 读回校验。
- **回滚**：如果 hosts 在最后一次写入后被其他程序改过，默认拒绝覆盖，`-Force` 才允许。

## 工作原理

详见 [docs/how-it-works.md](docs/how-it-works.md)。简述：

1. CFST 全量扫描 CF 官方 IPv4 段的延迟和丢包（不做下载测速）。
2. 取延迟最低的 256 个候选，探测各自落地的 CF 机房。
3. 按机房分层抽样 32 个，用 `-SpeedTestUrl` 做 1MB 吞吐初测。
4. 前 6 名进入决赛：3 × 2MB、串行，只保留有效样本 ≥2 的 IP。
5. 每个域名对前 N 个 IP 各发 1 次 HEAD，按状态类别和真实 TTFB 排序。
   如果返回 Cloudflare Error 1034/1003（边缘 IP 受限），该 IP 判为不可用，
   并回退到该域名自己的 DNS A 记录。
6. 读取 hosts、严格校验、增量合并、备份、原子替换、刷新 DNS。
   上一次写坏的旧映射（1034/连接失败）会被丢弃。

## 安全边界

- 只改 hosts 中列出的域名，其他内容保持不变（在支持的编码下）。
- 只向测速地址做批量请求；对目标站仅每域名每 IP 1 次 HEAD，不登录、不带 Cookie、
  不访问 announce URL、不读取 passkey。
- 不改系统 DNS、网卡、防火墙、代理配置。
- **不改变出口 IP**：前提是这些域名在代理旁路里。脚本会检查 WinINET 旁路并在缺失时报警，
  也会检测 TUN 网卡；但它**无法完整识别** PAC/WPAD、WinHTTP、应用级代理、WFP 透明转发。
- 不使用 VPN、机场、在线优选网站或公共反向代理。

PT 站的具体规则以各站为准。本项目不 affiliated with 任何 PT 站。

## 常见问题

见 [docs/faq.md](docs/faq.md)。

- 网页变快 ≠ 下载变快：hosts 不影响 P2P 传输。
- 写入 A 记录后，Windows 通常不再使用 DNS 的 AAAA；应用自带解析器可能不同。
- hosts 多行不保证优先级或自动故障转移，所以默认只写 1 个 IP。
- CF 路由会变，建议每 1–2 周或感觉变慢时重跑。
- 某站验证失败时会保留旧映射，不会把站写挂。

## 开发与测试

```powershell
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path .\tests -Output Detailed
```

测试覆盖：编码拒绝、标记结构、多别名/IPv6/外部区块、增量与 Prune、吞吐样本有效性、
备份选择、原子写入/回滚、导入器、CIDR 与分层抽样。全部离线，使用临时目录和合成备份。

CI 在 `windows-latest` 上运行语法检查、PSScriptAnalyzer 和 Pester。

## 致谢

- [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) — 优选引擎（GPL-3.0）
- [PT-Depiler](https://github.com/pt-plugins/PT-depiler) — 备份导入的字段结构参考
- [cmliu/CF-Workers-SpeedTestURL](https://github.com/cmliu/CF-Workers-SpeedTestURL) — 自建测速地址

## License

[MIT](LICENSE)。本仓库不包含 CloudflareSpeedTest 的代码或二进制。

---

## English

A Windows PowerShell tool that picks the fastest Cloudflare edge IPs and writes them into
the hosts file, for Cloudflare-proxied sites (PT trackers, forums, etc.).

It uses CloudflareSpeedTest for latency/loss screening only, measures throughput independently,
samples candidates across edge colos, verifies every domain with a single HEAD request, and
manages hosts entries in a tagged, idempotent, reversible block. Domain lists can be imported
from a PT-Depiler backup, the Windows proxy bypass list, text, or the clipboard.

Requirements: Windows 10/11, PowerShell 7+, curl.exe. CFST is optional and not bundled.
