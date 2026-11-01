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
- 同步更新 `docs/`（`guide.md` 管用法与参数、`design.md` 管机制与 hosts 规则、
  `faq.md` 管答疑）和 `CHANGELOG.md`；
- 用户可见行为变化要改 `$ScriptVersion`。

## 发布流程

发布包只包含 git 已跟踪的文件，不会带 `domains.txt`、`cfst/`、`backup/`、`plan.json`
或 `dist/`；`.gitattributes` 里标了 `export-ignore` 的开发文件（`.github/`、`.gitignore`、
`.gitattributes`、`tests/`、`scripts/`、`CONTRIBUTING.md`）也不会进包；
`docs/images/` 会保留在发布包里，README 的截图才能正常显示。

发布由 tag 触发的 workflow（`.github/workflows/release.yml`）自动完成：推 `v*` tag 后，
Actions 会检查 tag 是否在 `main` 上、版本号是否与 `$ScriptVersion` 一致，跑语法检查和
Pester，然后打包并创建 GitHub Release。

### 发布包结构

`scripts/Package-Release.ps1` 用 `git archive --prefix=Cloudflare-Hosts-Optimizer/` 打包，
解压后是一个顶层目录，不会把文件铺散：

```text
Cloudflare-Hosts-Optimizer-<X.Y.Z>.zip
└─ Cloudflare-Hosts-Optimizer\
     Cloudflare-Hosts-Optimizer.ps1
     Import-Domains.ps1
     cfst\
       PUT-CFST-HERE.txt
     lib\
     docs\
       guide.md
       design.md
       faq.md
     ...
```

`cfst\` 目录里只有一份给用户的说明，不放 CFST 本体；`.gitignore` 用 `cfst/*` 加白名单保证
二进制仍然不入库。`Package-Release.ps1` 会在打包后读一遍 zip 条目，确认所有条目都在这个
前缀下、必需文件齐全，否则直接失败而不是发出结构错误的包。

Windows 资源管理器的"全部解压缩"会先建一个以 zip 名命名的目录，再套这一层，README 里写了
要进内层运行。`export-ignore` 也会作用于 GitHub 自动生成的 Source code 包，所以从源码页
下载的 zip 里没有 `tests/` 和 workflow 文件，这是预期行为。

### 步骤

1. 更新 `$ScriptVersion`、`CHANGELOG.md`、README/docs，跑测试，提交并推送 `main`。
2. 确认工作区干净、CI 通过：

```powershell
git status --short
gh run list --limit 3
```

3. 打 tag 并推送。配置了 SSH 签名（`tag.gpgsign=true`）时，`git tag -a` 会自动签名：

```powershell
git tag -a v<X.Y.Z> -m "v<X.Y.Z>"
git push origin v<X.Y.Z>
```

本地验证签名（需要 `gpg.ssh.allowedSignersFile`）：

```powershell
git tag -v v<X.Y.Z>
```

4. 等 Release workflow 跑完（约 2–3 分钟）：

```powershell
gh run list --workflow release.yml --limit 3
```

5. 检查 Release 页面和附件：

```powershell
gh release view v<X.Y.Z>
```

发布说明取 `CHANGELOG.md` 中对应版本的小节，并自动附加安装提示；找不到对应小节时只用
`v<X.Y.Z>` 作为标题，不会自动生成变更列表（要变更列表请手动补 CHANGELOG）。

### 手动发布（workflow 失败时的回退）

```powershell
pwsh -NoProfile -File .\scripts\Package-Release.ps1 -Version <X.Y.Z>

gh release create v<X.Y.Z> `
  .\dist\Cloudflare-Hosts-Optimizer-<X.Y.Z>.zip `
  .\dist\Cloudflare-Hosts-Optimizer-<X.Y.Z>.zip.sha256 `
  --title "v<X.Y.Z>" `
  --notes-file .\release-notes-<X.Y.Z>.md
```

手动发布时说明文件放在仓库外（如 `release-notes-<X.Y.Z>.md`），不要提交进仓库。发布后下载
zip 核对 SHA256：

```powershell
Get-FileHash .\Cloudflare-Hosts-Optimizer-<X.Y.Z>.zip -Algorithm SHA256
```

### 注意

- **不要**把 `dist/`、`plan.json`、`last-report.txt` 提交进仓库。
- 不要在发布说明里贴真实站点清单或 passkey。
- 发布包不包含 CFST 二进制（GPL-3.0，需用户自行下载）。
- tag 已经在 `main` 之外、或 tag 版本与 `$ScriptVersion` 不一致时，workflow 会直接失败，
  不会发出错误的包。

## Pull Request

- 说明"改了什么、为什么、怎么验证"；
- 贴测试/分析器输出；
- 确认没有真实域名/凭据；
- 保持改动聚焦，不要顺手重构无关代码。
