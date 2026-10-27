# Codex 官方集成验证（1.6.0）

核对日期2026-10-23，使用OpenAI Docs并实际读取[app-server](https://learn.chatgpt.com/docs/app-server)、[SDK](https://learn.chatgpt.com/docs/codex-sdk)、[非交互模式](https://learn.chatgpt.com/docs/non-interactive-mode)。

| 方案 | 用途与决策 |
| --- | --- |
| codex exec | 适合预设权限的一次性任务，后续可选批处理 |
| TypeScript SDK | Node服务端编排；当前Dart客户端暂不引入Node中间层 |
| app-server | 适合长期会话、双向事件与审批；选为接入方向 |

实际CLI为codex-cli 0.163.0-alpha.11.2，已通过官方generate-json-schema导出协议。ThreadStart使用read-only/untrusted，TurnStart的readOnly策略缺少当前文档的access/readableRoots。证据artifacts/v21-codex-schema及测试能力子集；不能盲目套用当前网页字段。

本次实现Byte本地诊断：用户选择可信原生exe并确认后，仅用参数数组查询版本与导出Schema；不拼接Shell，限制时间和输出，限定清理本次临时目录，只持有自己启动的Process。没有登录、读取登录文件或启动模型会话。

JSONL/RPC基础已实现分片UTF8、1MB行限制、初始化、请求关联、超时、进程流中断与脱敏。诊断模式拒绝全部服务端审批请求。受控消息流测试不是外部会话成功；原生验收仅证明元数据探测可运行。

内部TODO：原生app-server传输桥、CodexExecutor注册、工作区授权、会话继续、操作审批、差异产物和恢复。因此taskExecutionEnabled始终false，能力探测通过也不会自动启用任务。后续先验证强制读取范围和插件隔离，再做只读任务端到端；不能因旧CLI缺字段而开放全盘。真实账号与具体项目/任务授权未验证，记UNVERIFIED/BLOCKED_EXTERNAL。
