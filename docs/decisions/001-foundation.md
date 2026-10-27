# ADR 001：基础技术与阶段边界

日期：2026-10-22；状态：采用。

问题：统一 Windows/Android/iOS/iPadOS 客户端，同时本地独立运行，不提前建设云服务。

选择：Flutter stable + Dart；唯一应用状态管理 Riverpod；路由 go_router；Drift + SQLite；Dio；flutter_secure_storage；path_provider 和 path 用于应用数据路径。Drift 的生成器与 build_runner 只在开发时使用。同步记录预留 UUID 字段，业务记录创建逻辑在后续模块实现；本阶段不增加 UUID 直接依赖。暂不引入 freezed、微服务或其它状态库。

原因：遵循用户指定技术栈；前三端有维护者支持声明，版本由 pub 解析并锁定；生成器减少数据库映射错误。

替代：纯 SQL/手写映射增加维护成本；Web 原型不能验证原生 SQLite 和系统安全存储；云端优先违背离线要求。

影响：iOS 签名/构建必须在 macOS/Xcode 验证；Windows 必须有 Visual Studio C++ 工作负载；Android 必须匹配 Flutter/插件所需 SDK/NDK/Java。所有缺口明确记录，不声称跨端验证完成。

## 依赖检查来源

以下为官方包页/官方文档（2026-10-22 查询），版本兼容性最终还须 pub get / analyze / build 实证；许可证以实际下载的包 LICENSE 为准。

| 依赖 | 用途 | 官方声明平台 | 许可证 | 检查结论 / 风险 |
| --- | --- | --- | --- | --- |
| Flutter | UI/平台宿主 | Windows/Android/iOS | BSD-3-Clause | 官方 stable 3.47.7，SDK 下载以官方 SHA256 校验；Apple 需 macOS |
| flutter_riverpod | 状态/依赖注入 | 三端 | MIT | 包页 3.4.3，近期维护；避免混用其他状态方案 |
| go_router | 声明式路由 | 三端 | BSD-3-Clause | 包页 18.1.1，Flutter 官方维护；禁用路由须显式守卫 |
| drift / drift_dev | 数据访问/生成 | 三端 | MIT | 包页 2.35.2，近期维护；迁移必须测试 |
| sqlite3 | 原生 SQLite | 三端 | MIT | Drift 传递依赖，使用其随包 native assets，必须实际加载测试 |
| dio | HTTP 边界 | 三端 | MIT | 包页 5.11.1，近期维护；禁用原始请求日志，生产只允许 HTTPS |
| flutter_secure_storage | 凭据 | 三端 | BSD-3-Clause | 包页 11.2.0，近期维护；Android 密钥算法/备份配置与 Apple Keychain 必须单独验证 |
| path_provider / path | 应用私有目录/路径 | 三端 | BSD-3-Clause | path_provider 2.1.6，4 个月内维护；不扫描用户目录 |

来源：
- https://docs.flutter.dev/install/manual
- https://docs.flutter.dev/platform-integration/windows/setup
- https://docs.flutter.dev/deployment/ios
- https://pub.dev/packages/flutter_riverpod
- https://pub.dev/packages/go_router
- https://pub.dev/packages/drift
- https://pub.dev/packages/dio
- https://pub.dev/packages/flutter_secure_storage
- https://pub.dev/packages/path_provider

安全边界：支持列表不等于无漏洞保证；锁文件可复现，交付前记录 pub 解析提示/已知 advisory；今后升级先迁移与回归。许可证在锁定版本包缓存中复核。项目源码暂保留所有权，不擅自为用户选择公开开源授权。

