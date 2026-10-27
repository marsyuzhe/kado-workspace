# KADO Desk v2.4.0

面向日常开发工具、网站、笔记与自行配置AI工作流的模块化本地工作台。Created and maintained by Links Tam.

## 新增与改进

- 网站固定入口、两级折叠工作空间、宽度与状态保存、紧凑首页、统一密度。
- API Studio、JSON/YAML格式化与差异、正则、SHA256/512文件校验、代码片段、明确单目标网络诊断、分页日志。
- GitHub公开项目/Release记录、静态依赖检查、环境差异、表单式文件工作流；Docker只读视图复用SSH与主机指纹。
- 原六模块和Pixel Office保留；低频旧模块可在设置显示，隐藏不删除记录。
- MIT公开副本、中英文文档、真实合成数据截图、完整第三方声明，以及不含个人注册库绝对路径的发布构建。

## 测试与限制

公开副本analyze零问题；240项单元/Widget通过，9项条件跳过；七页原生截图与最终核心/HTTP/原生拖入检查通过。Windows安装/便携/卸载和隔离2.3、2.0升级通过。Android源码Release构建与最终维护者签名已核验。

Windows本地未签名。Android模拟器/设备、iOS/Xcode均UNVERIFIED，无IPA；物理热键/Explorer拖动/DPI、用户远端Docker、真正冷缓存与30分钟内存待补。外部AI、SSH、FFmpeg/Whisper/模型需自己配置；安装包不含可选引擎或模型。云同步未配置。

## 下载与首次使用

Windows选Setup安装或完整解压Portable ZIP，保留DLL/data；Android选arm64或三架构Universal，两者均为沿用维护者开发证书的Release构建。不同签名不能直接覆盖，卸载前先备份。GitHub自动提供的Source code ZIP不是安装包。

核对SHA256SUMS.txt。项目代码按LICENSE.txt采用MIT，第三方/字体/CC0素材另按THIRD_PARTY_NOTICES.zip所存条件。先使用本地工具，需要时再配置外部服务；执行文件变更前先审查预览。本轮工具没有自动创建或发布GitHub仓库/Release。
