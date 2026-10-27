# Validation — public preparation

Current source version: 2.4.0+24; release preparation completed locally on 2026-10-27.

|Check|Actual result|
|---|---|
|Public-copy analyze|No issues found.|
|Public-copy unit/Widget suite|240 passed, 9 conditional skips.|
|Large file targeted retest|3 passed, including real 241,890,690-byte log pagination/search/export/redaction.|
|Seven native documentation pages|1 native test passed, real 1600×900 captures, synthetic DB, one actual loopback request, zero external AI requests.|
|Registrant URI native regression|1 passed: website/core entry, real HTTP and native DROPFILES→file hash, disabled after exit.|
|Windows public Release|Built; complete portable start, app-local SQLite/CRT, graceful close, wrapper extraction, isolated install/uninstall passed.|
|Public build upgrades|Actual old 2.3/2.0 binaries→new public 2.4, DB bytes unchanged by installer, uninstall preserves DB/user file.|
|Android reproducibility|Public source arm64 Release built with a separate temporary QA certificate; not distributed. Final Universal/arm64 rebuilt from public source with unchanged existing maintainer certificate and signature/ABI checks.|
|Earlier 2.4 business/engines baseline|11 Windows business and 11 real FFmpeg/Whisper cases passed in the preserved baseline; this preparation did not change business Dart source. These are inherited evidence, not an invented new full engine run.|

First attempts are retained in local private QA logs: one comment lint; two default-timeout tests under load; a serial compound-log total timeout; stale generated Android integration-test registration. The final runner is serial, every assertion is retained, each log worker still has a 30-second bound, and only the multi-operation log test has a two-minute total test budget. Normal Release tooling refreshes native registrants before the privacy pass.

Static scans review real text, scripts, configs, compiled Windows files and decompressed APK libraries. Generated registrant absolute URIs were found and removed using a generated-cache package URI, with no SDK/business source patch. Test-only invalid PEM and redaction literals are reviewed fixtures, not usable private keys.

UNVERIFIED: Android emulator/device, iOS/Xcode/signing/device, physical Explorer drag/hotkey/DPI, user remote Docker, true cold-cache timing and 30-minute memory. No cloud deployment. Online GitHub presentation/download validation awaits the owner's manual upload. Detailed reports and checksums accompany the local release package.
