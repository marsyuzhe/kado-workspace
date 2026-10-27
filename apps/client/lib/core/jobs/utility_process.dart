import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../data/tool_record.dart';
import 'utility_jobs.dart';

class UtilityProcessResult {
  const UtilityProcessResult(this.code, this.stdout, this.stderr);
  final int code;
  final String stdout, stderr;
}

/// Owns only this exact Process handle. Callers supply a verified executable
/// and fixed argument grammar, never arbitrary shell text.
Future<UtilityProcessResult> runUtilityProcess(
  String executable,
  List<String> arguments,
  UtilityJobContext job, {
  Future<void> Function(String line, bool error)? onLine,
  Duration timeout = const Duration(hours: 4),
}) async {
  job.check();
  final process = await Process.start(executable, arguments, runInShell: false);
  var exited = false, timedOut = false, overflow = false, bytes = 0;
  final timer = Timer(timeout, () {
    timedOut = true;
    process.kill();
  });
  job.onCancel(() async {
    if (!exited) process.kill();
  });
  final events = StreamController<(String, bool)>();
  var readers = 2;
  StreamSubscription<String> listen(Stream<List<int>> source, bool error) =>
      source
          .map((chunk) {
            bytes += chunk.length;
            if (bytes > 8 * 1024 * 1024) {
              overflow = true;
              process.kill();
              return <int>[];
            }
            return chunk;
          })
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
            (line) => events.add((line, error)),
            onError: (Object error, StackTrace trace) {
              events.addError(error, trace);
              process.kill();
            },
            onDone: () {
              if (--readers == 0) events.close();
            },
          );
  final stdout = listen(process.stdout, false),
      stderr = listen(process.stderr, true);
  var out = '', err = '';
  try {
    job.check();
    await for (final event in events.stream) {
      job.check();
      if (event.$2) {
        err += '${event.$1}\n';
        if (err.length > 32000) err = err.substring(err.length - 32000);
      } else {
        out += '${event.$1}\n';
        if (out.length > 32000) out = out.substring(out.length - 32000);
      }
      await onLine?.call(event.$1, event.$2);
    }
    final code = await process.exitCode;
    exited = true;
    job.check();
    if (timedOut || overflow) throw const ToolFailure('本地执行器超时或诊断输出超限，已停止本任务。');
    return UtilityProcessResult(code, out, err);
  } finally {
    timer.cancel();
    if (!exited) {
      process.kill();
      await process.exitCode;
      exited = true;
    }
    await stdout.cancel();
    await stderr.cancel();
    if (!events.isClosed) unawaited(events.close());
  }
}
