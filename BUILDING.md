# Building KADO Desk

Version: 2.4.0+24. Tested SDK: **Flutter 3.47.7 / Dart 3.13.5**, on Windows x64. Keep `apps/client/pubspec.lock`; do not upgrade dependencies as part of reproducing this release. The repository contains `apps/client`, not a root Flutter application. No maintainer toolchain directories or local SDK configuration are included.

## Prerequisites

- Flutter SDK on PATH; its bundled Dart satisfies `sdk: ^3.13.5`.
- Windows: Visual Studio 2022 / Build Tools with **Desktop development with C++**, Windows SDK and CMake. Review `flutter doctor -v`. Flutter plugins require supported symlinks; enable Windows Developer Mode if needed. The release-preparation PC used local junctions instead, without changing system settings.
- Android: Android SDK platform 36, build tools 36.x, SDK command-line tools, NDK version requested by Flutter, and a compatible JDK (tested JDK 21; Java/Kotlin target 17). Gradle wrapper is pinned to 9.3.1 with distribution SHA. Let Flutter/Gradle report a missing component; do not copy another developer's `local.properties`.
- Tests: Python 3 (stdlib for fixtures), PowerShell 7 with .NET certificate/PemEncoding support for the synthetic localhost TLS fixture. About 350 MB temporary disk space is needed for generated hash/log inputs. Fixture files and keys are created locally and must not be uploaded.
- iOS: macOS/Xcode, Apple signing and target capability review required; **not validated in this environment**.

## Resolve, analyze and test

From repository root:

```powershell
cd apps/client
flutter pub get
flutter analyze --no-pub
cd ../..
./scripts/dev.ps1 test
```

`scripts/dev.ps1` uses Flutter from PATH or accepts `-FlutterSdk /path/to/flutter`. The test action generates deterministic 16 MiB hash inputs, a large synthetic log and a short-lived self-signed localhost TLS fixture; it never installs that certificate in a trust store. Do not run concurrent Flutter jobs against the same build/cache, especially on Windows with native SQLite.

The full regression reports 240 passes and 9 conditional skips in the 2.4 baseline. Media-engine and public-network tests are opt-in; missing prerequisites are reported as skips, not successful execution. Native screenshot test is separate:

The public test runner uses one test process at a time. The compound 241 MB log case has a two-minute total test budget for its several independent scans/exports; each worker still has the original 30-second operation limit and every result assertion is retained. This prevents a framework-wide 30-second default from incorrectly timing out the sum of multiple bounded operations on slower disks.

```powershell
cd apps/client
flutter test integration_test/public_showcase_capture_test.dart -d windows --no-pub
```

It creates an isolated DB and in-memory empty credentials, captures seven actual pages with synthetic content, and makes one real loopback HTTP request. It does not contact an AI provider. Use `KADO_SHOWCASE_OUTPUT` to choose a capture folder outside the repository's source files.

## Windows Release

```powershell
./scripts/dev.ps1 windows-release
```

Output is `apps/client/build/windows/x64/runner/Release`. The executable needs all generated DLLs and `data/`. Debug symbols are written separately under `artifacts/symbols/windows`. PE PDB metadata uses basenames to avoid publishing the builder's absolute directory. App IDs and internal storage identity remain Links Toolbox for compatibility.

The Release wrapper runs normal Flutter tooling first, then adds a generated-cache-only package URI for `dart_plugin_registrant.dart` and rebuilds with `--no-pub`. This removes the otherwise embedded absolute registrant URI without changing Flutter SDK or application business source. The alias is not a dependency and is never uploaded as package configuration. Android uses the same two-pass flow: normal Release tooling also refreshes Java plugin registration so an earlier integration test does not leave a dev-only plugin in a Release build. Generated registrants/local configs are regenerated, not shipped as private state. Public artifact scanning checks decompressed libraries too; separating debug symbols alone does not remove every embedded URI.

For distribution, `scripts/package_windows.py --vc-runtime <Microsoft.VC143.CRT-directory>` assembles the complete folder, required app-local VC runtime, project/third-party notices, portable ZIP and installer payload. Then `scripts/build-windows-installer.ps1` wraps that payload with Windows IExpress. See each script's arguments. A successful local build is not Authenticode signing; the prepared Windows installer remains unsigned.

Native SQLite hooks download a hash-verified library during a normal build. Network access may be necessary. Preparation tests reused an existing official-SHA-verified cache; this does not make the source an offline SDK distribution. Keep normal TLS verification enabled.

## Android

For a development build:

```powershell
./scripts/dev.ps1 android-debug
```

For Release, provide **your own** `LINKS_ANDROID_KEYSTORE`, `LINKS_ANDROID_STORE_PASSWORD`, `LINKS_ANDROID_KEY_PASSWORD`, and optional `LINKS_ANDROID_KEY_ALIAS` environment variables in a private shell, then:

```powershell
./scripts/dev.ps1 android-release -SplitPerAbi
```

Never save passwords in scripts, `key.properties`, screenshots or issues. No maintainer signing key is included. Release does not fall back to Android's debug key. Split ABI builds preserve versionCode 24 using Flutter's supported force-version flag. Universal builds omit `-SplitPerAbi`.

A public-copy reproducibility check may use a separate temporary QA key; such an APK is test evidence, **not** the maintainer-signed downloadable APK. Installing a different signing identity over an existing app is not supported. Back up before any uninstall. No emulator or physical Android test was completed here.

## Optional engines and artwork

FFmpeg, whisper.cpp and Whisper models are external and not downloaded automatically. Import known binaries/models via the corresponding tool settings; verify upstream checksums and exact-build licenses. See `docs/OPTIONAL_ENGINES.md` and `THIRD_PARTY_NOTICES.md`. The tested tiny model is 77,691,713 bytes; do not commit it.

Original sprites: `python scripts/generate_pixel_studio.py` (Pillow required); brand source: `scripts/generate_brand_v23.py`. Noto Sans SC is retained with its OFL/provenance. Promo image layout has a local generator under `docs/images/source`. Regeneration is optional and not part of compiling the existing assets.

## Generated and local files

Keep `.gitignore`, approved `.github` issue templates and `.env.example`. Do not publish `.git`, `.dart_tool`, `build`, `.gradle`, `Pods`, plugin junctions, IDE private state, real `.env`, signing material, DBs, synthetic fixture outputs or local SDK paths. `.gitignore` does **not** filter files dragged into GitHub's website.

Created and maintained by Links Tam.
