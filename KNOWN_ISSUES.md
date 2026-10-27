# Known issues — 2.4.0+24

- Windows installer/portable are locally unsigned; SmartScreen reputation is not established.
- Android APK builds and signing verification exist; Android emulator/physical device behavior remains **UNVERIFIED**. The included iOS project is not built/signed/device-tested here. No IPA or Linux/macOS desktop/Web release is claimed.
- Windows physical Explorer pointer-drag, OS hotkey input injection and real monitor DPI switching need separate tests. Native DROPFILES bridging and virtual layout/DPI checks are covered, but are different measurements.
- Remote Docker views reuse SSH, fingerprints and read-only commands. The new views have no user remote-server acceptance here.
- True cold-cache startup and 30-minute memory/FPS studies are unmeasured. Small three-sample Release measurements do not establish an overall speed improvement.
- API Studio cannot identify every secret in arbitrary text/custom field names. Use secure references; inspect exports before sharing. Request redirects are not followed automatically; response/input/resource limits are intentional.
- YAML normalization uses valid JSON flow syntax for YAML 1.2; comments/anchors are not preserved. Static dependency inspection does not execute package managers or claim vulnerability/latest-version knowledge.
- Log Viewer reads UTF8 text; invalid bytes are replaced, long lines are marked/truncated. Export is text, not a byte-identical binary copy.
- FFmpeg/Whisper/model-dependent features need external components. No optional model or engine is included in source/base Release assets.
- Cloud sync is not configured or deployed. Legacy low-frequency modules are hidden by default and can be shown in Settings; hiding does not delete records.

Report problems with synthetic data as described in [CONTRIBUTING.md](CONTRIBUTING.md).
