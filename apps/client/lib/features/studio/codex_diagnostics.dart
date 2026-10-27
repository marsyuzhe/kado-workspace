import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/data/tool_record.dart';
import 'codex_protocol.dart';

class CodexDiagnostic {
  const CodexDiagnostic({
    required this.version,
    required this.restrictedReadSupported,
    required this.schemaChecksum,
  });
  final String version, schemaChecksum;
  final bool restrictedReadSupported;
  // A capability probe is not a finished task adapter or a verified login.
  bool get taskExecutionEnabled => false;
  String get explanation => restrictedReadSupported
      ? '目录读取限制字段存在；任务适配与真实账号验收仍未完成。'
      : 'BLOCKED：该CLI协议缺少受限读取目录字段，无法保证只读取授权项目。请勿降低权限边界。';
}

bool schemaSupportsRestrictedRead(Map<String, dynamic> schema) {
  final definitions = schema['definitions'] as Map? ?? {};
  dynamic resolve(dynamic value) {
    if (value is Map && value[r'$ref'] is String) {
      return definitions[(value[r'$ref'] as String).split('/').last];
    }
    if (value is Map &&
        value['allOf'] is List &&
        (value['allOf'] as List).length == 1) {
      return resolve((value['allOf'] as List).first);
    }
    return value;
  }

  final policy = resolve(definitions['SandboxPolicy']);
  if (policy is! Map || policy['oneOf'] is! List) return false;
  for (final variant in policy['oneOf'] as List) {
    final properties = variant is Map ? variant['properties'] : null;
    if (properties is! Map ||
        !((properties['type'] as Map?)?['enum'] as List? ?? []).contains(
          'readOnly',
        )) {
      continue;
    }
    final access = resolve(properties['access']);
    if (access is! Map || access['oneOf'] is! List) return false;
    for (final shape in access['oneOf'] as List) {
      final fields = shape is Map ? shape['properties'] : null;
      if (fields is Map &&
          ((fields['type'] as Map?)?['enum'] as List? ?? []).contains(
            'restricted',
          ) &&
          fields.containsKey('readableRoots') &&
          fields.containsKey('includePlatformDefaults')) {
        return true;
      }
    }
  }
  return false;
}

/// Only two fixed, local metadata operations are exposed. No arbitrary shell,
/// login, thread/start or turn/start method is reachable through this service.
class CodexDiagnostics {
  Future<CodexDiagnostic> inspect(String executable) async {
    if (!Platform.isWindows) {
      throw const ToolFailure('Codex本地诊断需要Windows桌面执行器。');
    }
    if (!p.isAbsolute(executable) ||
        p.extension(executable).toLowerCase() != '.exe' ||
        !await File(executable).exists()) {
      throw const ToolFailure('请选择已安装的Codex原生.exe完整路径，不接受脚本或Shell命令。');
    }
    final canonical = await File(executable).resolveSymbolicLinks();
    if (!p.equals(p.normalize(executable), canonical)) {
      throw const ToolFailure('请直接选择程序真实路径，不通过链接或重定向。');
    }
    final temp = await Directory.systemTemp.createTemp('links-codex-probe-');
    try {
      final version = (await _metadata(canonical, [
        '--version',
      ], temp.path)).trim();
      if (!RegExp(r'^codex-cli [a-zA-Z0-9.+\-]+$').hasMatch(version)) {
        throw const ToolFailure('该程序没有返回可识别的Codex CLI版本。');
      }
      await _metadata(canonical, [
        'app-server',
        'generate-json-schema',
        '--out',
        temp.path,
      ], temp.path);
      final schemaFile = File(p.join(temp.path, 'v2', 'TurnStartParams.json'));
      if (!await schemaFile.exists() ||
          await schemaFile.length() > 4 * 1024 * 1024) {
        throw const ToolFailure('CLI未能导出受支持的官方v2 Schema。');
      }
      final bytes = await schemaFile.readAsBytes();
      final schema = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      return CodexDiagnostic(
        version: version,
        restrictedReadSupported: schemaSupportsRestrictedRead(schema),
        schemaChecksum: sha256.convert(bytes).toString(),
      );
    } finally {
      // Only the unique directory allocated by this invocation is removed.
      if (p.isWithin(Directory.systemTemp.path, temp.path) &&
          p.basename(temp.path).startsWith('links-codex-probe-')) {
        await temp.delete(recursive: true);
      }
    }
  }

  Future<String> _metadata(
    String exe,
    List<String> arguments,
    String cwd,
  ) async {
    final process = await Process.start(
      exe,
      arguments,
      workingDirectory: cwd,
      runInShell: false,
    );
    await process.stdin.close();
    final output = <int>[], errors = <int>[];
    bool overflow = false;
    Future<void> drain(Stream<List<int>> stream, List<int> target) async {
      await for (final chunk in stream) {
        if (target.length + chunk.length > 64 * 1024) {
          overflow = true;
          process.kill();
          continue;
        }
        target.addAll(chunk);
      }
    }

    final out = drain(process.stdout, output),
        err = drain(process.stderr, errors);
    try {
      final code = await process.exitCode.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          process.kill();
          throw const ToolFailure('Codex元数据探测超时，已停止本次进程。');
        },
      );
      await Future.wait([out, err]);
      if (code != 0 || overflow) {
        throw const ToolFailure('Codex元数据探测失败或输出超限；未发起模型请求。');
      }
      return redactCodexText(utf8.decode(output, allowMalformed: true));
    } finally {
      // This is the exact Process handle created here, never a global kill.
      process.kill();
    }
  }
}
