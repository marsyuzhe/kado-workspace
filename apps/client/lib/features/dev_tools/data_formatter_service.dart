import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../../core/data/tool_record.dart';

/// YAML is parsed by package:yaml. Normalized output deliberately uses the JSON
/// flow form accepted by YAML 1.2, avoiding a custom YAML parser/emitter.
Object? formatData(Object? input) {
  final args = input as Map<String, dynamic>,
      text = args['text'] as String,
      mode = args['mode'] as String;
  if (text.trim().isEmpty || text.length > 2 * 1024 * 1024) {
    throw const ToolFailure('输入不能为空，且最多2MiB字符。');
  }
  Object? parse(String value, bool yaml) {
    Object? node;
    try {
      node = yaml ? loadYaml(value) : jsonDecode(value);
    } on YamlException catch (e) {
      throw ToolFailure(
        'YAML 第${(e.span?.start.line ?? 0) + 1}行，第${(e.span?.start.column ?? 0) + 1}列：${e.message}',
      );
    } on FormatException catch (e) {
      final offset = e.offset ?? 0,
          before = value.substring(0, offset.clamp(0, value.length));
      final lines = before.split('\n');
      throw ToolFailure(
        'JSON 第${lines.length}行，第${lines.last.length + 1}列：${e.message}',
      );
    }
    var count = 0;
    final active = <Object>{};
    Object? normalize(Object? v, int depth) {
      if (++count > 100000 || depth > 64) throw const ToolFailure('结构过深或节点过多。');
      if (v == null || v is String || v is bool || v is num && v.isFinite) {
        return v;
      }
      if (!active.add(v)) throw const ToolFailure('不支持循环YAML别名。');
      try {
        if (v is Map) {
          if (v.keys.any((k) => k is! String)) {
            throw const ToolFailure('JSON转换只支持字符串键；复杂YAML键不能无损转换。');
          }
          return {
            for (final e in v.entries)
              e.key as String: normalize(e.value, depth + 1),
          };
        }
        if (v is List) return [for (final e in v) normalize(e, depth + 1)];
        throw const ToolFailure('此YAML类型无法表示为JSON。');
      } finally {
        active.remove(v);
      }
    }

    return normalize(node, 0);
  }

  final value = parse(text, mode.startsWith('yaml'));
  if (mode == 'diff') {
    final other = args['other'] as String? ?? '';
    if (other.length > 2 * 1024 * 1024) throw const ToolFailure('比较输入超过限制。');
    final right = parse(other, false), changes = <Map<String, dynamic>>[];
    String escape(String s) => s.replaceAll('~', '~0').replaceAll('/', '~1');
    void compare(Object? a, Object? b, String path) {
      if (changes.length >= 1000) return;
      if (a is Map && b is Map) {
        for (final key in {...a.keys, ...b.keys}) {
          if (changes.length >= 1000) break;
          final child = '$path/${escape(key as String)}';
          if (!a.containsKey(key)) {
            changes.add({'path': child, 'change': 'added', 'after': b[key]});
          } else if (!b.containsKey(key)) {
            changes.add({'path': child, 'change': 'removed', 'before': a[key]});
          } else {
            compare(a[key], b[key], child);
          }
        }
      } else if (a is List && b is List) {
        for (var i = 0; i < (a.length > b.length ? a.length : b.length); i++) {
          if (changes.length >= 1000) break;
          if (i >= a.length) {
            changes.add({'path': '$path/$i', 'change': 'added', 'after': b[i]});
          } else if (i >= b.length) {
            changes.add({
              'path': '$path/$i',
              'change': 'removed',
              'before': a[i],
            });
          } else {
            compare(a[i], b[i], '$path/$i');
          }
        }
      } else if (jsonEncode(a) != jsonEncode(b)) {
        changes.add({
          'path': path,
          'change': 'changed',
          'before': a,
          'after': b,
        });
      }
    }

    compare(value, right, '');
    return {
      'text': const JsonEncoder.withIndent('  ').convert(changes),
      'value': changes,
      'note': changes.length >= 1000
          ? '差异达到1000项上限。'
          : '${changes.length}项差异（JSON Pointer路径）',
    };
  }
  return {
    'text': mode == 'minify'
        ? jsonEncode(value)
        : const JsonEncoder.withIndent('  ').convert(value),
    'value': value,
    'note': {'yaml-format', 'json-yaml'}.contains(mode)
        ? '规范化为YAML 1.2可解析的JSON流式语法；注释、锚点与原排版不保留。'
        : '语法有效',
  };
}
