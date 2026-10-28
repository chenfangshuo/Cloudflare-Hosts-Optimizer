# Changelog

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
