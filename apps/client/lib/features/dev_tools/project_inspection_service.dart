import 'dart:convert';

import 'package:csv/csv.dart';
import 'package:toml/toml.dart';
import 'package:yaml/yaml.dart';

import '../../core/data/tool_record.dart';
import '../utilities/environment_snapshot.dart';

/// Read selected manifests only. Never invoke a package manager, load referenced
/// files, expand environment variables, fetch versions or infer vulnerabilities.
Object? inspectDependencies(Object? input) {
  final args = input as Map<String, dynamic>,
      name = args['name'] as String,
      text = args['text'] as String;
  if (text.length > 2 * 1024 * 1024) throw const ToolFailure('配置超过2MiB。');
  final items = <Map<String, String>>[], warnings = <String>[];
  String safe(Object? value) {
    final raw = value is Map ? jsonEncode(value) : '$value';
    return SnapshotPrivacy.safeText(raw)
        .replaceAllMapped(RegExp(r'https?://[^\s"<>]+'), (m) {
          final uri = Uri.tryParse(m[0]!);
          return uri?.hasAuthority == true
              ? uri!.replace(userInfo: '').toString()
              : m[0]!;
        });
  }

  void dependencies(Object? raw, String scope) {
    if (raw == null) return;
    if (raw is! Map) throw ToolFailure('$scope 必须是依赖对象。');
    for (final e in raw.entries) {
      items.add({
        'name': '${e.key}',
        'constraint': safe(e.value),
        'scope': scope,
      });
    }
  }

  switch (name) {
    case 'pubspec.yaml':
      final root = loadYaml(text);
      if (root is! Map) throw const ToolFailure('pubspec根必须为对象。');
      dependencies(root['dependencies'], 'dependencies');
      dependencies(root['dev_dependencies'], 'dev_dependencies');
      dependencies(root['dependency_overrides'], 'overrides');
    case 'package.json':
      final root = jsonDecode(text) as Map;
      for (final key in [
        'dependencies',
        'devDependencies',
        'peerDependencies',
        'optionalDependencies',
      ]) {
        dependencies(root[key], key);
      }
      if (root['scripts'] != null) warnings.add('存在scripts；未读取或执行脚本。');
    case 'Cargo.toml':
      final root = TomlDocument.parse(text).toMap();
      for (final key in [
        'dependencies',
        'dev-dependencies',
        'build-dependencies',
      ]) {
        dependencies(root[key], key);
      }
      if (root['workspace'] is Map) {
        dependencies(
          (root['workspace'] as Map)['dependencies'],
          'workspace.dependencies',
        );
      }
      if (root['target'] is Map) {
        for (final entry in (root['target'] as Map).entries) {
          if (entry.value is Map) {
            for (final key in [
              'dependencies',
              'dev-dependencies',
              'build-dependencies',
            ]) {
              dependencies(
                (entry.value as Map)[key],
                'target.${entry.key}.$key',
              );
            }
          }
        }
      }
    case 'requirements.txt':
      final lines = const LineSplitter().convert(
        text.replaceAll(RegExp(r'\\\r?\n'), ' '),
      );
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        if (line.startsWith('-')) {
          warnings.add('行${i + 1}：选项/引用文件未执行或跟随。');
          continue;
        }
        final match = RegExp(
          r'^([A-Za-z0-9][A-Za-z0-9._-]*(?:\[[^\]]+\])?)(.*)$',
        ).firstMatch(line);
        if (match == null) {
          warnings.add('行${i + 1}无法识别，未猜测版本。');
          continue;
        }
        items.add({
          'name': match[1]!,
          'constraint': safe(match[2]!.trim()),
          'scope': 'requirements',
        });
      }
    default:
      throw const ToolFailure(
        '请选择pubspec.yaml、package.json、requirements.txt或Cargo.toml。',
      );
  }
  if (items.length > 5000) throw const ToolFailure('依赖超过5000项。');
  final seen = <String>{};
  for (final item in items) {
    if (!seen.add('${item['scope']}:${item['name']}')) {
      warnings.add('重复声明：${item['name']}');
    }
  }
  return {
    'file': name,
    'dependencies': items,
    'warnings': warnings,
    'note': '静态配置检查；未联网检查最新版本或漏洞，未读取锁文件解析实际安装版本。',
  };
}

/// Diff only allowlisted names and version fields; environment values, selected
/// config bodies and raw hardware data never enter the result/export.
Object? diffEnvironment(Object? input) {
  final args = input as Map<String, dynamic>;
  Map parse(String key) {
    final text = args[key] as String;
    if (text.length > 8 * 1024 * 1024) throw const ToolFailure('环境文件超过8MiB。');
    final root = jsonDecode(text) as Map;
    if (root['schemaVersion'] != 1) throw const ToolFailure('不支持的快照版本。');
    return root;
  }

  final before = parse('before'), after = parse('after');
  List<Map<String, String>> changes(
    Map<String, String> old,
    Map<String, String> next,
  ) => [
    for (final id in {...old.keys, ...next.keys}.toList()..sort())
      if (old[id] != next[id])
        {
          'name': id,
          'change': !old.containsKey(id)
              ? 'added'
              : !next.containsKey(id)
              ? 'removed'
              : 'version',
          'before': old[id] ?? '',
          'after': next[id] ?? '',
        },
  ];
  Map<String, String> tools(Map root) => {
    for (final raw in root['tools'] as List? ?? [])
      if (raw is Map && raw['id'] is String)
        raw['id'] as String:
            '${raw['version'] ?? raw['output'] ?? raw['available'] ?? ''}',
  };
  Map<String, String> software(String key) {
    final text = args[key] as String? ?? '';
    if (text.length > 8 * 1024 * 1024) throw const ToolFailure('软件清单超过8MiB。');
    if (text.isEmpty) return {};
    final rows = csv.decode(text.replaceFirst('\ufeff', ''));
    if (rows.isEmpty) return {};
    final header = rows.first.map((v) => '$v').toList(),
        id = header.indexOf('id'),
        name = header.indexOf('name'),
        version = header.indexOf('version');
    if (name < 0 || version < 0) {
      throw const ToolFailure('软件CSV缺少name/version列。');
    }
    if (rows.length > 20001) throw const ToolFailure('软件清单超过20000项。');
    final result = <String, String>{};
    for (final row in rows.skip(1)) {
      if (row.length < header.length) throw const ToolFailure('软件CSV存在不完整行。');
      final identity = id >= 0 && '${row[id]}'.isNotEmpty
          ? '${row[id]}'
          : '${row[name]}';
      result[identity] = '${row[version]}';
    }
    return result;
  }

  final oldNames = (before['environmentVariableNames'] as List? ?? [])
          .whereType<String>()
          .toSet(),
      newNames = (after['environmentVariableNames'] as List? ?? [])
          .whereType<String>()
          .toSet();
  return {
    'tools': changes(tools(before), tools(after)),
    'software': changes(software('beforeCsv'), software('afterCsv')),
    'environmentNamesAdded': newNames.difference(oldNames).toList()..sort(),
    'environmentNamesRemoved': oldNames.difference(newNames).toList()..sort(),
    'note': '只比较环境变量名称；不读取或导出值。软件清单未选择时无法比较软件。',
  };
}
