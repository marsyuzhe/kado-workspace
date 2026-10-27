# ADR 004 · 像素工作室与执行器边界

2026-10-23。保留 Flutter/Riverpod/Schema3；Flame 1.38.2 稳定版按需渲染。新 Studio 实体 payloadVersion=1；不升级 SQL DDL、不触碰旧记录。帧循环不访问数据库或网络；任务服务独立管理生命周期和取消。

原生验收证明本地工具任务链；本机真实 SSE 覆盖 API 协议，不能据此宣称外部模型验证。现有 OpenAI/兼容 Provider 执行文字草稿；尚未接入原生 Anthropic/Google 协议。

按 OpenAI Docs 核对了 [官方 App Server 文档](https://learn.chatgpt.com/docs/app-server) 和 [非交互模式](https://learn.chatgpt.com/docs/non-interactive-mode)。未来有状态产品集成优先研究 App Server 的结构化事件/审批/中断；简单有界任务可研究 exec JSON 事件。此轮不调用 CLI、不读取登录凭据、不把 ChatGPT 订阅当 API 余额。真正接入前要验证进程退出/取消、隔离工作目录、权限与登录状态；未提供任意 shell 入口。
