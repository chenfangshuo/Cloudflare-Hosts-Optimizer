# pt-cf-optimize

优选 Cloudflare 边缘 IP 并安全写入 Windows hosts，适合访问 PT 站、论坛等由 Cloudflare 托管的站点。

> 不代理、不登录、不改出口 IP。只改 hosts 中由本工具管理的域名，支持一键回滚。

## 它解决什么问题

使用 Cloudflare 的站点在中国大陆访问时，默认经常落到 LAX/SJC 等远端机房，握手 200–340ms。
把域名指向一个实测更快的 CF 边缘 IP 可以明显改善网页和 tracker 的响应。

但直接照搬"优选 IP 写 hosts"的脚本有几个坑：

1. **CFST 的默认测速地址可能失效**。例如 `cf.xiu2.xyz/url` 返回 403 时，官方
   `cfst_hosts` 脚本会把 403 小页面算成虚高速度（实测 15 MB/s，真实只有 0.48 MB/s）。
2. **延迟最低 ≠ 实际最快**。HKG 边缘握手只要 130ms，但大流量丢包严重，3MB 下载可能直接卡死。
3. **不是所有站都适合写 hosts**。非 CF 站点、DNS 被污染的站点、当前故障的站点，
   盲目写入会让原本能用的站直接打不开。
4. **hosts 是全局文件**。手工改容易破坏其他条目，也很难回滚。

本工具针对这四点做了处理。

## 特性

- **Windows 原生**：PowerShell 7 + 系统自带 `curl.exe`，无需 WSL、Python 或 Node。
- **CFST 只做延迟/丢包筛选**（`-dd`），吞吐量由本脚本独立实测，不信任第三方测速地址。
- **按落地机房分层抽样**（LAX / SJC / HKG / FRA …），避免候选被单一机房占满。
- **逐域名 HEAD 验证**：每个域名对每个候选 IP 发 1 次请求，按真实 TTFB 排序；
  两个 IP 都不通的域名保持原样。
- **非破坏式 hosts 管理**：标记区块、旧条目注释而非删除、幂等、自动备份、`-Rollback`。
- **安全边界检查**：检测系统代理旁路是否覆盖目标域名、是否存在 TUN 网卡、
  强制 curl 直连，避免测速和访问走代理。
- **没有 CFST 也能用**：自动回退到内置 PowerShell 扫描（候选集较小）。

## 与其他工具的关系

- [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)（GPL-3.0）是本项目的
  优选引擎。本仓库**不包含**也不分发它的二进制，需要你自行下载。
- 官方 `cfst_hosts.bat` 做的是"把 hosts 里所有旧 CF IP 全局替换成新 IP"，依赖一个统一的旧 IP，
  且使用默认测速地址。本工具改为按域名管理、逐站验证、可回滚。
- 如果希望自定义测速地址，可以参考
  [cmliu/CF-Workers-SpeedTestURL](https://github.com/cmliu/CF-Workers-SpeedTestURL) 自建一个。

## 要求

- Windows 10 / 11
- PowerShell 7+（`pwsh`）
- `curl.exe`（Windows 10 1803+ 自带）
- 可选：[CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest/releases) 的 `cfst.exe`

## 安装

```powershell
git clone <repo-url>
cd pt-cf-optimize
Copy-Item domains.example.txt domains.txt
notepad domains.txt
```

可选：把 CFST 压缩包里的 `cfst.exe` 和 `ip.txt` 放到 `cfst\` 目录：

```
pt-cf-optimize\
  cfst\
    cfst.exe
    ip.txt
```

不放也能用，脚本会自动回退到内置扫描。

## 快速开始

```powershell
# 1) 先看结果，不写 hosts（不需要管理员）
pwsh -NoProfile -ExecutionPolicy Bypass -File .\pt-cf-optimize.ps1 -DryRun

# 2) 以管理员身份正式写入
pwsh -NoProfile -ExecutionPolicy Bypass -File .\pt-cf-optimize.ps1

# 3) 出问题时一键回滚
pwsh -NoProfile -ExecutionPolicy Bypass -File .\pt-cf-optimize.ps1 -Rollback
```

`-DryRun` 也会发少量网络请求（每域名每 IP 1 次 HEAD），但不会修改任何文件。

## 配置域名

`domains.txt` 每行一个域名，`#` 开头为注释。只填**确认由 Cloudflare 代理**的域名：

```powershell
curl.exe -sI https://example.com | findstr /i "server:"
```

返回 `server: cloudflare` 才可以加入。不是 CF 的站点填进来会被逐站验证自动跳过，
不会写坏，但也没有优化效果。

`domains.txt` 已加入 `.gitignore`，站点清单不会进入版本库。

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-DryRun` | | 只扫描和验证，不写 hosts |
| `-Rollback` | | 用最近一次备份恢复 hosts |
| `-Version` | | 打印版本号并退出 |
| `-NoCfst` | | 不查找 cfst.exe，强制内置扫描 |
| `-TopN` | 2 | 最终写入的 IP 数（1–3） |
| `-Domains` | | 直接指定域名（优先于 domains.txt） |
| `-DomainsFile` | `.\domains.txt` | 域名文件路径 |
| `-CfstPath` | 自动查找 | cfst.exe 路径 |
| `-SpeedTestUrl` | `https://speed.cloudflare.com/__down?bytes={bytes}` | 吞吐测速地址，`{bytes}` 为占位符 |
| `-ScanSamples` | 2 | 内置扫描每个 IP 的探测次数 |
| `-MaxCandidates` | 192 | 内置扫描的候选 IP 数 |
| `-ThroughputCandidates` | 32 | 参与吞吐初测的 IP 数 |
| `-ThroughputSamples` | 1 | 初测每个 IP 的采样次数 |
| `-ThroughputBytes` | 1000000 | 初测下载字节数 |
| `-RefineTop` | 6 | 吞吐前 N 名再做 3MB×2 复核 |
| `-VerifyDelayMs` | 400 | 域名验证之间的间隔 |

## 工作原理

详见 [docs/how-it-works.md](docs/how-it-works.md)。简述：

1. CFST 全量扫描 CF IPv4 段的延迟和丢包（不做下载测速）。
2. 取延迟最低的 64 个候选，探测各自落地的 CF 机房。
3. 按机房分层抽样 32 个，用 `-SpeedTestUrl` 做 1MB 吞吐初测。
4. 前 6 名再做 3MB×2 复核，按吞吐排序。
5. 每个域名对前 N 个 IP 各发 1 次 HEAD，按真实 TTFB 排序。
6. 备份 hosts，只替换标记区块，刷新 DNS。

## 安全边界

- 只改 hosts 中列出的域名，其他内容逐字节保留。
- 只向测速地址做批量请求；对目标站仅每域名每 IP 1 次 HEAD，不登录、不带 Cookie、不爬页面。
- 不改系统 DNS、网卡、防火墙、代理配置。
- **不改变出口 IP**：前提是这些域名在代理旁路里。脚本会检查 Windows 系统代理的
  `ProxyOverride` 并在缺失时报警；也会检测 TUN 网卡。
- 不使用 VPN、机场、在线优选网站或公共反向代理——这些才会改变出口 IP。

PT 站的具体规则以各站为准。本项目不 affiliated with 任何 PT 站。

## 常见问题

见 [docs/faq.md](docs/faq.md)。

- 网页变快 ≠ 下载变快：hosts 不影响 P2P 传输。
- 写入 A 记录后，Windows 对这些域名不再使用 DNS 的 AAAA（浏览器走 IPv4 优选）；
  BitTorrent 的 IPv6 对等连接不受影响。
- CF 路由会变，建议每 1–2 周或感觉变慢时重跑。
- 某站验证失败时会保持原样，不会把站写挂。

## 开发与测试

```powershell
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path .\tests -Output Detailed
```

测试只覆盖离线的 `Update-HostsFile` 函数，不访问网络、不碰真实 hosts。
CI 在 `windows-latest` 上运行语法检查、PSScriptAnalyzer 和 Pester。

## 致谢

- [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) — 优选引擎（GPL-3.0）
- [cmliu/CF-Workers-SpeedTestURL](https://github.com/cmliu/CF-Workers-SpeedTestURL) — 自建测速地址的思路

## License

[MIT](LICENSE)。本仓库不包含 CloudflareSpeedTest 的代码或二进制。

---

## English

A Windows PowerShell tool that picks the fastest Cloudflare edge IPs and writes them into
the hosts file, intended for Cloudflare-proxied sites (PT trackers, forums, etc.).

It uses CloudflareSpeedTest for latency/loss screening only, measures throughput independently,
samples candidates across edge colos, verifies every domain with a single HEAD request, and
manages hosts entries in a tagged, idempotent, reversible block.

Requirements: Windows 10/11, PowerShell 7+, curl.exe. CFST is optional and not bundled.
