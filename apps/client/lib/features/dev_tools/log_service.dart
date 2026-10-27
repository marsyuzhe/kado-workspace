import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/data/tool_record.dart';

class _LogLine {
  const _LogLine(this.line, this.nextOffset, this.text, this.truncated);
  final int line, nextOffset;
  final String text;
  final bool truncated;
}

/// Byte offsets permit sequential pages without retaining a whole-file index.
/// Individual giant lines are truncated to 16KiB; UTF-8 decoding is bounded.
Stream<_LogLine> _lines(File file, int offset, int line) async* {
  var buffer = BytesBuilder(copy: false), truncated = false, base = offset;
  await for (final chunk in file.openRead(offset)) {
    var start = 0;
    void append(int end) {
      final available = 16384 - buffer.length, needed = end - start;
      if (needed > available) truncated = true;
      if (available > 0) {
        buffer.add(
          chunk.sublist(
            start,
            start + (needed < available ? needed : available),
          ),
        );
      }
    }

    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] != 10) continue;
      append(i);
      var text = utf8.decode(buffer.takeBytes(), allowMalformed: true);
      if (text.endsWith('\r')) text = text.substring(0, text.length - 1);
      yield _LogLine(++line, base + i + 1, text, truncated);
      buffer = BytesBuilder(copy: false);
      truncated = false;
      start = i + 1;
    }
    if (start < chunk.length) append(chunk.length);
    base += chunk.length;
  }
  if (buffer.length > 0 || truncated) {
    yield _LogLine(
      ++line,
      base,
      utf8.decode(buffer.takeBytes(), allowMalformed: true),
      truncated,
    );
  }
}

/// Async entry runs in ControlledWorker, so scans/exports can be terminated.
/// Each pass is bounded in memory, with at most 200 visible rows.
Future<Object?> scanLog(Object? input) async {
  final args = input as Map<String, dynamic>,
      file = File(args['path'] as String),
      before = await file.stat();
  if (before.type != FileSystemEntityType.file) {
    throw const ToolFailure('日志文件不存在。');
  }
  if (args['size'] != null &&
      (args['size'] != before.size ||
          args['modified'] != before.modified.toUtc().toIso8601String())) {
    throw const ToolFailure('日志已变化，请从第一页重新加载。');
  }
  final query = (args['query'] as String? ?? '').toLowerCase(),
      level = args['level'] as String? ?? '',
      from = DateTime.tryParse(args['from'] as String? ?? ''),
      to = DateTime.tryParse(args['to'] as String? ?? ''),
      output = args['output'] as String?,
      items = <Map<String, dynamic>>[];
  final sink = output == null
      ? null
      : await File(output).open(mode: FileMode.writeOnly);
  var count = 0,
      exportBytes = 0,
      nextOffset = args['offset'] as int? ?? 0,
      lastLine = args['line'] as int? ?? 0;
  bool more = false;
  try {
    await for (final row in _lines(file, nextOffset, lastLine)) {
      nextOffset = row.nextOffset;
      lastLine = row.line;
      if (query.isNotEmpty && !row.text.toLowerCase().contains(query)) continue;
      var rowLevel = '', time = '';
      if (row.text.trimLeft().startsWith('{')) {
        try {
          final json = jsonDecode(row.text);
          if (json is Map) {
            rowLevel = '${json['level'] ?? json['severity'] ?? ''}'
                .toUpperCase();
            time =
                '${json['timestamp'] ?? json['time'] ?? json['@timestamp'] ?? ''}';
          }
        } on FormatException {
          /* Non-JSON log lines still support text filters. */
        }
      }
      if (rowLevel.isEmpty) {
        rowLevel =
            RegExp(
              r'\b(ERROR|WARN(?:ING)?|INFO|DEBUG|TRACE|FATAL)\b',
              caseSensitive: false,
            ).firstMatch(row.text)?.group(1)?.toUpperCase() ??
            '';
      }
      if (level.isNotEmpty &&
          !(level == 'WARN' && rowLevel == 'WARNING') &&
          rowLevel != level) {
        continue;
      }
      if (time.isEmpty) {
        time =
            RegExp(r'^\d{4}-\d\d-\d\d[T ][0-9:.+-]+Z?')
                .firstMatch(row.text)
                ?.group(0) ??
            '';
      }
      final stamp = DateTime.tryParse(time);
      if (from != null && (stamp == null || stamp.isBefore(from))) continue;
      if (to != null && (stamp == null || stamp.isAfter(to))) continue;
      count++;
      if (sink != null) {
        final bytes = utf8.encode(
          '${row.text}${row.truncated ? ' [LINE TRUNCATED]' : ''}\n',
        );
        exportBytes += bytes.length;
        if (exportBytes > 100 * 1024 * 1024) {
          throw const ToolFailure('筛选导出超过100MiB，请缩小范围。');
        }
        await sink.writeFrom(bytes);
      } else {
        items.add({
          'line': row.line,
          'offset': row.nextOffset,
          'text': row.text,
          'level': rowLevel,
          'time': time,
          'truncated': row.truncated,
        });
        if (items.length >= 200) {
          more = nextOffset < before.size;
          break;
        }
      }
    }
    if (sink != null) await sink.flush();
  } finally {
    await sink?.close();
  }
  final after = await file.stat();
  if (after.size != before.size || after.modified != before.modified) {
    throw const ToolFailure('读取期间日志发生变化，请重新加载。');
  }
  return {
    'items': items,
    'nextOffset': nextOffset,
    'line': lastLine,
    'more': more,
    'matched': count,
    'size': before.size,
    'modified': before.modified.toUtc().toIso8601String(),
    'exportBytes': exportBytes,
  };
}

String redactLog(String text) => text
    .replaceAllMapped(
      RegExp(
        r'^(\s*(?:authorization|proxy-authorization|cookie|set-cookie)\s*[:=]).*$',
        caseSensitive: false,
        multiLine: true,
      ),
      (m) => '${m[1]} [REDACTED]',
    )
    .replaceAllMapped(
      RegExp(
        r'''("(?:password|passwd|token|access_token|refresh_token|secret|api[_-]?key|authorization|cookie)"\s*:\s*)"(?:[^"\\]|\\.)*"''',
        caseSensitive: false,
      ),
      (m) => '${m[1]}"[REDACTED]"',
    )
    .replaceAllMapped(
      RegExp(
        r'((?:password|passwd|token|secret|api[_-]?key)\s*[=:]\s*)[^\s&,;]+',
        caseSensitive: false,
      ),
      (m) => '${m[1]}[REDACTED]',
    );
