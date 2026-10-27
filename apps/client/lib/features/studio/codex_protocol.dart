import '../../app/brand_config.dart';
import 'dart:async';
import 'dart:convert';

import '../../core/data/tool_record.dart';
import '../../app/version.dart';

/// JSONL framing is bounded before decoding. A noisy or malformed child process
/// cannot accumulate an unlimited pending line or resolve an unrelated request.
class CodexJsonLines {
  static const maxLineBytes = 1024 * 1024;
  final List<int> _pending = [];
  List<Map<String, dynamic>> add(List<int> bytes) {
    final result = <Map<String, dynamic>>[];
    for (final byte in bytes) {
      if (byte == 10) {
        if (_pending.isNotEmpty) {
          try {
            final value = jsonDecode(utf8.decode(_pending));
            if (value is! Map<String, dynamic>) throw const FormatException();
            result.add(value);
          } catch (_) {
            throw const ToolFailure('Codex返回了无效JSONL消息。');
          } finally {
            _pending.clear();
          }
        }
      } else {
        _pending.add(byte);
        if (_pending.length > maxLineBytes) {
          throw const ToolFailure('Codex单条消息超过1MB上限。');
        }
      }
    }
    return result;
  }

  void finish() {
    if (_pending.isNotEmpty) throw const ToolFailure('Codex进程在消息完成前退出，结果不完整。');
  }
}

String redactCodexText(String value) {
  var result = value.replaceAll(
    RegExp(r'\b(?:sk-|sess-)[A-Za-z0-9_\-]{8,}'),
    '[REDACTED]',
  );
  result = result.replaceAllMapped(
    RegExp(r'(Bearer\s+)[^\s"\x27,}]+', caseSensitive: false),
    (m) => '${m[1]}[REDACTED]',
  );
  result = result.replaceAllMapped(
    RegExp(
      r'((?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret)\s*[=:]\s*)[^\s,;]+',
      caseSensitive: false,
    ),
    (m) => '${m[1]}[REDACTED]',
  );
  result = result.replaceAll(
    RegExp(
      r'-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----',
    ),
    '[REDACTED PRIVATE KEY]',
  );
  return result.length > 8192
      ? '${result.substring(0, 8192)}…[truncated]'
      : result;
}

dynamic redactCodexValue(dynamic value, [int depth = 0]) {
  if (depth > 8) return '[truncated]';
  if (value is String) return redactCodexText(value);
  if (value is List) {
    return value.take(64).map((v) => redactCodexValue(v, depth + 1)).toList();
  }
  if (value is Map) {
    return {
      for (final e in value.entries.take(100))
        '${e.key}':
            RegExp(
              r'key|token|password|secret|email|authorization',
              caseSensitive: false,
            ).hasMatch('${e.key}')
            ? '[REDACTED]'
            : redactCodexValue(e.value, depth + 1),
    };
  }
  return value;
}

/// Protocol connection only. The client never guesses success from prose or
/// grants server-initiated approvals. Unknown requests receive a JSON-RPC error.
class CodexRpcClient {
  CodexRpcClient({
    required Stream<List<int>> stdout,
    required this.send,
    required this.closeOwnedProcess,
    this.requestTimeout = const Duration(seconds: 15),
  }) {
    _subscription = stdout.listen(
      _receive,
      onError: (_) => _fail(const ToolFailure('Codex输出流失败。')),
      onDone: () {
        try {
          _decoder.finish();
        } catch (error) {
          _fail(error);
          return;
        }
        _fail(const ToolFailure('Codex进程已退出，未完成请求已中断。'));
      },
    );
  }
  final void Function(String jsonLine) send;
  final Future<void> Function() closeOwnedProcess;
  final Duration requestTimeout;
  final _decoder = CodexJsonLines();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  late final StreamSubscription<List<int>> _subscription;
  int _nextId = 1;
  bool _closed = false;
  Future<void>? _closing;
  Future<void> _close() => _closing ??= closeOwnedProcess();
  Stream<Map<String, dynamic>> get events => _events.stream;
  void _write(Map<String, dynamic> message) {
    if (_closed) throw const ToolFailure('Codex连接已关闭。');
    // The app-server wire protocol intentionally omits the jsonrpc header.
    send('${jsonEncode(message)}\n');
  }

  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params,
  ) async {
    final id = _nextId++, completer = Completer<Map<String, dynamic>>();
    if (_closed) throw const ToolFailure('Codex连接已关闭。');
    _pending[id] = completer;
    try {
      _write({'id': id, 'method': method, 'params': params});
      return await completer.future.timeout(
        requestTimeout,
        onTimeout: () => throw const ToolFailure('Codex协议请求超时。'),
      );
    } finally {
      _pending.remove(id);
    }
  }

  Future<Map<String, dynamic>> initialize() async {
    final response = await request('initialize', {
      'clientInfo': {
        'name': 'links_toolbox',
        'title': AppBrandConfig.displayName,
        'version': appVersion,
      },
    });
    _write({'method': 'initialized', 'params': {}});
    return response;
  }

  void _receive(List<int> bytes) {
    if (_closed) return;
    try {
      for (final message in _decoder.add(bytes)) {
        final id = message['id'];
        if (message['method'] is String) {
          if (id != null) {
            // Diagnostics has no approval surface; every request is denied.
            // No acceptForSession or automatic approval fallback exists.
            _write({
              'id': id,
              'error': {
                'code': -32601,
                'message': 'This client has not authorized server requests.',
              },
            });
          }
          _events.add(
            Map<String, dynamic>.from(redactCodexValue(message) as Map),
          );
        } else if (id is int) {
          final pending = _pending.remove(id);
          if (pending == null) continue;
          if (message.containsKey('error')) {
            pending.completeError(const ToolFailure('Codex拒绝了协议请求；请检查版本和权限。'));
          } else if (message['result'] case final Map result) {
            pending.complete(Map<String, dynamic>.from(result));
          } else {
            pending.completeError(const ToolFailure('Codex响应结构无效。'));
          }
        }
      }
    } catch (error) {
      _fail(error);
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pending.clear();
    unawaited(_close());
  }

  Future<void> dispose() async {
    _fail(const ToolFailure('用户已关闭Codex连接。'));
    await _subscription.cancel();
    await _close();
    await _events.close();
  }
}
