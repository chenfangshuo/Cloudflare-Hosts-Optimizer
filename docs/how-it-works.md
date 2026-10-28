# 工作原理

## 目标

不是"找出延迟最低的 CF IP"，而是"找出对这些域名实际最快、且确实能用的边缘 IP"，
并且以可回滚、不破坏 hosts 其他内容的方式落地。

## 流程

1. **延迟/丢包筛选**
   - 有 `cfst.exe` 时：`cfst.exe -dd -tlr 0.05 -p 0 -o result.csv -f ip.txt`
   - 没有时：内置扫描，从官方 CF IPv4 段随机抽样 + 已知可用种子，用
     `https://speed.cloudflare.com/cdn-cgi/trace` 探测。
   - 只保留丢包率 ≤5%、有响应的 IP，按延迟升序。

2. **机房探测与分层抽样**
   - 取延迟最低的 64 个候选，逐个请求 `cdn-cgi/trace` 读取 `colo=`。
   - 按机房分组，轮流取样 32 个（`-ThroughputCandidates`）。
   - 目的：纯延迟排序会把 HKG 全排前面，而 HKG 在这类线路上大流量丢包严重。

3. **吞吐测速**
   - 对 32 个候选请求 `-SpeedTestUrl`（默认 `speed.cloudflare.com/__down?bytes=...`）。
   - 初测 1MB，前 6 名再用 3MB × 2 次复核，取中位数。
   - 完成字节数 < 500KB 的样本丢弃，避免把"卡死"误判为高速。

4. **逐域名验证**
   - 对每个域名、每个候选 IP 发 1 次 `HEAD`（`--resolve` 固定 IP，SNI 用域名）。
   - 任何 HTTP 状态码都算"可连通"（403/503 是 WAF/维护，不是封号）；
     只有连接失败/超时才记为失败。
   - 通过的 IP 按真实 TTFB 排序；两个 IP 都不通的域名不写入 hosts。

5. **写入 hosts**
   - 备份到 `backup/hosts-<时间戳>.bak`，只保留最近 5 份。
   - 删除旧的标记区块，注释管理域名的旧条目，写入新区块。
   - `ipconfig /flushdns`。
   - 任一步失败自动从备份还原。

## 关键设计决策

### 为什么 CFST 只做延迟，不做下载测速

CFST 的测速结果高度依赖 `-url` 指向的文件。官方默认地址 `https://cf.xiu2.xyz/url`
在实际测试中返回 **403**，CFST 会把 403 响应体当成"下载完成"，算出 15 MB/s 之类的假速度。
独立用 3MB 文件复测，真实吞吐只有 0.48 MB/s。

所以本工具只使用 CFST 的延迟/丢包能力（`-dd`），吞吐量自己测。默认测速地址是
Cloudflare 官方的 `speed.cloudflare.com/__down`，也可以用 `-SpeedTestUrl` 换成自建地址。

`-SpeedTestUrl` 支持 `{bytes}` 占位符；`--resolve` 会使用该 URL 的 host 和端口，
因此自建地址只要是 Cloudflare 托管即可。

### 为什么按机房分层

同一线路到不同 CF 机房的表现差异很大：

- HKG：TCP 握手约 130ms，但大流量丢包、TLS 偶发数秒、3MB 下载可能直接超时。
- LAX/SJC：握手 170–340ms，吞吐不一定最好，但通常更稳定。
- FRA/LHR 等：有时吞吐反而更高，但网页 TTFB 不一定更好。

只按延迟排序会系统性地高估 HKG。分层抽样保证每个主要机房都有候选，再由吞吐和
逐站 TTFB 决定。

### 为什么逐域名验证

同一个 CF 边缘 IP 能服务任何 CF 站点，但站点本身可能：

- 不是 Cloudflare 托管（写 hosts 会直接打不开）；
- DNS 被污染（必须靠 hosts，但错误的 IP 同样打不开）；
- 正在维护或 WAF 拦截（403/503 可连通，但不应误判为失败）；
- 对 HEAD 请求直接断开（少数站点）。

逐站验证是最后一道保险：验证不过就保持原样，不会把原本能用的站弄挂。

### 为什么写 A 记录会让浏览器走 IPv4

在 Windows 上，hosts 里存在的 A 记录会覆盖该名字的 DNS 查询结果，AAAA 不再从 DNS 返回。
因此浏览器会使用 hosts 里的 IPv4，而不会绕到 IPv6 的远端 CF 边缘。

这只影响这些域名的网页/tracker；BitTorrent 的 IPv6 对等连接不受影响。

### 为什么默认不做 IPv6 优选

在测试线路上，CF 的 IPv6 全部落到 LAX，3MB 下载 15 秒只收到 1.25MB（约 83KB/s），
明显差于 IPv4 候选。脚本目前只扫描 IPv4。

## hosts 写入算法

- 只用一对标记界定管理范围：
  ```
  # >>> pt-cf-optimize BEGIN (auto-generated; -Rollback to undo) >>>
  ...
  # <<< pt-cf-optimize END <<<
  ```
- 管理域名的旧条目改成 `# [pt-cf-optimize] <原内容>`，不删除。
- 重复运行只替换标记区块，结果幂等。
- 某域名本次未通过验证时，它的旧条目会恢复成未注释状态。
- 非管理行逐字节保留；按原文件编码（ASCII/UTF-8）和换行（CRLF/LF）读写。

## 局限

- 只支持 Windows（依赖 `HKCU` 代理设置、`Get-NetAdapter`、`ipconfig`）。
- 只做 IPv4。
- CF 路由和运营商互联会变化，结果有时效性，建议定期重跑。
- 吞吐测速有噪声；本工具用多次采样和中位数降低误判，但不能消除。
- 逐站验证只发 HEAD，不保证登录、发种、下载等功能一定正常。
- 自定义测速地址如果不是 Cloudflare 托管，`--resolve` 固定 IP 的语义不成立。
