# ADR 005 · 第一批工具的共享边界

2026-10-23。网页收藏沿用Hub favorite，附加body/标签而不迁移或复制旧收藏；浏览器HTML由html 0.15.7离线解析，实际包许可证已读。图片使用MIT许可image 4.12.0（无原生依赖），已核对官方包API与WebP编码参数；不打包FFmpeg或语音模型。

图片计算只向顶层Isolate入口传递字节与不可变选项；DB和文件句柄留在主服务。处理确认后，附件+记录写入沿用DataMutationGate；每个文件单独原子保存，取消前后均检查。attachment字段使新输出进入既有完整备份，已有恢复测试之外新增真实输出备份验证。

Archive 增强原RenameRule，不创建平行文件执行器；正则使用受限语法降低回溯风险，输出仍经过旧预览、路径、哈希和禁止覆盖边界。个人待办与Agent执行任务的kind和状态分离。

原数据事务门保持V1.0实现。新增手机/桌面UI测试分别运行于独立测试isolate，避免把一个测试的虚拟时钟完成信号留给下一测试；生产不使用虚拟时钟。所有旧测试继续执行，没有隐藏失败或关闭Drift诊断。

参考：[image官方包](https://pub.dev/packages/image/versions/4.12.0)、[html官方包](https://pub.dev/packages/html)。后续音视频转换应独立核实FFmpeg工具来源、许可证、取消和输出冲突；未接入前不宣称可用。
