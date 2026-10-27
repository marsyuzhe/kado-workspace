# Download and install / 下载与安装

Open the **Releases** section on the repository homepage. The owner must publish a Release before these files appear. No fictional account, download URL or domain is embedded here. Source code ZIPs are for developers, not installers.

## Windows

Choose **Setup.exe** for per-user installation or **Portable.zip** for a complete folder. For portable use, extract everything to a writable directory, keep DLLs/`data`, and run `links_toolbox.exe`; do not run a single EXE copied out of the ZIP. `portable.flag` selects local `user-data`. Installed mode preserves the prior Links Toolbox system-data identity. Back up before upgrading or bulk operations.

Windows files are unsigned. If SmartScreen warns, inspect the publisher/source and checksum; only proceed if you trust the release. Do not globally disable protection. Antivirus findings should be reviewed rather than bypassed automatically.

## Android

Use arm64 on ARM64 devices, Universal when the architecture is uncertain. These are maintainer-development-signed Release APKs, not Debug builds; no physical-device compatibility claim is made. Android may require you to allow installation from the browser/file manager you chose. Review that permission and turn it off afterward if desired. If the existing app has a different certificate, do not assume it can be overwritten; export/backup first and understand that uninstalling may remove data.

No iOS IPA is supplied. iOS/iPadOS need a separately validated, signed build.

## Checksums

Compare each downloaded file with the corresponding entry in `SHA256SUMS.txt` (case-insensitive hexadecimal). Windows can calculate a value using `Get-FileHash -Algorithm SHA256 <downloaded-file>`; this is an optional local integrity check, not a required upload step. A checksum verifies bytes, not publisher identity.

## 首次使用

先查看本地工作台与工具说明；不配置 API/SSH 也可使用本地能力。外部 AI 请求需自己的 Provider，服务器需核对主机指纹；媒体转换/转写需手动配置外置执行器。不要把私人数据或密钥用于公开问题截图。卸载前先备份，尤其是不同 Android 签名之间迁移。
