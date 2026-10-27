# 可选本地媒体执行器

基础安装包不包含 FFmpeg、whisper.cpp 或识别模型，不会在启动时自动下载或启动它们。Windows 运行器不能直接用于 Android/iOS。图片与基础文档转换无需这些运行器。

## FFmpeg

在格式转换的「音频与视频」页选择可信来源的 bin 目录，需要 ffmpeg.exe、ffprobe.exe 和同一构建的 DLL。界面先展示本地 SHA256 指纹，确认后才运行版本/编码器检测；每次媒体处理重新核对文件与 DLL 指纹。单纯的本地指纹不能证明发布者身份，请同时核对来源。

本轮实测：官方 [FFmpeg 下载页](https://ffmpeg.org/download.html)所列 [BtbN builds](https://github.com/BtbN/FFmpeg-Builds/releases) 的 n9.0 LGPL shared x64；实际版本 n9.0.2-35-g9a9b70bb8c-20261023。ZIP SHA256 3fa88605040303d0f2f556580a226db0d54bce9fb85b0dbbd561b983e820aafc，来自同次发布 checksums.sha256。配置 --enable-version3，禁用libx264/libx265；使用libopenh264、aac、libmp3lame、flac、pcm_s16le。许可应按实际构建判断；本项目不再分发此执行器。

脚本 scripts/prepare_utility_engines.py 用于开发机准备可选运行器，下载校验表再比对 SHA256；latest发布会变化，已存在文件若与新发布不一致会保留并报错，不自动替换。执行器在项目外 .toolchains/utility-runtimes，不进入源代码或安装包。

已测输出：WAV→MP3/FLAC/M4A/AAC/WAV；MP4→MKV复制轨道；MKV→MOV重新编码和尺寸缩放。其他兼容组合取决于探测出的轨道/容器/编码器，不承诺所有文件可转。播放列表/远端协议不作为输入。取消只终止本任务子进程，临时文件位于本任务工作目录，最终输出不覆盖已有文件。

## whisper.cpp（Batch B 准备）

已准备官方 [v1.8.7 x64 CPU release](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.8.7)，ZIP SHA256 d9627486e1c34a03745880485593473e047294260ce9a3cb0aa8deaf15b99af6，MIT。较新v1.9.4发布仅附源码，本轮先验证有官方二进制与发布方校验值的v1.8.7。

[模型列表](https://github.com/ggml-org/whisper.cpp/blob/v1.9.4/models/README.md)指向 ggerganov/whisper.cpp。tiny 多语言75MiB模型官方SHA1 bd577a113a864445d4c299885e0cb97d4ba92b5f；本地SHA256 be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21。模型预计约273MB内存，实际会受音频长度和参数影响。for-tests模型无权重，不能用来验证识别。

开发脚本 scripts/prepare_whisper_engine.py 流式下载并核验，保存在项目外；公开 jfk.wav 11秒英文样本已用真实 tiny 模型识别成功，实测文本与时间戳位于 artifacts/v22-regression/transcribe，耗时约0.7秒（此开发机、此短样本），不能推定长录音或中文准确率。当前尚未作为完整用户模块验收。

## LocalSend（独立可选应用）

`python scripts/prepare_localsend_engine.py`下载固定官方1.18.2 x64 ZIP并核对发布页SHA256，放在工程外.toolchains/utility-runtimes/localsend-v1.18.2-x64，不安装、不自动运行、不捆绑基本包。普通用户也可从https://localsend.org/download自行安装，并在互传页选择LocalSend GUI EXE。许可Apache-2.0及上游说明见UTILITIES_TECH_DECISIONS。工具箱核对产品名称、版本和离线签名，并记录EXE/AOT/DLL指纹；版本更新后需重新配置。旧指纹不自动信任新组件。

实际发现、配对/设备核对、接收确认、网络进度、取消和平台权限由独立LocalSend处理；双真机验收尚未完成。Toolbox基础包可完全不安装该应用，只使用发送清单与本地接收核验功能。
