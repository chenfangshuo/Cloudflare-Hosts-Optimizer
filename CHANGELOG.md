# Changelog

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

