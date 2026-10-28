# FAQ

## 会不会导致 PT 站封号？

本工具不改变你的出口 IP：它只改"连到哪个 CF 边缘节点"，流量仍然从你的家宽直接出去，
登录 IP、tracker 上报 IP 都不变。

前提是这些域名在代理旁路里。脚本会检查 Windows 系统代理的 `ProxyOverride`，
缺失时会报红；也会检测 TUN 网卡。请不要用 VPN、机场、在线优选网站或公共反向代理
访问 PT——那些才会让出口 IP 变化。

验证阶段每域名每 IP 只发 1 次 HEAD，不登录、不带 Cookie、不爬页面。
具体规则以各站为准。

## 需要关掉 Clash / 代理吗？

不需要。脚本里所有 curl 都带 `--noproxy '*'`，CFST 启动前也会清空
`HTTP_PROXY/HTTPS_PROXY` 环境变量，所以测速走的是直连。

唯一要避免的是 **TUN / 虚拟网卡模式**，它会接管全部流量，导致测速结果和出口 IP 都失真。
脚本会检测并警告。

## 为什么不用 DNS 替代 hosts？

有些 PT 站点的公共 DNS 被污染（返回 Facebook/Twitter 的 IP），改 DNS 记录没有意义；
hosts 是唯一可靠的方式。另外本工具不想改你的 DNS 服务器或路由器配置。

## 为什么只做 IPv4？我的 IPv6 呢？

在测试线路上，CF 的 IPv6 全部落到远端 LAX，3MB 下载只有约 83KB/s，明显不如 IPv4 候选。

hosts 写入 A 记录后，Windows 对这些域名不再使用 DNS 的 AAAA，浏览器会走 IPv4 优选。
**BitTorrent 的 IPv6 对等连接不受影响**，因为 hosts 只影响这几个域名的网页/tracker。

## 为什么下载速度没有变快？

hosts 只影响这些域名的网页和 tracker 通告。PT 的 P2P 传输是 BitTorrent 直连，
与 hosts 无关，取决于做种人数、你的 IPv6 连通性和运营商互联质量。
网页变快 ≠ 下载变快。

## 支持哪些站点？

任何**由 Cloudflare 代理**的域名都支持。检测方法：

```powershell
curl.exe -sI https://example.com | findstr /i "server:"
```

返回 `server: cloudflare` 即可。不是 CF 的站点会被逐站验证自动跳过。

## 多久重跑一次？

CF 的路由和运营商互联会变。建议每 1–2 周，或感觉变慢、出现大面积红种时重跑。
不需要手工改 hosts。

## 某个站验证失败怎么办？

脚本会保持该站原样（不写入 hosts），并在报告里列出。
常见原因：

- 站点不是 Cloudflare 托管；
- 站点当前维护或源站故障（TCP/TLS 能连上但 HTTP 无响应）；
- 站点对 HEAD 请求直接断开（少数 WAF）。

等站点恢复后重跑即可。不要手工把 CF IP 写进去。

## 测速地址 403 怎么办？

默认测速地址是 `https://speed.cloudflare.com/__down?bytes={bytes}`。
如果你所在网络访问不了，可以用 `-SpeedTestUrl` 换成自建地址，例如参考
[cmliu/CF-Workers-SpeedTestURL](https://github.com/cmliu/CF-Workers-SpeedTestURL)
搭一个 Cloudflare Workers 测速地址。

注意：自建地址也应当由 Cloudflare 托管，否则 `--resolve` 固定 IP 的语义不成立。

## 会消耗多少流量？

一次完整运行大致是：

- 延迟扫描：每个候选几十字节的 trace 请求（CFST 扫描数千个 IP 也很轻）。
- 吞吐初测：32 个 IP × 1MB ≈ 32MB（`-ThroughputCandidates` / `-ThroughputBytes` 可调）。
- 复核：前 6 名 × 3MB × 2 ≈ 36MB。
- 站点验证：每域名每 IP 1 次 HEAD，可忽略。

合计约 70MB 量级，可通过参数调小。

## 为什么需要管理员权限？

写入 `C:\Windows\System32\drivers\etc\hosts` 需要管理员。`-DryRun` 不需要。

## 怎么完全卸载？

```powershell
# 先回滚
pwsh -NoProfile -ExecutionPolicy Bypass -File .\pt-cf-optimize.ps1 -Rollback
```

然后删除整个目录即可。脚本不会安装服务、驱动或计划任务。

## 会覆盖 hosts 里的其他内容吗？

不会。只处理 `domains.txt` 里列出的域名和一对标记区块；其他行逐字节保留。
写入前自动备份，失败自动还原，也可以随时 `-Rollback`。

## 能在 Linux / 路由器 / macOS 上用吗？

目前不支持。脚本依赖 Windows 的代理注册表、`Get-NetAdapter` 和 `ipconfig`。
Linux/路由器场景可以参考
[XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) 官方的
`cfst_hosts.sh`，或社区里的 OpenWrt 方案。
