# 架构索引

历史基础架构保留于根目录 `ARCHITECTURE.md`。本目录从v0.2持续开发开始建立。

本轮沿用Riverpod、go_router、Drift/SQLite和系统安全存储。组件集中于 `core/ui`，业务按Repository → Service → UI → Platform Adapter分层。跨模块通过公开服务/导航参数交互，不直接操作其他模块内部表。

服务端仍可选且未连接。数据必须在本机真实持久化，凭据不进入普通记录、备份或同步载荷。版本迁移不删除旧库。
