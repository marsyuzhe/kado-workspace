import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/data/tool_record.dart';

class DevCancellation {
  bool cancelled = false;
  void cancel() => cancelled = true;
  void check() {
    if (cancelled) throw const ToolFailure('处理已取消。');
  }
}

class _HashSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest data) => digest = data;
  @override
  void close() {}
}

class FileHashes {
  const FileHashes(this.path, this.size, this.sha256, this.sha512);
  final String path, sha256, sha512;
  final int size;
  bool matches(String expected) =>
      {sha256, sha512}.contains(expected.trim().toLowerCase());
}

/// Stream bounded chunks and yield between them. Never load a whole file.
/// Detect a changing file instead of publishing a checksum as a stable result.
Future<FileHashes> hashFile(
  File file,
  DevCancellation cancel, {
  void Function(int, int)? progress,
}) async {
  final before = await file.stat();
  if (before.type != FileSystemEntityType.file) {
    throw const ToolFailure('请选择普通文件。');
  }
  final s256 = _HashSink(), s512 = _HashSink();
  final c256 = sha256.startChunkedConversion(s256),
      c512 = sha512.startChunkedConversion(s512);
  var bytes = 0;
  final clock = Stopwatch()..start();
  var last = 0;
  try {
    await for (final chunk in file.openRead()) {
      cancel.check();
      c256.add(chunk);
      c512.add(chunk);
      bytes += chunk.length;
      if (clock.elapsedMilliseconds - last > 100) {
        progress?.call(bytes, before.size);
        last = clock.elapsedMilliseconds;
      }
    }
    cancel.check();
  } finally {
    c256.close();
    c512.close();
  }
  final after = await file.stat();
  if (bytes != before.size ||
      after.size != before.size ||
      after.modified != before.modified) {
    throw const ToolFailure('计算期间文件发生变化，请重新校验。');
  }
  progress?.call(bytes, bytes);
  return FileHashes(
    file.path,
    bytes,
    s256.digest.toString(),
    s512.digest.toString(),
  );
}
