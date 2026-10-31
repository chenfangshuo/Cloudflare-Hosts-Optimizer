# 发布

发布包只包含 git 已跟踪的文件，不会带 `domains.txt`、`cfst/`、`backup/`、`plan.json`
或 `dist/`；`.gitattributes` 里标了 `export-ignore` 的开发文件（`.github/`、`tests/`、
`scripts/`、`CONTRIBUTING.md`、`docs/releasing.md`）也不会进包。

发布由 tag 触发的 workflow（`.github/workflows/release.yml`）自动完成：推 `v*` tag
后，Actions 会检查 tag 是否在 `main` 上、版本号是否与 `$ScriptVersion` 一致，跑语法
检查和 Pester，然后打包并创建 GitHub Release。

## 发布包结构

`Package-Release.ps1` 用 `git archive --prefix=Cloudflare-Hosts-Optimizer/` 打包，
解压后是一个顶层目录，不会把文件铺散：

```text
Cloudflare-Hosts-Optimizer-0.4.0.zip
└─ Cloudflare-Hosts-Optimizer\
     Cloudflare-Hosts-Optimizer.ps1
     Import-Domains.ps1
     cfst\
       PUT-CFST-HERE.txt
     lib\
     docs\
     ...
```

`cfst\` 目录里只有一份给用户的说明，不放 CFST 本体；`.gitignore` 用 `cfst/*` 加白名单
保证二进制仍然不入库。

`Package-Release.ps1` 会在打包后读一遍 zip 条目，确认所有条目都在这个前缀下、且主脚本
存在，本地和 CI 都会因此失败而不是发出结构错误的包。

Windows 资源管理器的「全部解压缩」会先建一个以 zip 名命名的目录，再套这一层，README
里已经写了要进内层运行。`export-ignore` 也会作用于 GitHub 自动生成的 Source code 包，
所以从源码页下载的 zip 里没有 `tests/` 和 workflow 文件，这是预期行为。

## 步骤

1. 更新 `$ScriptVersion`、`CHANGELOG.md`、README/docs，跑测试，提交并推送 `main`。
2. 确认工作区干净、CI 通过：

```powershell
git status --short
gh run list --limit 3
```

3. 打 tag 并推送。配置了 SSH 签名（`tag.gpgsign=true`）时，`git tag -a` 会自动签名：

```powershell
git tag -a v0.4.0 -m "v0.4.0"
git push origin v0.4.0
```

本地验证签名（需要 `gpg.ssh.allowedSignersFile`）：

```powershell
git tag -v v0.4.0
```

4. 等 Release workflow 跑完（约 2–3 分钟）：

```powershell
gh run list --workflow release.yml --limit 3
```

5. 检查 Release 页面和附件：

```powershell
gh release view v0.4.0
```

发布说明取 `CHANGELOG.md` 中 `## 0.4.0` 这一节，并自动附加安装提示；找不到对应小节时
用 GitHub 自动生成的变更列表。

## 手动发布（workflow 失败时的回退）

```powershell
pwsh -NoProfile -File .\scripts\Package-Release.ps1 -Version 0.4.0

gh release create v0.4.0 `
  .\dist\Cloudflare-Hosts-Optimizer-0.4.0.zip `
  .\dist\Cloudflare-Hosts-Optimizer-0.4.0.zip.sha256 `
  --title "v0.4.0" `
  --notes-file .\release-notes-0.4.0.md
```

手动发布时说明文件放在仓库外（如 `release-notes-0.4.0.md`），不要提交进仓库。
发布后下载 zip 核对 SHA256：

```powershell
Get-FileHash .\Cloudflare-Hosts-Optimizer-0.4.0.zip -Algorithm SHA256
```

## 注意

- **不要**把 `dist/`、`plan.json`、`last-report.txt` 提交进仓库。
- 不要在发布说明里贴真实站点清单或 passkey。
- 发布包不包含 CFST 二进制（GPL-3.0，需用户自行下载）。
- tag 已经在 `main` 之外、或 tag 版本与 `$ScriptVersion` 不一致时，workflow 会直接失败，
  不会发出错误的包。
