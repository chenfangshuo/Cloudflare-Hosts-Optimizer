# 发布

发布包只包含 git 已跟踪的文件，不会带 `domains.txt`、`cfst/`、`backup/`、`plan.json`
或 `dist/`。

发布由 tag 触发的 workflow（`.github/workflows/release.yml`）自动完成：推 `v*` tag
后，Actions 会检查 tag 是否在 `main` 上、版本号是否与 `$ScriptVersion` 一致，跑语法
检查和 Pester，然后打包并创建 GitHub Release。

## 步骤

1. 更新 `$ScriptVersion`、`CHANGELOG.md`、README/docs，跑测试，提交并推送 `main`。
2. 确认工作区干净、CI 通过：

```powershell
git status --short
gh run list --limit 3
```

3. 打 tag 并推送。配置了 SSH 签名（`tag.gpgsign=true`）时，`git tag -a` 会自动签名：

```powershell
git tag -a v0.3.7 -m "v0.3.7"
git push origin v0.3.7
```

本地验证签名（需要 `gpg.ssh.allowedSignersFile`）：

```powershell
git tag -v v0.3.7
```

4. 等 Release workflow 跑完（约 2–3 分钟）：

```powershell
gh run list --workflow release.yml --limit 3
```

5. 检查 Release 页面和附件：

```powershell
gh release view v0.3.7
```

发布说明取 `CHANGELOG.md` 中 `## 0.3.7` 这一节，并自动附加安装提示；找不到对应小节时
用 GitHub 自动生成的变更列表。

## 手动发布（workflow 失败时的回退）

```powershell
pwsh -NoProfile -File .\scripts\Package-Release.ps1 -Version 0.3.7

gh release create v0.3.7 `
  .\dist\pt-cf-optimize-0.3.7.zip `
  .\dist\pt-cf-optimize-0.3.7.zip.sha256 `
  --title "v0.3.7" `
  --notes-file .\release-notes-0.3.7.md
```

手动发布时说明文件放在仓库外（如 `release-notes-0.3.7.md`），不要提交进仓库。
发布后下载 zip 核对 SHA256：

```powershell
Get-FileHash .\pt-cf-optimize-0.3.7.zip -Algorithm SHA256
```

## 注意

- **不要**把 `dist/`、`plan.json`、`last-report.txt` 提交进仓库。
- 不要在发布说明里贴真实站点清单或 passkey。
- 发布包不包含 CFST 二进制（GPL-3.0，需用户自行下载）。
- tag 已经在 `main` 之外、或 tag 版本与 `$ScriptVersion` 不一致时，workflow 会直接失败，
  不会发出错误的包。
