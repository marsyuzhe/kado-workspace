import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/jobs/utility_process.dart';
import '../../core/platform/system_actions.dart';
import '../../core/storage/utility_files.dart';
import '../archive/archive_service.dart';
import 'media_converter.dart';

class SnapshotConfig {
  const SnapshotConfig(
    this.source,
    this.name,
    this.content,
    this.redactions, {
    this.rejected = '',
  });
  final String source, name, rejected;
  final Uint8List content;
  final int redactions;
}

class EnvironmentPlan {
  const EnvironmentPlan(
    this.hardware,
    this.tools,
    this.configs,
    this.systemRoot,
  );
  final Map<String, dynamic> hardware;
  final List<Map<String, dynamic>> tools;
  final List<SnapshotConfig> configs;
  final String systemRoot;
}

class SnapshotPrivacy {
  static final secretKey = RegExp(
    r'api[_. -]?key|access[_. -]?key|token|secret|password|passwd|credential|private[_. -]?key|authorization|auth[_-]?token',
    caseSensitive: false,
  );
  static String safeText(String value, {String? profile}) {
    value = const LineSplitter()
        .convert(value)
        .map((line) {
          final match = RegExp(r'^(.*?)[:=]').firstMatch(line);
          return match != null && secretKey.hasMatch(match[1]!)
              ? '[REDACTED SECRET ASSIGNMENT]'
              : line;
        })
        .join('\n');
    var result = value.replaceAll(
      RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
    result = result.replaceAllMapped(
      RegExp(
        r'''([?&](?:api_?key|access_token|token|secret|password)=)[^&\s"'#]+''',
        caseSensitive: false,
      ),
      (m) => '${m[1]}[REDACTED]',
    );
    for (final pattern in [
      r'\bsk[-_][A-Za-z0-9_-]{16,}',
      r'\bgh[pousr]_[A-Za-z0-9_]{16,}',
      r'\bgithub_pat_[A-Za-z0-9_]{16,}',
      r'\bAKIA[A-Z0-9]{16}\b',
      r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
    ]) {
      result = result.replaceAll(RegExp(pattern), '[REDACTED]');
    }
    if (profile != null && profile.isNotEmpty) {
      result = result.replaceAll(
        RegExp(RegExp.escape(profile), caseSensitive: false),
        '%USERPROFILE%',
      );
    }
    return result;
  }

  static SnapshotConfig config(
    String path,
    Uint8List bytes, {
    String? profile,
  }) {
    final name = p.basename(path),
        segments = p.split(path).map((v) => v.toLowerCase()).toSet();
    if ({
          '.ppk',
          '.p8',
          '.pem',
          '.key',
          '.pfx',
          '.p12',
        }.contains(p.extension(name).toLowerCase()) ||
        segments.any({'.ssh', '.aws', '.gnupg', 'credentials'}.contains) ||
        RegExp(
          r'^(\.env(?:\..*)?|id_rsa|id_ed25519|.*cookie.*|.*credential.*)$',
          caseSensitive: false,
        ).hasMatch(name)) {
      return SnapshotConfig(
        path,
        name,
        Uint8List(0),
        0,
        rejected: '凭据/私钥/环境秘密文件默认不导出',
      );
    }
    if (bytes.isEmpty || bytes.length > 1024 * 1024) {
      return SnapshotConfig(
        path,
        name,
        Uint8List(0),
        0,
        rejected: '配置为空或超过1MiB',
      );
    }
    String text;
    try {
      text = utf8.decode(bytes).replaceFirst('\ufeff', '');
    } catch (_) {
      return SnapshotConfig(
        path,
        name,
        Uint8List(0),
        0,
        rejected: '仅支持UTF-8文本配置',
      );
    }
    if (text.contains('PRIVATE KEY-----') ||
        text.runes.any((r) => r < 32 && !{9, 10, 13}.contains(r))) {
      return SnapshotConfig(
        path,
        name,
        Uint8List(0),
        0,
        rejected: '发现私钥或二进制内容，拒绝导出',
      );
    }
    var count = 0;
    dynamic scrub(dynamic value) {
      if (value is Map) {
        return {
          for (final e in value.entries)
            e.key: secretKey.hasMatch(e.key.toString())
                ? (() {
                    count++;
                    return '[REDACTED]';
                  })()
                : scrub(e.value),
        };
      }
      if (value is List) return value.map(scrub).toList();
      if (value is String) {
        final safe = safeText(value, profile: profile);
        if (safe != value) count++;
        return safe;
      }
      return value;
    }

    if (p.extension(name).toLowerCase() == '.json') {
      try {
        text = const JsonEncoder.withIndent('  ')
            .convert(scrub(jsonDecode(text)));
      } catch (_) {
        return SnapshotConfig(
          path,
          name,
          Uint8List(0),
          0,
          rejected: 'JSON无效，未按文本回退导出',
        );
      }
    } else {
      final lines = <String>[];
      int? blockIndent;
      for (final line in const LineSplitter().convert(text)) {
        final indent = line.length - line.trimLeft().length;
        if (blockIndent != null &&
            line.trim().isNotEmpty &&
            indent > blockIndent) {
          count++;
          lines.add(' [REDACTED BLOCK]');
          continue;
        }
        if (line.trim().isNotEmpty) blockIndent = null;
        final assignment = RegExp(r'^\s*([^:=]+)\s*[:=]\s*(.*)$')
            .firstMatch(line);
        if (assignment != null && secretKey.hasMatch(assignment[1]!)) {
          final value = assignment[2]!;
          if (value.contains("'''") ||
              value.contains('"""') ||
              value.trimLeft().startsWith('[')) {
            return SnapshotConfig(
              path,
              name,
              Uint8List(0),
              0,
              rejected: '发现复杂多行敏感配置，需先人工脱敏',
            );
          }
          lines.add('${assignment[1]}: [REDACTED]');
          count++;
          if (value.trim() == '|' || value.trim() == '>') blockIndent = indent;
        } else {
          final safe = safeText(line, profile: profile);
          if (safe != line) count++;
          lines.add(safe);
        }
      }
      text = lines.join('\n');
    }
    return SnapshotConfig(
      path,
      name,
      Uint8List.fromList(utf8.encode(text)),
      count,
    );
  }
}

class EnvironmentSnapshotService {
  EnvironmentSnapshotService(this.store, this.native, this.files, this.root);
  final RecordStore store;
  final NativePlatformAdapter native;
  final UtilityFileService files;
  final Future<Directory> Function() root;
  static const commands = {
    'flutter': ['--version'],
    'dart': ['--version'],
    'python': ['--version'],
    'node': ['--version'],
    'git': ['--version'],
    'docker': ['--version'],
    'code': ['--version'],
  };
  static List<String> encodedPowerShell(String code) {
    final bytes = ByteData(code.length * 2);
    for (var i = 0; i < code.length; i++) {
      bytes.setUint16(i * 2, code.codeUnitAt(i), Endian.little);
    }
    return [
      '-NoProfile',
      '-NonInteractive',
      '-EncodedCommand',
      base64.encode(bytes.buffer.asUint8List()),
    ];
  }

  static String psLiteral(String value) => "'${value.replaceAll("'", "''")}'";
  String powershell(String systemRoot) => p.join(
    systemRoot,
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );
  Future<String?> findTool(String name, String systemRoot) async {
    try {
      final output = await boundedProcess(
        p.join(systemRoot, 'System32', 'where.exe'),
        [name],
        timeout: const Duration(seconds: 4),
      );
      for (final path in const LineSplitter().convert(output)) {
        if (p.isAbsolute(path) &&
            {
              '.exe',
              '.bat',
              '.cmd',
            }.contains(p.extension(path).toLowerCase()) &&
            await FileSystemEntity.type(path, followLinks: false) ==
                FileSystemEntityType.file &&
            await File(path).length() > 0) {
          return path;
        }
      }
    } catch (_) {
      /* Unavailable is recorded in the plan. */
    }
    return null;
  }

  Future<EnvironmentPlan> plan(List<String> configurationPaths) async {
    if (!Platform.isWindows) throw const ToolFailure('环境快照当前仅支持Windows。');
    if (configurationPaths.length > 10) {
      throw const ToolFailure('单次最多10个可预览文本配置。');
    }
    final summary = await native.systemEnvironmentSummary(),
        systemRoot = summary['windowsDirectory'] as String?;
    if (systemRoot == null || !p.isAbsolute(systemRoot)) {
      throw const ToolFailure('Windows系统目录不可用。');
    }
    final tools = <Map<String, dynamic>>[];
    for (final entry in commands.entries) {
      final path = await findTool(entry.key, systemRoot);
      tools.add({
        'id': entry.key,
        'path': path ?? '',
        'available': path != null,
        'sha256': path == null
            ? ''
            : await archiveHash(File(path), TaskCancellation()),
        'arguments': entry.value,
        'reason': path == null ? '系统PATH未发现可读程序/有效别名' : '',
      });
    }
    final configs = <SnapshotConfig>[];
    for (final path in configurationPaths) {
      final file = File(path);
      if (!p.isAbsolute(path) ||
          await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() > 1024 * 1024) {
        configs.add(
          SnapshotConfig(
            path,
            p.basename(path),
            Uint8List(0),
            0,
            rejected: '路径无效、链接或超过1MiB',
          ),
        );
        continue;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in file.openRead()) {
        bytes.add(chunk);
        if (bytes.length > 1024 * 1024) break;
      }
      configs.add(
        SnapshotPrivacy.config(
          path,
          bytes.takeBytes(),
          profile: Platform.environment['USERPROFILE'],
        ),
      );
    }
    return EnvironmentPlan(summary, tools, configs, systemRoot);
  }

  Future<Map<String, dynamic>> toolVersion(
    Map<String, dynamic> tool,
    String systemRoot,
    UtilityJobContext job,
  ) async {
    if (tool['available'] != true) return {...tool, 'version': ''};
    final path = tool['path'] as String,
        arguments = List<String>.from(tool['arguments'] as List);
    try {
      if (await archiveHash(File(path), job.cancellation) != tool['sha256']) {
        return {
          ...tool,
          'available': false,
          'version': '',
          'reason': '预览后工具文件发生变化，未执行',
        };
      }
      final UtilityProcessResult output;
      if ({'.cmd', '.bat'}.contains(p.extension(path).toLowerCase())) {
        final script =
            '& ${psLiteral(path)} ${arguments.map(psLiteral).join(' ')} 2>&1; '
            r'exit $LASTEXITCODE';
        output = await runUtilityProcess(
          powershell(systemRoot),
          encodedPowerShell(script),
          job,
          timeout: const Duration(seconds: 15),
        );
      } else {
        output = await runUtilityProcess(
          path,
          arguments,
          job,
          timeout: const Duration(seconds: 15),
        );
      }
      final text = SnapshotPrivacy.safeText(
        '${output.stdout}${output.stderr}',
        profile: Platform.environment['USERPROFILE'],
      );
      return {
        ...tool,
        'version': text.substring(0, text.length.clamp(0, 8192)).trim(),
        'available': output.code == 0,
        'exitCode': output.code,
        if (output.code != 0) 'reason': '版本命令未成功返回',
      };
    } on ToolFailure catch (error) {
      job.check();
      return {
        ...tool,
        'available': false,
        'version': '',
        'reason': error.message,
      };
    } on ProcessException {
      job.check();
      return {
        ...tool,
        'available': false,
        'version': '',
        'reason': '无法启动版本读取命令',
      };
    } on FileSystemException {
      job.check();
      return {
        ...tool,
        'available': false,
        'version': '',
        'reason': '预览后工具路径不可读，未执行',
      };
    }
  }

  Future<(List<Map<String, dynamic>>, List<String>)> softwareList(
    String systemRoot,
    Directory work,
    UtilityJobContext job,
  ) async {
    final warnings = <String>[], rows = <Map<String, dynamic>>[];
    final winget = await findTool('winget', systemRoot),
        export = File(p.join(work.path, 'winget.json'));
    if (winget != null) {
      try {
        final output = await runUtilityProcess(
          winget,
          [
            'export',
            '--output',
            export.path,
            '--include-versions',
            '--disable-interactivity',
          ],
          job,
          timeout: const Duration(seconds: 30),
        );
        if (output.code == 0 &&
            await export.exists() &&
            await export.length() < 5 * 1024 * 1024) {
          final data = jsonDecode(
            (await export.readAsString()).replaceFirst('\ufeff', ''),
          ) as Map;
          for (final source in data['Sources'] as List? ?? []) {
            for (final package in (source as Map)['Packages'] as List? ?? []) {
              final item = package as Map;
              rows.add({
                'name': item['PackageIdentifier'] ?? '',
                'id': item['PackageIdentifier'] ?? '',
                'version': item['Version'] ?? '',
                'source': 'winget export',
              });
            }
          }
        } else {
          warnings.add('winget export未成功；没有自动接受源协议或安装软件。');
        }
      } catch (_) {
        job.check();
        warnings.add('winget export不可用或超时。');
      }
    } else {
      warnings.add('系统PATH未发现winget。');
    }
    try {
      final appx = File(p.join(work.path, 'appx.json'));
      if (await appx.exists()) throw const ToolFailure('临时清单已存在，未覆盖。');
      final output = await runUtilityProcess(
        powershell(systemRoot),
        encodedPowerShell(
          'Get-AppxPackage | Select-Object Name,Version,PackageFamilyName | ConvertTo-Json -Compress -Depth 3 | Set-Content -LiteralPath ${psLiteral(appx.path)} -Encoding UTF8',
        ),
        job,
        timeout: const Duration(seconds: 20),
      );
      if (output.code == 0 &&
          await appx.exists() &&
          await appx.length() < 5 * 1024 * 1024) {
        final decoded = jsonDecode(
              (await appx.readAsString()).replaceFirst('\ufeff', ''),
            ),
            apps = decoded is List ? decoded : [decoded];
        for (final app in apps) {
          final a = app as Map;
          rows.add({
            'name': a['Name'] ?? '',
            'id': a['PackageFamilyName'] ?? '',
            'version': a['Version'] ?? '',
            'source': 'Get-AppxPackage',
          });
        }
      } else {
        warnings.add('Get-AppxPackage未返回可用清单。');
      }
    } catch (_) {
      job.check();
      warnings.add('Get-AppxPackage不可用或超时。');
    }
    return (rows.take(10000).toList(), warnings);
  }

  Future<ToolRecord> collect(
    EnvironmentPlan plan,
    String outputParent,
    UtilityJobContext job,
  ) async {
    job.check();
    final parent = await files.selectedDirectory(outputParent),
        work = Directory(p.join((await root()).path, 'utility-work', job.id));
    await work.create(recursive: true);
    final tools = <Map<String, dynamic>>[], warnings = <String>[];
    ToolRecord? record;
    final manifest = <Map<String, dynamic>>[];
    try {
      for (var i = 0; i < plan.tools.length; i++) {
        job.check();
        await job.progress(
          i,
          plan.tools.length + 2,
          currentFile: '读取${plan.tools[i]['id']}版本',
          force: true,
        );
        tools.add(await toolVersion(plan.tools[i], plan.systemRoot, job));
      }
      final software = await softwareList(plan.systemRoot, work, job);
      warnings.addAll(software.$2);
      for (final tool in tools) {
        if (tool['available'] != true) {
          warnings.add('${tool['id']}: ${tool['reason']}');
        }
      }
      final name =
              'Links-environment-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}-${newId().substring(0, 8)}',
          destination = Directory(p.join(parent.path, name));
      if (await destination.exists()) throw const ToolFailure('输出目录已存在，请重新选择。');
      await destination.create();
      record = await store.create(
        'environment_snapshot',
        'Windows环境快照',
        data: {
          'payloadVersion': 1,
          'outputDirectory': destination.path,
          'manifest': [],
          'status': 'processing',
          'jobId': job.id,
          'syncAllowed': false,
          'isSensitive': true,
        },
      );
      await job.output(record.id);
      final safeConfigs = <Map<String, dynamic>>[];
      for (var i = 0; i < plan.configs.length; i++) {
        final config = plan.configs[i];
        if (config.rejected.isNotEmpty) {
          warnings.add('${config.name}: ${config.rejected}');
          continue;
        }
        final configs = Directory(p.join(destination.path, 'configs'));
        await configs.create();
        final safeName =
            'config-$i${{'.json', '.yaml', '.yml', '.toml', '.ini', '.txt', '.ps1', '.cfg', '.conf'}.contains(p.extension(config.name).toLowerCase()) ? p.extension(config.name).toLowerCase() : '.txt'}';
        await files.exportBytes(
          configs.path,
          safeName,
          config.content,
          job.cancellation,
        );
        safeConfigs.add({
          'name': SnapshotPrivacy.safeText(config.name),
          'file': 'configs/$safeName',
          'redactions': config.redactions,
          'sha256': sha256.convert(config.content).toString(),
        });
        record = await store.save(
          record!.copyWith(
            data: {...record.data, 'configurationFiles': List.of(safeConfigs)},
          ),
        );
      }
      final environment = {
        'schemaVersion': 1,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'osVersion': Platform.operatingSystemVersion,
        'hardware': plan.hardware,
        'tools': [
          for (final tool in tools)
            {
              ...tool,
              'path': SnapshotPrivacy.safeText(
                tool['path'] as String,
                profile: Platform.environment['USERPROFILE'],
              ),
            },
        ],
        'environmentVariableNames': Platform.environment.keys.toList()..sort(),
        'configurationFiles': safeConfigs,
        'warnings': warnings,
        'privacy': {
          'environmentValuesExported': false,
          'credentialsExportedByDefault': false,
          'selectedConfigsRedacted': true,
          'manualReviewRequired': true,
        },
        'softwareSources': [
          'winget export when available',
          'Get-AppxPackage when available',
        ],
      };
      String safeCell(String value) {
        final safe = SnapshotPrivacy.safeText(value);
        return RegExp(r'^\s*[=+@-]').hasMatch(safe) ? "'$safe" : safe;
      }

      final reports = <String, String>{
        'environment.json': const JsonEncoder.withIndent('  ')
            .convert(environment),
        'software-list.csv':
            '\ufeff${csv.encode([
              ['name', 'id', 'version', 'source'],
              for (final row in software.$1) [
                  for (final key in ['name', 'id', 'version', 'source']) safeCell('${row[key] ?? ''}'),
                ],
            ])}',
        'README.md':
            '# Windows环境快照\n\n生成时间：${environment['createdAt']}\n\n此目录包含系统硬件、已发现工具版本和可获取的软件清单。未安装/不可用命令有明确原因，软件清单可能不完整。没有自动安装、修复、导入或覆盖系统配置。\n\n环境变量仅保存名称；可选配置是人工预览后选择的脱敏副本。自动检测不能识别所有自定义秘密，请分享前再次审阅。\n\n配置副本${safeConfigs.length}个，敏感字段替换${plan.configs.fold<int>(0, (n, c) => n + c.redactions)}处。\n\n## 读取异常\n${warnings.map((w) => '- ${SnapshotPrivacy.safeText(w)}').join('\n')}\n',
        'restore-guide.md': '# 手动恢复指南\n\n1. 在新系统核对environment.json的系统/硬件和工具版本。\n2. 从官方网站获取工具和安装包；software-list.csv是记录，不是自动执行脚本。\n3. 检查configs中的脱敏副本，与现有配置逐项比较；不要覆盖后续编辑。\n4. 在原软件界面手动导入需要的设置，自行从安全存储恢复凭据；本快照不包含密钥。\n5. 验证工具版本、项目构建与备份，再清理旧环境。\n\n本版不自动执行恢复或软件安装命令。\n',
      };
      for (final report in reports.entries) {
        job.check();
        final bytes = Uint8List.fromList(utf8.encode(report.value));
        final file = await files.exportBytes(
          destination.path,
          report.key,
          bytes,
          job.cancellation,
        );
        manifest.add({
          'name': report.key,
          'sha256': sha256.convert(bytes).toString(),
          'size': await file.length(),
        });
        record = await store.save(
          record!.copyWith(
            data: {...record.data, 'manifest': List.of(manifest)},
          ),
        );
      }
      await job.progress(
        plan.tools.length + 2,
        plan.tools.length + 2,
        currentFile: '四份报告校验完成',
        force: true,
      );
      final row = await store.save(
        record!.copyWith(
          data: {
            ...record.data,
            'payloadVersion': 1,
            'outputDirectory': destination.path,
            'manifest': manifest,
            'configCount': safeConfigs.length,
            'warnings': warnings,
            'status': warnings.isEmpty ? 'complete' : 'partial',
            'jobId': job.id,
            'syncAllowed': false,
            'isSensitive': true,
          },
        ),
      );
      return row;
    } catch (error) {
      final current = record;
      if (current != null) {
        await store.save(
          current.copyWith(
            data: {
              ...current.data,
              'manifest': List.of(manifest),
              'status': job.cancellation.cancelled ? 'cancelled' : 'failed',
              'error': error is ToolFailure ? error.message : '收集或写入失败，已有文件保留。',
            },
          ),
        );
      }
      rethrow;
    } finally {
      for (final name in ['winget.json', 'appx.json']) {
        final exported = File(p.join(work.path, name));
        if (await exported.exists()) await exported.delete();
      }
      if (await work.exists() && await work.list().isEmpty) await work.delete();
    }
  }
}
