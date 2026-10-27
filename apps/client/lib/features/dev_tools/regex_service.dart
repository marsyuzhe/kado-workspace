import '../../core/data/tool_record.dart';

Object? evaluateRegex(Object? input) {
  final args = input as Map<String, dynamic>,
      pattern = args['pattern'] as String,
      text = args['text'] as String;
  if (pattern.length > 2000 || text.length > 200000) {
    throw const ToolFailure('表达式最多2000字符，文本最多200000字符。');
  }
  final regex = RegExp(
    pattern,
    caseSensitive: args['caseSensitive'] != false,
    multiLine: args['multiLine'] == true,
    dotAll: args['dotAll'] == true,
    unicode: args['unicode'] == true,
  );
  final matches = <Map<String, dynamic>>[];
  var truncated = false;
  for (final m in regex.allMatches(text)) {
    if (matches.length >= 1000) {
      truncated = true;
      break;
    }
    matches.add({
      'start': m.start,
      'end': m.end,
      'match': m[0],
      'groups': [for (var i = 1; i <= m.groupCount; i++) m[i]],
      'named': {for (final name in m.groupNames) name: m.namedGroup(name)},
    });
  }
  // Replacement is kept inside the same killable isolate as matching.
  final replacement = args['replacement'] as String? ?? '';
  if (replacement.length > 10000) throw const ToolFailure('替换模板过长。');
  String expand(Match match) => replacement.replaceAllMapped(
    RegExp(r'\$\$|\$(\d+)|\$\{([A-Za-z_][A-Za-z_0-9]*)\}'),
    (token) {
      if (token[0] == '\$\$') return '\$';
      final index = int.tryParse(token[1] ?? '');
      if (index != null) {
        return index <= match.groupCount ? match[index] ?? '' : token[0]!;
      }
      if (match is RegExpMatch && match.groupNames.contains(token[2])) {
        return match.namedGroup(token[2]!) ?? '';
      }
      return token[0]!;
    },
  );
  var end = 0, replacements = 0;
  final output = StringBuffer();
  for (final m in regex.allMatches(text)) {
    if (++replacements > 1000) {
      truncated = true;
      break;
    }
    output.write(text.substring(end, m.start));
    output.write(expand(m));
    end = m.end;
    if (output.length > 2 * 1024 * 1024) throw const ToolFailure('替换输出超过2MiB。');
  }
  output.write(text.substring(end));
  return {
    'matches': matches,
    'replacement': output.toString(),
    'truncated': truncated,
    'note': 'Dart RegExp · 范围为UTF-16索引 · 替换支持\$1 / \${name} / \$\$；最多1000项',
  };
}
