## 改了什么

<!-- 简要说明行为变化和原因 -->

## 怎么验证

- [ ] `Invoke-Pester -Path .\tests` 全过
- [ ] `Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error` 无错误
- [ ] 用临时 `-HostsPath` 跑过 `-DryRun` 或 `-Plan`（没有碰真实 hosts）
- [ ] 没有真实站点域名、passkey、Cookie、完整 URL
- [ ] 行为变更已补测试；文档/CHANGELOG 已同步
- [ ] 提交不含 `Co-Authored-By` 等归因行
