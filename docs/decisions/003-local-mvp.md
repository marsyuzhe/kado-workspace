# 003 · 本地MVP业务与交付

2026-10-23。沿用现有Flutter/SQLite工程和原21测试意图，不重建。所有新授权以MASTER_SPEC_V1为准，取消逐阶段暂停；不部署/上传/Push。

- Schema3增量扩展通用LocalRecords/RecentActions；UUID+CAS revision+墓碑。FTS5 trigram与短中文参数化子串共同实现可验证中文搜索。
- Material统一主题与可复用控件，组件Gallery仅Debug。静态模块注册和深链禁用保护保持。
- Windows使用真实WM_HOTKEY/WM_CLIPBOARDUPDATE、受限PNG读写、禁止覆盖MoveFileW和窗口关闭保存回调。移动平台用文档选择器导入副本，不伪装后台监听。
- Memory正文权威在SQLite；只查询摘要做列表，串行自动保存与导航/关闭前保护。
- 网络访问使用现有Dio及显式用户操作，AI不携带Key重定向，SSH始终提供主机验证回调。第三方模块库选择经平台/维护/许可检查；实测外部服务另列待验收。
- 使用flutter_markdown_plus 1.0.12（BSD-3-Clause）提供Markdown，默认禁用外部图片。dartssh2 4.1.0（MIT）提供SSH。archive 4.5.2（MIT）提供流式ZIP。cupertino_icons 2.0.0（MIT）补齐官方字体资源。
- 备份共享异步变更锁，VACUUM INTO+引用附件+SHA-256清单，后台压缩。重启恢复采用新数据代次指针，保留原库/附件，避免原地覆盖导致不可逆损失。
- Windows/Android平台构建必须串行：Flutter会重写跨平台插件注册文件，并行集成测试与Release曾造成integration_test插件注册冲突，已定位并采用串行重建。
- Android使用独立本机开发签名，不使用默认Debug Key冒充Release。签名材料在工程外，密码由Windows DPAPI保护，源码与交付包均排除。Windows安装器使用现有IExpress与每用户脚本，不修改管理员设置。

协议依据：
- https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events
- https://developers.openai.com/api/reference/resources/models/methods/list
- https://pub.dev/packages/flutter_markdown_plus
- https://pub.dev/packages/dartssh2
- https://pub.dev/packages/archive
- https://pub.dev/packages/cupertino_icons
- https://developer.android.com/develop/connectivity/network-ops/connecting

OpenAI Docs技能用于查询官方协议，未申请/使用用户API Key。真实外部联网、Android设备和Apple构建的缺口不会用Mock结果冒充。

补充构建根因：本机Flutter源码flutter_command.dart的regeneratePlatformSpecificToolingIfApplicable在shouldRunPub=false时直接返回；--no-pub会保留此前包含dev插件的Android Java注册文件，而Gradle Release会过滤dev插件。Release脚本已移除--no-pub，由Flutter按releaseMode重新生成，避免手改生成文件。串行仍用于避免共享生成文件被其他构建覆盖。
