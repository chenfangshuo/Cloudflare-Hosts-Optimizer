# Changelog

## 0.3.0 - 2026-10-29

逐域名选择 + 基线对比。

### Added

- 全局决赛只取前 K 个候选（`-CandidatesPerDomain`，默认 3），每个域名独立测试。
- 基线对比：以当前 hosts/DNS 路径为基线；只有候选快 ≥ `-MinImprovementPct`
  （默认 15%），或基线失败/类别更差时才切换；否则保留基线。
- 决策表：基线 IP/TTFB、选中 IP/TTFB、改善百分比、原因、Action（update/keep/dns/drop）。
- 旧映射优先于 DNS 回退；受限时 DNS A 记录最多测 2 条。
- `Select-DomainIp` 纯函数与 7 项单元测试（共 60 项）。

### Changed

- `-TopN` 现在表示切换后每个域名最多写入的 IP 数；未切换时保留基线。
- 逐域名请求预算：典型约 5 次、最坏约 8 次 HEAD/域名（仍不登录、不带 Cookie）。

## 0.2.1 - 2026-10-29

修复 Cloudflare Error 1034（Edge IP Restricted）导致的整站不可用。

### Fixed

- 403/503 不再一律当作 WAF：会取一小段响应体，识别 `error code: 1034` / `1003`
  （Edge IP Restricted / Direct IP access not allowed），判定为 `restricted` 并拒绝写入。
- 受限时回退到该域名自己的 DNS A 记录（最多 2 条，6 秒超时）；仍不可用才跳过。
- 旧映射校验：上一次写坏的 IP（1034 或连接失败）会被丢弃，不会因为"验证失败保留旧映射"
  而继续保留。可用的旧映射优先于 DNS 回退。
- 收紧超时：吞吐初测 20 秒、决赛 15 秒、域名验证 8 秒、DNS 回退 6 秒；
  避免慢速/无响应 IP 把一次运行拖到十几分钟。
- 新增 `Get-CfErrorClass` 测试与 `InvalidPreviousDomains` 测试；共 53 项。

## 0.2.0 - 2026-10-29

安全修复（P0）与域名导入。

### Fixed

- hosts 标记缺失 END、重复、嵌套、孤立 END 时直接拒绝，不再丢弃文件后半部分。
- 多别名行、已有 IPv6 映射、其他工具的托管区块（如 S302）→ 中止并报告行号。
- 编码只接受 ASCII / UTF-8（含 BOM）；UTF-16、GBK/ANSI 直接拒绝，避免损坏原文件。
- 增量更新：验证失败的域名保留上一次映射；`-Prune` 才删除；全部失败且无历史映射时不写。
- 吞吐样本必须满足退出码 0、HTTP 200/206、≥95% 字节数、remote_ip 匹配、无重定向。
- 决赛只使用决赛成绩（3×2MB 串行，有效样本 ≥2，真中位数）；失败 IP 不再保留初测高分。
- 域名验证接受 2xx/3xx/401/403，拒绝其他 4xx/429/5xx；403 标记为 WAF/受限。
- `-Rollback` 不再依赖 domains.txt。
- 备份按文件名选最近（不再依赖 LastWriteTime）；文件名加 GUID；附 JSON 清单（pre/post 哈希）。
- 写入改为互斥锁 + 提交前哈希检查 + 临时文件 + 原子替换 + 读回校验。
- `-DryRun` 不再写 `last-report.txt` 或 CFST 的 `result.csv`；报告需显式 `-ReportPath`。
- curl 统一 `-q`、`--noproxy '*'`、`--max-redirs 0`、`--proto '=https'`；优先使用 System32 的 curl.exe。
- CFST 输出写到临时目录，数字用 InvariantCulture 解析，并校验 IP 属于允许网段。
- 默认只扫描 Cloudflare 官方 IPv4 段；`104.28.0.0/14` 改为 `-ExperimentalRanges`。
- 机房分层抽样先按 TTFB 排序，组内也排序；预筛池从 64 扩到 256。
- TUN 检测结果生效；代理措辞改为"未发现已知信号"，不再断言已证明直连。
- 新增域名/测速地址校验；`ipconfig /flushdns` 检查退出码。
- 退出码：0 成功；2 无域名/参数错误；3 扫描失败；4 写入失败；5 回滚失败。

### Added

- `Import-Domains.ps1`：从 PT-Depiler 备份（`metadata.json` 的 `sites`/`siteHostMap`）、
  Windows 代理旁路、文本、剪贴板导入域名；只输出主机名，不读 cookies/userInfo，不访问网络。
- `-HostsPath`、`-Prune`、`-CheckResolved`、`-Force`、`-ExperimentalRanges`、`-ReportPath`。
- 默认 `-TopN 1`；文档明确 hosts 不是故障转移配置。
- 离线测试扩展到 49 项，覆盖编码、标记、冲突、增量、吞吐、备份、回滚、导入、CIDR、分层抽样。

## 0.1.0 - 2026-10-28

首个版本。

- 使用 CloudflareSpeedTest 做全量延迟/丢包筛选（仅 `-dd`，不使用其下载测速）。
- 独立的吞吐测速：默认请求 `speed.cloudflare.com/__down`，支持 `-SpeedTestUrl` 自定义。
- 按落地机房分层抽样，避免纯延迟排序把候选全部选成 HKG。
- 逐域名 HEAD 验证，并按真实 TTFB 排序；验证失败的域名保持原样。
- 非破坏式 hosts 管理：标记区块、注释旧条目、幂等、备份、`-Rollback`。
- 代理旁路与 TUN 网卡检查，避免测速走代理。
- 无 CFST 时可回退到内置 PowerShell 扫描（`-NoCfst`）。
- Windows 10/11 + PowerShell 7 + curl.exe。

