# Contributing

## 先看这几条

- **不要**在 issue、PR、测试或文档里放真实 PT 站点清单、passkey、Cookie、完整 URL。
  用 `example.com`、`192.0.2.0/24` 之类的占位符。
- 测试必须离线：不访问网络、不碰真实 hosts；用 `$TestDrive` / `-HostsPath` 临时文件。
- 提交信息不要加 `Co-Authored-By` / `Generated with Claude Code` 等归因行。
- 不要提交 `domains.txt`、`domains.imported.txt`、`cfst/`、`backup/`、`last-report.txt`、
  `plan.json`、`dist/`。

## 开发环境

- Windows 10/11
- PowerShell 7+
- `curl.exe`（系统自带）
- 可选：CloudflareSpeedTest 的 `cfst.exe`（不要提交）

```powershell
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path .\tests -Output Detailed
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error
```

改完优选/验证/hosts 逻辑后，用一个临时 hosts 跑小规模 DryRun：

```powershell
.\Cloudflare-Hosts-Optimizer.ps1 -DryRun -HostsPath .\tmp-hosts -Domains example.com `
  -NoCfst -MaxCandidates 16 -ThroughputCandidates 4 -RefineTop 2 -VerifyDelayMs 100
```

需要机器可读结果时用 `-Plan -PlanPath .\plan.json`，它同样不会修改 hosts。

## 行为变更

- 新增/修改行为要补 Pester 测试；
- 同步更新 `docs/` 和 `CHANGELOG.md`；
- 用户可见行为变化要改 `$ScriptVersion`；
- 发布流程见 [docs/releasing.md](docs/releasing.md)。

## Pull Request

- 说明“改了什么、为什么、怎么验证”；
- 贴测试/分析器输出；
- 确认没有真实域名/凭据；
- 保持改动聚焦，不要顺手重构无关代码。
