# Cloudflare-Hosts-Optimizer

优选 Cloudflare 边缘 IP 并安全写入 Windows hosts，让经 Cloudflare 代理的站点（PT 站、论坛等）网页打开更快。

> 不代理、不登录、不改出口 IP；严格校验 hosts，增量更新，一键回滚。

Windows 10/11 · PowerShell 7+ · 系统自带 `curl.exe` · CFST 可选

[English](README.en.md) · [下载发布包](https://github.com/chenfangshuo/Cloudflare-Hosts-Optimizer/releases)

**为什么会有这个脚本。** 我这边访问 PT 站经常十几秒才打开。用
[CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) 优选后手动写 hosts 确实能改善，
但 ping 最低的 IP 有时一访问就是 1034（这个 IP 不被该站接受，页面直接打不开），CFST 的默认测速
地址也已经不由作者维护。所以干脆把「测延迟 → 测吞吐 → 逐站验证 → 写 hosts → 可回滚」串成一次
运行。**我这边某个 PT 站首页从 >10s 降到 3s 左右；单站点实测 TTFB 1.75s → 0.69s。**

## 30 秒开始

不用敲命令，下载解压后双击就够：

<img src="docs/images/menu.png" width="860" alt="Cloudflare-Hosts-Optimizer 菜单：域名数量、上次运行与最近提交、1–10 编号项">

1. **下载并完整解压**，进入里面的 `Cloudflare-Hosts-Optimizer\` 目录，**双击 `Start.bat`**。
   它会自动找 PowerShell 7，没有会询问是否用 winget 安装。
2. **按 `1` 导入 / 编辑域名**（填法见下一节），保存关闭。
3. **（可选）按 `3` 下载 / 更新 CFST**：候选覆盖更广、通常效果更好；不装也能用内置扫描，只是会漏掉一些好 IP。
4. **（可选）按 `8` 只看结果**：不写 hosts，先看一遍切换和保留是否符合预期。
5. **按 `9` 正式写入**，会弹一次 UAC；不满意随时**选中第 10 项「回滚」**（方向键移过去，
   不是先按 `1` 再按 `0`）。

菜单按键：`↑`/`↓` 选择，`1`–`9` 直达前九项，第 10 项「回滚」用方向键移过去，`0` 退出 /
返回，`Enter` 确认，`Esc` 返回。首次运行约 **8–15 分钟**，过程会打印 `[n/6] 步骤名 · 预计时间`
和一行转轮（例如 `| 96/256 · 45s`），不是卡死。所有菜单项、提权行为和完整参数见
[使用与参数指南](docs/guide.md)。

第 3、4 步都是可选的。注意 **DryRun 也会真实请求一轮**：紧接着再正式写入，等于每个站点被
请求两次，详见下面的[注意事项](#注意事项)。

## 填域名与注意事项

`domains.txt` 一行一个域名，`#` 开头是注释。三种填法：

- 菜单 `1` → `5 手动编辑 domains.txt`，用记事本一行写一个；
- 菜单 `1` 里从 PT-Depiler 备份、Windows 代理旁路、文本或剪贴板导入，导完人工筛一遍；
- 命令行 `.\Import-Domains.ps1 -Source Depiler -Path '.\PTD_backup.zip' -Merge`，
  四种来源和合并规则见 [guide.md](docs/guide.md#域名导入与合并)。

填什么：**只填网页域名**，不要填 `tracker.example.com` 这类专门的汇报子域名；**只填确认由
Cloudflare 代理的站点**，填错了也不会写坏，只是白跑一次。拿不准就用下面这条看一眼：

```powershell
curl.exe -sI https://example.com | findstr /i "server:"
```

返回 `server: cloudflare` 是线索，不是绝对保证；不确定的域名先留在列表里跑 `-DryRun`。

### 注意事项

1. 第一次运行约 **8–15 分钟**；写入 hosts 需要管理员权限；**hosts 只影响本机**，不改变站点
   看到的来源，也不影响 P2P 和 IPv6 对等连接。
2. 每次运行只对每个站点发少量首页 **HEAD**（只取响应头，不下载页面），典型 6–10 次、最坏
   11 次，同一个边缘 IP 最多 2 次，间隔 400ms，不建议调高。脚本**不登录、不带 Cookie、
   不读 passkey、不访问 announce、不连 tracker 端口**，批量测速只打 `speed.cloudflare.com`；
   **只处理你写进 `domains.txt` 的域名，不会自动发现或爬取站点**。
   **DryRun 也会真实请求一轮**：紧接着再正式写入，等于每个站点被请求两次、风险翻倍。确认
   要写就直接按 9；想先看结果，就隔一段时间再单独跑一次 DryRun。
3. **不改变出口 IP**：只换连到哪个 CF 边缘节点，前提是这些域名在代理旁路里。脚本会检查
   WinINET 旁路和 TUN，但无法完整识别 PAC/WPAD、WinHTTP、应用级代理和 WFP 透明转发。
   不要用 VPN、机场、在线优选网站或公共反向代理访问 PT。
4. 默认只新增/更新列表里的域名，**不删除其他托管条目**；只有 `-Prune` 才清理不在列表里的旧映射。
5. 跑脚本时**不用关 Clash**（所有 curl 带 `--noproxy '*'`，CFST 启动前清空代理环境变量）；
   但**浏览时想走 hosts，需要关掉代理或把域名加进旁路**。检测到 TUN 时默认中止，确认风险后
   才加 `-Force`。
6. 优选出的 IP 会随时间变化，**建议 1–2 周重跑一次**，或按
   [定时任务](docs/guide.md#定时运行) 自动跑；hosts 只影响域名解析，暂不做 IPv6 优选。
7. 不建议把 `tracker.example.com` 这类汇报子域名写进列表：announce 是每 30 分钟几十字节的
   请求，优选没有收益；映射一旦过期或变成 1034，汇报失败反而会红种。同域名结构
   （`example.com/announce.php`）分不开，只能靠定期重跑和回滚兜底。
   [为什么](docs/faq.md#要不要把-tracker-域名加进-domainstxt)。

完整规则与请求预算见 [安全边界](docs/design.md#安全边界) 与 [请求预算](docs/design.md#请求预算)。

## 运行效果

我这边单站点实测 TTFB 1.75s → 0.69s（−60%）。下面是完整的一次运行（演示数据，域名已替换），
从环境检查、延迟筛选、机房抽样、吞吐决赛，到逐站验证、写入 hosts 和最终决策表：

<img src="docs/images/run.png" width="880" alt="完整运行过程：环境检查、延迟筛选、机房抽样、吞吐决赛、逐站验证、写入 hosts、结果与决策表">

为什么这么选、1034 怎么回退、hosts 怎么保证不被写坏，见
[工作原理与安全机制](docs/design.md)。

## 命令行与自动化

同样的功能，脚本化和排查时用命令行（简写，实际运行时用 `pwsh -File .\Cloudflare-Hosts-Optimizer.ps1 ...`）：

```powershell
.\Cloudflare-Hosts-Optimizer.ps1 -DryRun      # 只看结果，不写 hosts
.\Cloudflare-Hosts-Optimizer.ps1              # 正式写入（管理员）
.\Cloudflare-Hosts-Optimizer.ps1 -Rollback    # 回滚到最近一次备份
.\Cloudflare-Hosts-Optimizer.ps1 -Doctor      # 只读自检
```

给面板/脚本消费结果用 `-Plan -PlanPath .\plan.json`（不写 hosts）；定时运行用
`-InstallTask -TaskMode DryRun`（AutoApply 需管理员）。全部参数、定时任务和导入命令见
[使用与参数指南](docs/guide.md)。

## 文档与致谢

| 文档 | 什么时候看 |
| --- | --- |
| [docs/guide.md](docs/guide.md) | 菜单细节、域名导入、CFST 下载、定时任务、全部参数、数据位置 |
| [docs/design.md](docs/design.md) | 选 IP 的五个阶段、CFST 对比、1034 处理、hosts 原子更新与回滚规则 |
| [docs/faq.md](docs/faq.md) | 启动排障、封号边界、报错含义、卸载 |

开发：`Invoke-Pester -Path .\tests`（全部离线，不碰真实 hosts）。贡献见
[CONTRIBUTING.md](CONTRIBUTING.md)（含发布流程），安全问题用 [SECURITY.md](SECURITY.md)
里的私密渠道，不要开公开 issue。

致谢：[XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)（优选引擎，
GPL-3.0，不随本仓库分发）、[PT-Depiler](https://github.com/pt-plugins/PT-depiler)（备份字段
结构参考）、[cmliu/CF-Workers-SpeedTestURL](https://github.com/cmliu/CF-Workers-SpeedTestURL)
（自建测速地址）。

License：[MIT](LICENSE)。本仓库不包含 CloudflareSpeedTest 的代码或二进制。
