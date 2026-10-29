# pt-cf-optimize

优选 Cloudflare 边缘 IP 并安全写入 Windows hosts，让 PT 站、论坛等 CF 站点的网页和 tracker 更快。

> 不代理、不登录、不改出口 IP；严格校验 hosts，增量更新，一键回滚。

Windows 10/11 · PowerShell 7+ · 系统自带 `curl.exe` · CFST 可选

## 快速开始

**1）[准备域名](#准备域名)**

复制 `domains.example.txt` 为 `domains.txt`，每行一个域名。只填**确认由 Cloudflare 代理**的站点：

```powershell
curl.exe -sI https://example.com | findstr /i "server:"
```

返回 `server: cloudflare` 是线索，不是绝对保证；不是 CF 的站点会在逐站验证时被跳过。

**2）可选：放好 CFST（效果更好）**

从 [CloudflareSpeedTest releases](https://github.com/XIU2/CloudflareSpeedTest/releases)
下载后，把 `cfst.exe` 和 `ip.txt` 放到脚本旁的 `cfst\` 目录：

```text
pt-cf-optimize\
  cfst\
    cfst.exe
    ip.txt
```

不放也能用，脚本会自动回退到内置扫描；覆盖和速度差异见
[CFST vs 内置扫描](#cfst-vs-内置扫描)。

**3）先看结果**（不需要管理员，不修改 hosts）

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\pt-cf-optimize.ps1 -DryRun
```

**4）正式写入**（管理员 PowerShell）

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\pt-cf-optimize.ps1
```

**5）出问题一键回滚**

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\pt-cf-optimize.ps1 -Rollback
```

第一次运行约 **8–15 分钟**。`探测候选落地区域（256 个）` 本身就要几分钟，现在每 32 个
会打印一次 `已探测 x/256`，不会看起来像卡死。各阶段耗时见[运行时间](#大概要跑多久)。

## 运行效果

域名和部分数字已替换为示例；实际输出会多出扫描和测速的表格。

```text
==== Cloudflare 优选 IP -> hosts ====
hosts: C:\Windows\System32\drivers\etc\hosts
域名数: 12

代理：WinINET 系统代理已开启 -> 127.0.0.1:7890
  注意：本工具的 curl 都带 --noproxy *，CFST 也会清空代理环境变量；探测和测速强制直连，不走这个代理。
旁路：目标域名均在 ProxyOverride 中（仅代表 WinINET 层直连）。
网卡：未发现已知 TUN 虚拟网卡（这不等于已证明直连）。

使用 CFST 做全量延迟扫描（可能需要 1–3 分钟）：...\cfst\cfst.exe
延迟/丢包筛选后可用 IP：1631，最佳 162.159.146.94（133ms）
探测候选落地区域（256 个，可能需要几分钟，每 32 个打印一次进度）...
  已探测 32/256（38s）
  已探测 64/256（79s）
分层抽样 32 个（SJC x8, LAX x8, HKG x4, FRA x1, ...）
...
逐域名验证与选择（基线 = 当前 hosts/DNS 路径）...
  pt.example.com          切换 104.17.143.151 -> 162.159.160.5  [confirmed]
  forum.example.org       保留 104.17.131.149  [below-threshold]

已写入 hosts（备份：C:\ProgramData\pt-cf-optimize\backup\hosts-20261029-120000-xxxxxxxx.bak）

==== 逐域名决策 ====
Domain            BaselineIP      BaseState BaseTTFB ChosenIP        ChosenTTFB BestTTFB ImprovePct Reason           Action
------            ----------      --------- -------- --------        ---------- -------- ---------- ------           ------
pt.example.com    104.17.143.151  ok            1.01 162.159.160.5        0.62     0.62      39.30 confirmed       update
forum.example.org 104.17.131.149  ok            0.57 104.17.131.149       0.57     0.53       7.30 below-threshold keep
```

## 它怎么选 IP

1. CFST（或内置扫描）先按延迟/丢包筛掉大部分 IP。
2. 按落地机房分层抽样，避免候选全落在 HKG。
3. 独立吞吐初测 + 3 × 2MB 决赛，只认决赛成绩。
4. 每个域名以当前 hosts/DNS 为基线逐站 HEAD 验证；准备切换时基线与候选各复核一次。
5. 只有快 ≥15%（`-MinImprovementPct`）且 ≥30ms（`-MinImprovementMs`），或基线不可用/类别更差才切换。

为什么这么设计、1034 回退、IPv6 取舍等，见 [docs/how-it-works.md](docs/how-it-works.md)。

## 准备域名

`domains.txt` 每行一个域名，`#` 开头为注释；已加入 `.gitignore`，站点清单不会进入版本库。
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

## 大概要跑多久

典型家用宽带（CFST + 十几个域名）约 **8–15 分钟**：

| 阶段 | 典型耗时 | 说明 |
| --- | --- | --- |
| CFST 延迟/丢包扫描 | 1–3 分钟 | `-NoCfst` 内置扫描通常更快但覆盖小 |
| 探测候选落地区域（256 个） | 2–6 分钟 | 每个候选最多 6 秒、16 并发；每 32 个打印进度 |
| 吞吐初测 + 决赛 | 1–3 分钟 | 约 70MB 下载，取决于带宽 |
| 逐域名验证与复核 | 1–3 分钟 | 每站约 6–10 次 HEAD，间隔 400ms |

想缩短时间：

```powershell
.\pt-cf-optimize.ps1 -ThroughputCandidates 16 -MaxDomainProbes 4
.\pt-cf-optimize.ps1 -NoCfst -MaxCandidates 128
```

## 安全边界（PT 站必看）

- 不登录、不带 Cookie、不访问 announce URL、不读取 passkey；对目标站只做少量 HEAD
  （每域名典型 6–10 次、最坏 11 次；准备切换时同一 IP 最多 2 次）。
- **不改变出口 IP**：前提是这些域名在代理旁路里。脚本会检查 WinINET 旁路和 TUN，
  但无法完整识别 PAC/WPAD、WinHTTP、应用级代理和 WFP 透明转发。
- 即使 Clash 开着也没关系：所有 curl 都带 `--noproxy '*'`，CFST 启动前清空代理环境变量；
  探测和测速强制直连。
- 不使用 VPN、机场、在线优选网站或公共反向代理访问 PT。
- hosts 只影响这些域名的网页/tracker；**P2P 和 IPv6 对等连接不受影响**。

具体规则以各站为准；更多问答见 [docs/faq.md](docs/faq.md)。

## CFST vs 内置扫描

| | CFST（`cfst\cfst.exe`） | 内置扫描（`-NoCfst` / 未找到） |
| --- | --- | --- |
| 候选覆盖 | `ip.txt` 当前 25 个网段，更广 | 随机抽 `-MaxCandidates` 个（默认 192） |
| 延迟测量 | TCPing（TCP RTT） | HTTPS `cdn-cgi/trace`（含 TLS） |
| 依赖 | 第三方 GPL-3.0 二进制 | 仅 PowerShell + 系统 `curl.exe` |
| 速度 | 快 | 几十秒到一两分钟 |

两者共用后续的机房分层、吞吐决赛和逐域名选择；CFST 只用于延迟/丢包，**不做下载测速**。
覆盖、参数和已知坑见 [docs/how-it-works.md](docs/how-it-works.md#cfst-与内置扫描)。

## 常用参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-DryRun` | | 只扫描和验证，不修改 hosts |
| `-Rollback` | | 用最近一次备份恢复 hosts（不依赖 domains.txt） |
| `-Prune` | | 删除不再出现在域名列表中的历史托管映射 |
| `-CheckResolved` | | 写入后解析每个域名，报告系统实际返回的地址 |
| `-NoCfst` | | 强制内置扫描 |
| `-TopN` | 1 | 每个域名最多写入的 IP 数 |
| `-MinImprovementPct` | 15 | 相对基线至少改善多少百分比才切换 |
| `-MinImprovementMs` | 30 | 切换所需的最小绝对改善（毫秒） |
| `-MaxDomainProbes` | 6 | 每域名候选探测硬上限 |
| `-CfstPath` | 自动查找 | cfst.exe 路径，可传目录 |

完整参数（含测速、超时、沙箱选项）见 [docs/parameters.md](docs/parameters.md)。

## hosts 安全

- 只接受“没有标记”或“恰好一对 BEGIN/END”；缺失、重复、嵌套、孤立 END 直接中止。
- 编码只支持 ASCII / UTF-8；多别名行、IPv6 映射、其他工具的托管区块 → 中止并报告行号。
- 验证失败默认保留旧映射；明确 1034/1003 才自动丢弃；不在本次列表默认保留，`-Prune` 才删除。
- 写入：互斥锁 + 提交前哈希检查 + 备份清单 + 原子替换 + 读回校验；`-Rollback` 可恢复。

完整规则和备份/回滚细节见 [docs/hosts-safety.md](docs/hosts-safety.md)。

## 常见问题

见 [docs/faq.md](docs/faq.md)。几个最常问的：

- 网页变快 ≠ 下载变快：hosts 不影响 P2P 传输。
- 写入 A 记录后，Windows 通常不再使用 DNS 的 AAAA；应用自带解析器可能不同。
- hosts 多行不保证优先级或故障转移，所以默认只写 1 个 IP。
- CF 路由会变，建议每 1–2 周或感觉变慢时重跑。

## 开发与测试

```powershell
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path .\tests -Output Detailed
```

全部离线测试（临时目录、合成备份，不访问网络、不碰真实 hosts）；CI 在 `windows-latest`
上运行语法检查、PSScriptAnalyzer 和 Pester。

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
samples candidates across edge colos, verifies every domain with HEAD requests (one extra
confirmation probe per IP when switching), and manages hosts entries in a tagged, idempotent,
reversible block. Domain lists can be imported from a PT-Depiler backup, the Windows proxy
bypass list, text, or the clipboard.

Requirements: Windows 10/11, PowerShell 7+, curl.exe. CFST is optional and not bundled.
