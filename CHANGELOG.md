# Changelog

## 0.5.0 - 2026-10-31

### Added

- 双击启动：`Start.bat` 自动查找 PowerShell 7（PATH / WindowsApps / Program Files），
  缺失时可用 winget 安装；随后进入 `Menu.ps1`，可运行 Doctor、导入或手动编辑域名、
  查看域名、DryRun、正式写入、回滚、下载 CFST、定时任务、查看报告。
- `Install-Cfst.ps1`：从官方 GitHub Release 下载 `cfst.exe` + `ip.txt` 到 `cfst\`。
  支持直连、WinINET 系统代理、本地 zip；逐项校验 zip 结构与内容；CFST 本体仍不打包
  （GPL-3.0，仅运行时由用户下载）。
- 菜单「查看域名」：同时显示 `domains.txt` 和 hosts 托管区块，以及只在一边的差集。
- 菜单「手动编辑 domains.txt」：记事本编辑后自动校验条数和非法行。
- CFST 版本的解析抽成 `lib\Probe.ps1` 的 `ConvertFrom-CfstHelpText` / `Get-CfstVersion`，
  Doctor 复用。

### Changed

- 发布包新增 `Start.bat`、`Menu.ps1`、`Install-Cfst.ps1`、`lib\Menu.ps1`、
  `lib\CfstInstaller.ps1`；`.gitattributes` 固定 `.bat` 为 CRLF。
- 发布说明从 “No installer” 改为“解压后双击 `Start.bat`，或继续用命令行”。

## 0.4.1 - 2026-10-31

### Changed

- 发布包里已经建好 `cfst\` 目录，并附一份 `PUT-CFST-HERE.txt` 说明要放 `cfst.exe` 和
  `ip.txt`。仍然不包含 CFST 本体（GPL-3.0）。
- `.gitignore` 的 `cfst/` 改为 `cfst/*` 加白名单，只有说明文件入库，二进制照旧忽略。
- 去除 `Write-Progress` 进度条（旧控制台会在右侧留下括号/方块残影），改为步骤化输出：
  每个大步骤一行 `[n/6] 步骤名 · 预计时间`（青色），结束打印实际用时；底部一行转轮动画
  （`| / - \`），只显示进度数字，步骤名不再重复。整行擦除优先用 ANSI `ESC[2K`，
  不受中文字宽影响。输出被重定向（计划任务、管道）时自动禁用动画，探测进度仍按批写进报告。
- 步骤内部文字改成灰/白，青色只留给步骤标题；代理/旁路/网卡改成「标题 + 说明」两行结构，
  去掉了「说明：」前缀；所有说明、列表、结果行都左对齐（不再缩进），表格标题与表格之间
  不再空行，「完成」行也去掉缩进。
- 测速端点预检失败时重试一次，避免一次瞬时超时让整轮提前中止。
- 开头一行改为 `Cloudflare-Hosts-Optimizer <版本> · <模式> · N 个域名`，贴日志时能直接看出
  跑的是哪一版、DryRun 还是写入；结束前多一行结果汇总
  （`结果：更新 3 · 保留 12 · 沿用 DNS 2 · 用时 3 分 20 秒`）。
- 决策表与逐站结果行的原因/动作改成中文（`未达阈值`、`复核确认`、`保留（未验证）` 等），
  `plan.json` 里仍保留原始代码。
- CFST 这种没有细粒度进度的阶段，转轮显示已用时间（`| 1:32`）；吞吐两行分别加
  「初测：」「决赛：」前缀。
- 修复动画与 CFST/吞吐状态行重叠：`lib/Probe.ps1` 里直接 `Write-Host` 的几行改为先擦掉
  动画行再输出。

## 0.4.0 - 2026-10-31

### Added

- `-Doctor`：只读自检。检查 PowerShell/curl、当前是否管理员、hosts 结构与编码、域名文件、
  CFST 与 `ip.txt` 的覆盖差异、探测/测速端点、代理与 TUN、备份目录、机房缓存和已注册的
  计划任务；有失败项时退出码为 1。不写 hosts、不需要管理员，只打 Cloudflare 公共端点。
- `-InstallTask` / `-UninstallTask`：一条命令注册/删除计划任务。默认
  `-TaskMode DryRun`（只生成报告、不需要管理员）；`-TaskMode AutoApply` 自动写入 hosts，
  注册和使用都需要管理员。任务显式允许电池运行、错过补跑，超时 2 小时。
- `-ProbeUrl`：延迟扫描和机房探测使用的 `cdn-cgi/trace` 地址可替换
  （默认仍是 `speed.cloudflare.com`）。只接受 https 域名、443 端口。
- 启动预检：先确认探测端点和测速端点可用，失败时立即中止并给出提示，不再扫描几分钟后
  才报「没有候选通过吞吐初测」。

### Changed

- 默认探测端点不可用时自动回退到 `https://cloudflare.com/cdn-cgi/trace` 并告警；
  显式指定 `-ProbeUrl` 时不回退，避免静默换掉用户的选择。
- 新增参数都有默认值，现有命令的行为不变。

### Fixed

- `-Doctor` 会把 CFST 的 `ip.txt` 与内置网段做 /24 覆盖比较，指出
  `ip.txt` 不含 172.68–172.71（只有内置扫描覆盖）、并额外包含 104.28.0.0/14
  （需要 `-ExperimentalRanges`）。

## 0.3.10 - 2026-10-31

### Changed

- 代理/网卡提示更准确：`--noproxy` 和 CFST 清空环境变量只绕过 HTTP 代理，不再写成
  「强制直连」；TUN/WFP/PAC 无法这样绕过，说明后才中止。
- 旁路报警区分开：浏览器等 WinINET 程序可能走代理，与本工具的探测/测速无关；
  开着代理时这些程序可能不用 hosts 里的映射。
- 未检测到 TUN 时改为「只说明没有已知 TUN，不排除 WFP/透明代理」。

## 0.3.9 - 2026-10-31

### Changed (breaking)

- 项目更名为 **Cloudflare-Hosts-Optimizer**：仓库、主脚本（`Cloudflare-Hosts-Optimizer.ps1`）、
  发布包、文档和所有内部标识都改了名，不保留旧名称兼容。
- hosts 托管标记改为 `# >>> Cloudflare-Hosts-Optimizer BEGIN ... >>>` /
  `# <<< Cloudflare-Hosts-Optimizer END <<<`；旧条目前缀改为 `# [Cloudflare-Hosts-Optimizer] `。
- 全局互斥锁改为 `Global\Cloudflare-Hosts-Optimizer`；备份目录改为
  `%ProgramData%\Cloudflare-Hosts-Optimizer\backup`；机房缓存改为
  `%LOCALAPPDATA%\Cloudflare-Hosts-Optimizer\colo-cache.json`。
- **从 0.3.8 升级**：新版本不认识旧标记。把 hosts 托管区块的 BEGIN/END 两行里的
  `pt-cf-optimize` 改成 `Cloudflare-Hosts-Optimizer`（区块里的映射不动），或者删掉整个
  区块让新版本重建；之后只运行新版本。旧的备份目录和缓存目录可以删除。

### Fixed

- 发布 zip 现在带顶层 `Cloudflare-Hosts-Optimizer/` 目录，解压不再是一堆散文件；
  `Package-Release.ps1` 会在打包后校验 zip 结构。

### Changed

- 发布包不再包含 `.github/`、`tests/`、`scripts/`、`CONTRIBUTING.md`、`docs/releasing.md`
  （`.gitattributes` 的 `export-ignore`）；GitHub 自动生成的 Source code 包同样少这些文件。
- 安装提示写清解压后要进入内层文件夹再运行。

## 0.3.8 - 2026-10-29

### Fixed

- 机房缓存把只出现 1 次的稀有区域（例如 256 个候选里唯一的 FRA）也写进缓存，
  导致覆盖检查永远不满足、每次都退回全量探测，缓存实际上不生效。现在只缓存抽样中
  出现 ≥2 次的区域，最多 6 个。
- 实测：修复后第二次运行探测 96/256 即提前结束（165s，全量为 485s）。

## 0.3.7 - 2026-10-29

### Added

- 机房缓存（`-NoColoCache` / `-ColoCachePath` / `-ColoCacheMaxAgeDays`，默认 14 天）：
  缓存上次观察到的落地区域，探测覆盖后提前结束，重复运行从几分钟降到约 1 分钟；
  缓存过期、损坏或区域不再出现时自动退回全量探测。
- `-Rollback` 支持 `-RollbackFrom <hosts-*.bak>`：最近一次备份已经写坏时，可以退回到
  更早的备份；按 manifest 校验目标 hosts，缺少 manifest 或目标不符直接拒绝。
- tag 触发的发布 workflow（`.github/workflows/release.yml`）：推送 `v*` tag 后自动
  校验版本、跑测试、打包并创建 Release（zip + SHA256）；发布说明取 CHANGELOG 对应小节。

### Changed

- `docs/releasing.md` 更新为自动化流程，保留手动发布作为回退。
- `docs/parameters.md`、`docs/how-it-works.md` 补充新参数和缓存行为。

## 0.3.6 - 2026-10-29

### Changed

- 定时运行文档增加方案 C（自动写入 hosts）和风险说明，并补充“代码怎么运行”、
  `pwsh.exe` 路径排查；方案 A 不再只有代码片段。
- README 把自动化/定时运行入口移到快速开始末尾；FAQ 增加“1–2 周不重跑会不会更慢”。
- `actions/checkout` 升级到 v7.0.1（Dependabot PR #1）。

## 0.3.5 - 2026-10-29

### Added

- `-Plan` / `-PlanPath`：不修改 hosts，输出机器可读的 JSON 计划（决策、写入计划、告警），
  便于面板、脚本和定时任务消费。
- 发布工具：`scripts/Package-Release.ps1` 生成只含 git 跟踪文件的 zip + SHA256；
  发布流程见 `docs/releasing.md`。
- 英文 README（`README.en.md`）、`SECURITY.md`、`CONTRIBUTING.md`、
  issue/PR 模板、Dependabot。
- 定时运行示例 `docs/scheduling.md`（非管理员 DryRun + 人工确认）。
- 主流程纯函数 `Get-DomainAction`、`Resolve-ConfirmedDecision`、`New-PlanDocument`
  及 10 项测试（共 96 项）。

### Changed

- CI 的 `actions/checkout` 固定到 v5.1.0 的 commit SHA，并启用 Dependabot 每周检查。
- README 增加发布包下载、`-Plan` 和贡献/安全入口。

## 0.3.4 - 2026-10-29

### Changed

- 机房探测改为每 32 个分批回调：控制台显示“已探测 x/256”和进度条，
  不再出现几分钟没有任何输出、看起来像卡死的情况。
- 系统代理提示明确说明探测/测速强制直连（`--noproxy '*'`、CFST 清空代理环境变量），
  避免误解为走了 Clash。
- README 增加各阶段预计耗时、总时长和缩短时间的参数；FAQ 补充机房探测等待时间和
  代理提示的说明。
- README 重构为“快速上手”结构：运行效果示例、域名准备、检查并合并、安全边界、
  CFST 对比和常用参数放在前面；完整参数、导入细节、hosts 规则移入 `docs/`。

## 0.3.3 - 2026-10-29

按本地 review 修复边界问题，并让报告与文档和实际行为一致。

### Fixed

- `release` / 删除托管条目时，若 hosts 区块外仍有该域名的旧条目（被注释的原条目会恢复，
  用户手工行会保留），运行结束会告警；文档不再承诺一定“交还 DNS”。
- `Resolve-SwitchConfirmation` 接受 `baseline-failed`，避免边界情况下参数校验中止整次运行。
- `-DropUnreachable` 不再删除基线验证可用的映射；报告与日志显示实际保留的 IP。
- 报告新增 `BestTTFB`；复核中位数同时回写基线和候选，修复
  `BaseTTFB` / `ChosenTTFB` / `ImprovePct` 对不上的问题。
- 绝对毫秒门槛并入 `Select-DomainIp`，必然被 30ms 门槛拒绝的组合不再多花 2 次复核 HEAD。
- `-SpeedTestUrl` 在扫描前校验，参数写错不用等几分钟才失败。
- 缺少 `NetAdapter` 模块时跳过 TUN 检测，而不是抛 `CommandNotFoundException` 中止。
- ProxyOverride 匹配支持 `.example.com` 和 `example.com:443` 这类非标准写法。
- 决策表 TTFB 保留 3 位小数，避免 184ms 显示成 180ms（仅显示，判定仍用原始值）。

### Changed

- 切换前复核明确为每域名每 IP 最多 2 次 HEAD，规则与文档同步；请求预算最坏值修正为 11。
- `curl -w` 字段清单与解析器共用一份定义，避免两边索引漂移。
- 补上 `-NoCfst` 的帮助文本。

### Added

- `Find-Cfst`、`Test-BypassStrict` 迁入 `lib/Probe.ps1`，补目录解析、复核
  `baseline-failed`、健康基线保留、毫秒门槛和 release 告警的测试（共 86 项）。

## 0.3.2 - 2026-10-29

修复测量口径与切换前复核（外部 review 的 P1）；DNS 回退不再写死 IP。

### Fixed

- 所有 TTFB/连接时间扣除 `time_namelookup`：候选走 `--resolve`、基线走系统解析，
  统一口径后门槛不再被 DNS 时间吃掉。
- 切换前复核只比较"基线与选中的候选"：不再复核后在全部候选里重选
  （避免未复核的 IP 因噪声胜出）；候选复测失败/受限则不切换。
- 复核从"仅阈值附近"改为"准备切换就复核"（基线可用时）。
- 新增 `-MinImprovementMs`（默认 30）：百分比和绝对毫秒门槛都满足才切换；
  替换不再需要的 `-ConfirmThresholdPct`。
- 1034 回退胜出的是 DNS 记录时，动作改为**交还 DNS**（删除托管条目），
  不再把临时 IP 写进 hosts。
- `-CfstPath` 支持传目录（自动找 `cfst.exe`），不再"找到"目录后静默回退。
- 帮助文本修正旧映射语义，补全缺失的参数说明。

### Added

- `ConvertFrom-CurlWriteOut`、`Resolve-SwitchConfirmation` 纯函数与 10 项测试（共 77 项）。

## 0.3.1 - 2026-10-29

按外部 review 收敛可靠性：不再因一次失败删除旧映射，备份按目标隔离，
请求预算与文档一致。

### Fixed

- 旧映射只在明确 `1034/1003` 时自动丢弃；连接失败默认保留并告警；
  新增 `-DropUnreachable` 显式删除。
- 备份按 hosts 目标隔离（非系统 hosts 使用 `targets\<hash>` 子目录），
  回滚校验 manifest 的 `hostsPath`，避免沙箱备份恢复到系统 hosts。
- 403/503 诊断 GET 加 `--max-filesize 65536`，只读前 16KB；文档同步请求预算。
- DNS 回退显式 `-NoHostsFile`；只接受 IPv4 且在允许的 CF 网段内。
- `-RefineTop` 范围改为 1–16（0 不再静默禁用新候选）。
- `-Version` 提前到加载 lib 之前；显式 `-CfstPath` 不存在直接报错。
- 冲突 preflight 提前到扫描前；`Invoke-Main` 不再用返回值当退出码。
- 基线失败时不再跳过同 IP 候选；`-TopN` 额外 IP 需同类且 TTFB ≤ 主 IP 的 1.5 倍。
- 报告增加 `BaseState`；基线不可用时 `BaseTTFB` 留空，避免“变慢”误读。

### Added

- `-BackfillCandidates`（默认 1）、`-MaxDomainProbes`（默认 6）、
  `-VerifyTimeoutSec`（默认 5）、`-ConfirmThresholdPct`（默认 5）。
- 逐域名有限补位：前 K 个都不可用时补测。
- 改善接近 15% 阈值时，基线与最佳候选各复核一次。
- 导入器拒绝重复 `metadata.json` 和 >8MB 的解压内容。
- 测试扩展到 67 项。

## 0.3.0 - 2026-10-29

逐域名选择 + 基线对比。

### Added

- 全局决赛只取前 K 个候选（`-CandidatesPerDomain`，默认 3），每个域名独立测试。
- 基线对比：以当前 hosts/DNS 路径为基线；只有候选快 ≥ `-MinImprovementPct`
  （默认 15%），或基线失败/类别更差时才切换；否则保留基线。
- 决策表：基线 IP/TTFB、选中 IP/TTFB、改善百分比、原因、Action（update/keep/dns/drop）。
- 旧映射优先于 DNS 回退；受限时 DNS A 记录最多测 2 条。
- `Select-DomainIp` 纯函数与 7 项单元测试（共 60 项）。

### Changed

- `-TopN` 现在表示切换后每个域名最多写入的 IP 数；未切换时保留基线。
- 逐域名请求预算：典型约 5 次、最坏约 8 次 HEAD/域名（仍不登录、不带 Cookie）。

## 0.2.1 - 2026-10-29

修复 Cloudflare Error 1034（Edge IP Restricted）导致的整站不可用。

### Fixed

- 403/503 不再一律当作 WAF：会取一小段响应体，识别 `error code: 1034` / `1003`
  （Edge IP Restricted / Direct IP access not allowed），判定为 `restricted` 并拒绝写入。
- 受限时回退到该域名自己的 DNS A 记录（最多 2 条，6 秒超时）；仍不可用才跳过。
- 旧映射校验：上一次写坏的 IP（1034 或连接失败）会被丢弃，不会因为"验证失败保留旧映射"
  而继续保留。可用的旧映射优先于 DNS 回退。
- 收紧超时：吞吐初测 20 秒、决赛 15 秒、域名验证 8 秒、DNS 回退 6 秒；
  避免慢速/无响应 IP 把一次运行拖到十几分钟。
- 新增 `Get-CfErrorClass` 测试与 `InvalidPreviousDomains` 测试；共 53 项。

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

