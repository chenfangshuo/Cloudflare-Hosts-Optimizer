# Security Policy

## Supported versions

只支持最新版本。这是一个本地 Windows 工具，没有服务端组件，也不会收集遥测。

## 报告安全问题

请使用 GitHub 的私密漏洞报告：仓库 **Security** 标签页 → **Report a vulnerability**。
不要为安全问题开公开 issue。

报告里请不要包含：

- 真实 PT 站点清单或域名；
- passkey、Cookie、完整 announce URL；
- 你的完整 hosts 文件或可识别线路的 IP。

用 `example.com` 和保留 IP 段（如 `192.0.2.0/24`）说明即可。

## 范围

**在范围内**

- hosts 解析/写入/回滚绕过、原子写入失败、备份串台；
- 导入器的路径穿越、命令注入、异常 ZIP；
- 日志/报告泄漏域名、passkey、Cookie；
- 1034/1003 判断错误导致写入不可用映射。

**不在范围内**

- PT 站点规则、封号、tracker 策略；
- Cloudflare 路由变化或测速结果波动；
- 用户自己的代理/VPN/TUN 配置；
- 修改过 hosts、使用不支持的编码、或自行改过代码的情况。

## 安全使用建议

- 先跑 `-DryRun` 或 `-Plan`，确认结果再正式写入。
- `domains.txt` 已在 `.gitignore` 里，不要提交或贴到 issue。
- 只从本仓库的 GitHub Releases 下载发布包，并核对 SHA256。
