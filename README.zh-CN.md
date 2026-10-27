<p align="center"><img src="docs/images/hero-banner.png" alt="KADO Desk — Your workspace, your way." width="100%"></p>

<p align="center"><strong>Your workspace, your way.</strong><br>为日常开发、AI 工具与科技工作流而打造的个人工作台。</p>

<p align="center"><a href="README.md">English</a> · <a href="#下载与安装">下载</a> · <a href="BUILDING.md">源码构建</a> · <a href="docs/V24_TOOLS_GUIDE.md">工具指南</a> · <a href="LICENSE">MIT 许可证</a></p>

KADO Desk 把网站导航、开发工具、文件、笔记、AI Provider 和像素办公室放进统一的个人工作空间。按需配置模块，本地记录保存在 SQLite；外部 AI 和 SSH 连接需要你主动配置。本地工作台无需云账号。

**2.4.0+24 · Flutter / Dart · Windows 已实测 · Android 已构建 · iOS 未验证**

> **普通用户请先看 Releases：** 在仓库右侧找到 **Releases**，下载 Windows 安装版、便携版或 Android APK。GitHub 自动提供的 **Source code** ZIP 是源码，不是已编译安装包。[安装帮助](docs/DOWNLOADS.md)。

![使用合成笔记的真实 Windows 工作台](docs/images/01_dashboard.png)

## 按你的方式组织工作

|区域|当前实际能力|
|---|---|
|工作空间|两级折叠导航、侧栏宽度/状态保存、紧凑密度、快捷启动和真实最近使用。|
|开发工具|带集合与环境的 API 请求、JSON/YAML 格式化和差异、有界正则执行、流式 SHA256/512、代码片段、网络诊断、分页日志。|
|AI 与 Agent|自行配置兼容 API Provider、流式聊天与用量记录；像素办公室连接本地任务、日志和需审核的产物。外部模型需要自己的 Provider。|
|文件与媒体|文件整理预览/撤销、批量改名、图片与文档工具；音视频转换和转写需要另行安装 FFmpeg、Whisper 与模型。|
|知识管理|Markdown 笔记、项目、附件、搜索与上下文导出。|
|网站导航|内置公共目录，以及自建分类、收藏、导入和导出；元数据请求受控，不宣称内置通用浏览器。|
|系统与网络|SSH 主机指纹固定、服务器/Docker 只读视图、明确单目标诊断、环境快照/差异与静态依赖检查。|

低频旧模块可在 **设置 → 模块管理** 显示。隐藏不删除记录。文件工作流只组合已支持的文件操作，不执行任意脚本。

## 看看实际界面

以下均为可验证开发版本的 Windows 原生 Flutter 截图，统一 1600×900，使用全新合成数据库。未使用私人笔记、API Key 或真实服务器账号；原始截图与采集说明随本地发布准备材料提供。

|网站导航|开发工具|
|---|---|
|![内置公共网站目录](docs/images/02_web_library.png)|![真实本机 HTTP 响应](docs/images/03_developer_tools.png)|
|AI 控制台：尚未配置 Provider|文件管理：尚未选择文件夹|
|![未配置 Provider 的 AI 控制台](docs/images/05_ai_desk.png)|![等待选择目录的文件整理页](docs/images/06_file_manager.png)|
|设置|像素办公室|
|![真实设置页面](docs/images/07_settings.png)|![真实 Flame 像素办公室](docs/images/04_pixel_office.png)|

## 像素办公室

![真实办公室和本地角色](docs/images/pixel-office-showcase.png)

六个原创像素角色在 Flame 场景中活动，连接本地任务、工具调用、日志和可审核产物。截图展示本地演示角色，**不代表多个外部 AI 模型正在自主工作**。外部 AI 任务需配置 Provider，并受已有工具和审核流程约束。源码包含原创图集、可编辑图层和生成脚本，保留原 CC0 声明。

## 下载与安装

前往本仓库 **Releases**。维护者将手动发布附件，只有完成发布后才会有可下载的 Release。

|文件|用途|
|---|---|
|`KADO-Desk-v2.4.0-Windows-Setup.exe`|Windows x64 按用户安装。|
|`KADO-Desk-v2.4.0-Windows-Portable.zip`|完整解压后运行 `links_toolbox.exe`，保留 DLL 和 `data/`。|
|`KADO-Desk-v2.4.0-Android-arm64.apk`|多数 ARM64 Android 设备；Release 签名，尚待设备实测。|
|`KADO-Desk-v2.4.0-Android-Universal.apk`|同时包含 ARM32、ARM64、x86_64。|
|`SHA256SUMS.txt`|最终实际附件的校验值。|

Windows 本地未签名，可能触发 SmartScreen。应核对来源与校验值，不要全局关闭系统防护。Android 使用维护者开发签名证书；不同签名的安装包不能直接覆盖已有版本。卸载前先备份。当前不提供 IPA。

便携模式在程序旁 `user-data` 保存数据；安装版沿用原 Links Toolbox 内部存储身份。Schema 3 与包 ID 保持兼容。[备份与恢复](docs/BACKUP_RESTORE.md)。

## 为什么做 KADO？

项目来自个人日常需求：给常用链接、小型开发任务、文件和笔记一个集中的位置。已经有很多优秀开源工具。KADO 希望把适合自己工作方式的部分整合进可管理的本地环境，并清楚说明自动化和外部服务的边界。

## 技术与源码构建

界面采用 Flutter / Material 3，Riverpod 管理状态，go_router 处理路由；Drift/SQLite 保存本地记录，系统安全存储保存配置凭据，Flame 驱动像素场景。文件变更按能力进入预览、审核和任务队列；Windows 原生适配器提供支持的系统能力。[架构](ARCHITECTURE.md) · [完整构建说明](BUILDING.md)。

安装对应 SDK 后可从这里开始：

```powershell
cd apps/client
flutter pub get
flutter analyze
flutter run -d windows
```

完整测试需要先生成合成测试文件，步骤见 `BUILDING.md`。Android 签名材料和外置引擎需开发者自行提供；源码不包含维护者凭据或构建缓存。

## 平台状态

|平台|实际状态|
|---|---|
|Windows x64|Release 构建与原生业务测试通过；开发机完成安装/便携启动与保留数据升级测试。|
|Android|Release APK 构建与签名校验完成。模拟器/真机行为 **UNVERIFIED（未验证）**；不承诺桌面系统能力在 Android 等价可用。|
|iOS / iPadOS|有源码工程；macOS/Xcode 构建、签名和设备运行 **UNVERIFIED**，无 IPA。|
|Linux / macOS 桌面 / Web|不是本发布包的交付平台。|

系统物理输入热键、Explorer 鼠标拖动、真实显示器 DPI、用户远端 Docker、真正冷缓存启动与 30 分钟内存仍待独立验证。布局测试不等于设备认证。见[已知问题](KNOWN_ISSUES.md)与[测试说明](docs/TESTING.md)。

## 下一步

优先补设备测试、可访问性与使用反馈。云同步尚未配置。不宣称全自动 AI 公司或全平台能力一致。[路线图](ROADMAP.md)。

## 参与与安全

欢迎附复现步骤的问题反馈和经过测试的小范围改进。请勿公开提交真实密钥、个人数据库或私人日志。见[贡献说明](CONTRIBUTING.md)和[安全说明](SECURITY.md)。

## 许可证与作者

公开副本的项目代码及原创 KADO 品牌图形采用 **MIT**，© 2026 Links Tam，已由所有者明确选择。像素素材保留既有 CC0 声明；Noto Sans SC 采用 SIL OFL-1.1。依赖与外置引擎保留各自许可。详[第三方声明](THIRD_PARTY_NOTICES.md)。

**Created and maintained by Links Tam.**
