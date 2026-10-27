# ADR 002：增量MVP与新依赖

日期：2026-10-23；状态：实施中。用户新指令取消逐Phase暂停，连续实施P0–P8；缺少外部凭据时继续自动化验证和其他工作。

不重建、不删除旧数据/测试。P1封装Flutter官方组件，统一蓝灰变量，只有Debug路由能进入Gallery。SQLite正文为权威源；跨模块调用公开服务。业务使用UUID、revision、deviceId、更新时间和删除标记；路径/凭据默认不同步。Windows事件与快捷键通过原生适配器，禁止拼接Shell。

已核验候选（版本最终以pub解析与锁文件为准）：

| 依赖 | 用途 | 官方维护/平台/许可证 |
| --- | --- | --- |
| file_picker13.1.0 | 系统选择/导出文件 | 37天内发布，三端，MIT |
| flutter_markdown_plus1.0.12 | Markdown预览 | 3个月内发布，三端，BSD-3-Clause；原flutter_markdown已停止维护 |
| dartssh2 4.1.0 | SSH协议 | 48天内发布，纯Dart三端；许可证解析后复核；必须提供onVerifyHostKey |
| crypto3.0.7 | SHA256去重/完整性 | Dart官方，多平台，BSD-3-Clause；流式哈希 |

来源：https://pub.dev/packages/file_picker 、https://pub.dev/packages/flutter_markdown_plus 、https://pub.dev/packages/dartssh2 、https://pub.dev/packages/crypto 。支持声明不等于真实设备验证。
