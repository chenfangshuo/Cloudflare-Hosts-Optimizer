# 发布

发布包只包含 git 已跟踪的文件，不会带 `domains.txt`、`cfst/`、`backup/`、`plan.json`
或 `dist/`。

## 步骤

1. 更新 `$ScriptVersion`、`CHANGELOG.md`、README/docs，跑测试，提交。
2. 确认工作区干净：

```powershell
git status --short
```

3. 打包（zip + SHA256）：

```powershell
pwsh -NoProfile -File .\scripts\Package-Release.ps1 -Version 0.3.5
```

4. 打 tag 并推送：

```powershell
git tag -a v0.3.5 -m "v0.3.5"
git push origin v0.3.5
```

5. 创建 GitHub Release，附上 zip 和 `.sha256`：

```powershell
gh release create v0.3.5 `
  .\dist\pt-cf-optimize-0.3.5.zip `
  .\dist\pt-cf-optimize-0.3.5.zip.sha256 `
  --title "v0.3.5" `
  --notes-file .\docs\release-notes-0.3.5.md
```

6. 检查 Actions 和 Release 页面；下载 zip 核对 SHA256：

```powershell
Get-FileHash .\pt-cf-optimize-0.3.5.zip -Algorithm SHA256
```

## 注意

- **不要**把 `dist/`、`plan.json`、`last-report.txt` 提交进仓库。
- 不要在发布说明里贴真实站点清单或 passkey。
- 发布包不包含 CFST 二进制（GPL-3.0，需用户自行下载）。
