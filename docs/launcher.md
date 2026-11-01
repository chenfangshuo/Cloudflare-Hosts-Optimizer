# 双击启动（Start.bat）

不需要记命令，也不需要先装 PowerShell 7。

## 启动

1. 下载发布包，解压到本地目录（不要在压缩包里直接运行）。
2. 双击 `Start.bat`。

菜单是上下箭头选择的 TUI：`↑`/`↓` 移动，`1`–`9` 直达对应项，`Enter` 确认，`Esc` 返回
（主菜单里是退出）。标题青色加粗，状态里的数字和「已安装」是绿色，`0 个`/未安装是黄色，
选中项用 `❯` 标出，底部提示是暗灰。菜单就地重绘；选定后先擦掉整块菜单再执行动作，
所以 Doctor、DryRun 的输出从干净的位置开始，不会被菜单内容覆盖。每次回到菜单会清屏、
连同回滚记录一起清掉，菜单上方不会堆积旧输出；需要回看时用「查看上次报告」
（菜单里的 DryRun 也会写报告）。

输出被重定向、管道里运行，或终端不支持 VT 时，会自动退回“输入编号”的模式。
也可以设置 `CFO_PLAIN_MENU=1` 强制使用编号模式。

第一次启动会显示类似：

```text
Cloudflare-Hosts-Optimizer 0.5.2
域名 12 个 · hosts 已写入 10 个 · CFST 已安装 · 上次运行 2026-11-01 09:10
当前是普通权限；写入 hosts / 回滚时会单独弹出 UAC。

  1) 导入 / 编辑域名
  2) 查看域名（列表与已写入）
  3) 下载 / 更新 CFST
  4) 定时任务
  5) 查看上次报告
  6) 打开 README
  7) 环境自检 (Doctor)
  8) 只看结果 (DryRun，不改 hosts)
  9) 正式写入 hosts
  10) 回滚到上次备份
  0) 退出
```

## PowerShell 7

`Start.bat` 会依次查找：

1. `PATH` 里的 `pwsh.exe`
2. `%ProgramFiles%\PowerShell\7\pwsh.exe`（winget/MSI 安装）
3. `%ProgramFiles%\PowerShell\7-preview\pwsh.exe`
4. `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`（MSIX 应用执行别名）

找不到时，如果系统有 winget，会询问是否安装 `Microsoft.PowerShell`，确认后执行：

```text
winget install --id Microsoft.PowerShell --source winget --exact ^
  --accept-package-agreements --accept-source-agreements --silent --disable-interactivity
```

装完会在同一个窗口重新检查上面四个位置（包括 Program Files），并实际运行一次
`pwsh -Version` 验证；仍失败时会给出 <https://aka.ms/powershell-release?tag=stable>，
手动安装后重新打开窗口再运行。

## 菜单项

| 项 | 作用 | 管理员 |
| --- | --- | --- |
| 1 导入/编辑域名 | 从 PT-Depiler 备份、代理旁路、文本、剪贴板导入；或用记事本直接编辑 `domains.txt` | 否 |
| 2 查看域名 | 显示 `domains.txt`、hosts 托管区块，以及只在一边的差集 | 否 |
| 3 下载/更新 CFST | 见下一节 | 否 |
| 4 定时任务 | 安装 DryRun / AutoApply 任务，或卸载 | AutoApply 需要 |
| 5 查看报告 | 显示 `last-report.txt` 的最后 80 行 | 否 |
| 6 README | 用记事本打开本仓库 README | 否 |
| 7 Doctor | 只读自检：环境、hosts、域名、CFST、端点、代理/TUN、备份、计划任务 | 否 |
| 8 DryRun | 完整跑一遍但不写 hosts | 否 |
| 9 正式写入 | 写入系统 hosts | 是（弹 UAC） |
| 10 回滚 | 用最近一次备份恢复 hosts | 是（弹 UAC） |

导入流程会先把提取结果写到 `domains.imported.txt` 并显示前 15 个，再问是否合并到
`domains.txt`；不会直接改主列表。

「手动编辑」用记事本打开主脚本读取的 `domains.txt`，保存关闭后自动检查条数和非法行；
有非法项会提示并问是否重新打开。

## 下载 CFST

CFST 是第三方 GPL-3.0 软件，本工具**不打包**它，只在你选择时下载。

| 方式 | 说明 |
| --- | --- |
| 直连 GitHub | 默认。会清空 `HTTP_PROXY`/`HTTPS_PROXY` 等环境变量并加 `--noproxy '*'`，确保是真直连 |
| 系统代理 | 读取 Windows「Internet 选项」里的 HTTP 代理（Clash 的“系统代理”模式） |
| 蓝奏云下载页 | 在浏览器打开作者提供的下载入口，手动下载 zip 后用下一项安装 |
| 从本地 zip 安装 | 只接受 zip，并做和自动下载相同的校验 |

蓝奏云地址：<https://xiu.lanzoub.com/b0742hkxe>（作者在其官方 README 中列出）。

下载后会校验 zip 结构（根级 `cfst.exe` + `ip.txt`）、大小、压缩比、`MZ` 头和 `ip.txt`
里的 CIDR；显示来源和 SHA256。上游没有发布校验值或签名，SHA256 只用于记录/比对。

## 提权（UAC）

菜单本身以普通权限运行。只有「正式写入」「回滚」「安装 AutoApply 任务」会调用
`Start-Process -Verb RunAs` 打开一个管理员窗口：

- 会先弹 UAC，取消则回到菜单，不会中断；
- 管理员窗口跑完后提示「执行完毕（退出码 N），按 Enter 关闭此窗口」，按回车窗口自动关闭、
  回到菜单；期间主窗口提示请在新窗口查看进度；
- 结果同时写进 `last-report.txt`，菜单里可以查看。

## 数据位置

| 内容 | 位置 |
| --- | --- |
| 域名列表 | `<工具目录>\domains.txt` |
| 导入中间产物 | `<工具目录>\domains.imported.txt` |
| 运行报告 | `<工具目录>\last-report.txt` |
| 备份 | `%ProgramData%\Cloudflare-Hosts-Optimizer\backup` |
| 机房缓存 | `%LOCALAPPDATA%\Cloudflare-Hosts-Optimizer\colo-cache.json` |
| CFST | `<工具目录>\cfst\cfst.exe` + `ip.txt` |

## 常见问题

- **双击后提示没找到 Menu.ps1**：你在压缩包预览里直接运行了；先完整解压，再运行解压后的
  `Start.bat`。
- **双击后窗口一闪而过**：说明启动失败。右键 `Start.bat` →「以 PowerShell 运行」看不到；
  可以在终端里执行 `cmd /k Start.bat` 保留输出。
- **winget 安装后仍提示找不到 pwsh**：`Start.bat` 会再检查 Program Files 和 WindowsApps；
  如果仍失败，关掉窗口重新打开一次再试。
- **直连下载失败**：菜单里改用“系统代理”，或打开蓝奏云下载页手动下载。
- **写入 hosts 没有反应**：检查 UAC 是否被取消；正式写入需要管理员。
- **不要用“以其他用户运行”**：配置目录不一定是同一个，建议用当前用户。
- **工具放在映射盘/网络路径**：提权后的进程可能看不到该路径，建议放到本地目录。
