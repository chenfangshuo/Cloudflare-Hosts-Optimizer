# 导入域名

`Import-Domains.ps1` 只负责把主机名写进文件：不访问网络、不登录、不带 Cookie，
也不读取 passkey。

## 输出与合并

默认输出 `domains.imported.txt`，**不会覆盖 `domains.txt`**。先打开检查，再合并：

```powershell
# 先备份、幂等、不会重复
.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip' -Merge
```

也可以手工把需要的行复制进 `domains.txt`。

## 从 PT-Depiler 备份（推荐）

1. 在 PT-Depiler 里导出备份（建议**关闭备份加密**，导入器不处理密码）。
2. 运行：

```powershell
.\Import-Domains.ps1 -Source Depiler -Path 'C:\path\to\PTD_backup.zip'
```

默认读取备份 ZIP 里的 `metadata.json`，取每个站点的 `url` 主机名；离线站点默认跳过。

```powershell
# 同时导入 siteHostMap 里的备用/CDN 主机名
.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip' -IncludeAlternates

# 包含离线站点
.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip' -IncludeOffline
```

**隐私边界**：只打开 `metadata.json`，绝不读取 `cookies.json`、`userInfo.json`、
`downloadHistory.json`；控制台只打印数量，不打印域名、passkey 或完整 URL。
为避免异常备份，导入器会拒绝重复的 `metadata.json` 和超过 8MB 的解压内容。

## 从 Windows 代理旁路列表

如果已经把所有 PT 域名加进了代理旁路，这一步零文件、零网络：

```powershell
.\Import-Domains.ps1 -Source ProxyBypass
```

列表可能包含非 PT 域名（例如 test-ipv6、Steam），请人工筛选。

## 从文本或剪贴板

```powershell
.\Import-Domains.ps1 -Source Text -Path .\sites.txt
.\Import-Domains.ps1 -Source Clipboard
```

会提取文本里的 URL 和裸主机名；URL 路径不会被误当成域名。

## 检查重点

- 只保留确认由 Cloudflare 代理的站点；
- 代理旁路列表可能混有非 PT 域名；
- 不确定的域名先跑 `-DryRun`，看它是否被逐站验证跳过；
- 不要把整份备份或整个旁路列表直接 `-Merge` 进去。
