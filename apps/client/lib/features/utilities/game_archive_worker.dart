import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart' as arc;
import 'package:path/path.dart' as p;

import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../archive/archive_service.dart';

const maxGameBytes = 20 * 1024 * 1024 * 1024;
bool safeGameRelative(String name) =>
    name.isNotEmpty &&
    !name.contains('\\') &&
    !p.posix.isAbsolute(name) &&
    !p.windows.isAbsolute(name) &&
    name.split('/').every(validArchiveName) &&
    name.length < 30000;

/// A streaming ZIP worker, with cooperative cancellation at file/IO boundaries.
/// The UI truthfully shows CANCEL_REQUESTED until the current codec call ends.
Future<Map<String, dynamic>> runGameArchive(
  Map<String, dynamic> request,
  UtilityJobContext job,
) async {
  final receive = ReceivePort();
  SendPort? control;
  var cancelled = false;
  job.onCancel(() async {
    cancelled = true;
    control?.send('cancel');
  });
  final isolate = await Isolate.spawn(
    _gameArchiveWorker,
    {...request, 'reply': receive.sendPort},
    onExit: receive.sendPort,
    onError: receive.sendPort,
  );
  try {
    await for (final message in receive) {
      if (message is Map) {
        if (message['control'] is SendPort) {
          control = message['control'] as SendPort;
          if (cancelled) control.send('cancel');
        }
        if (message['progress'] is int && !job.cancellation.cancelled) {
          await job.progress(
            message['progress'] as int,
            message['total'] as int,
            currentFile: message['file'] as String,
          );
        }
        if (message['result'] is Map) {
          job.check();
          return Map<String, dynamic>.from(message['result'] as Map);
        }
        if (message['error'] is String) {
          job.check();
          throw ToolFailure(message['error'] as String);
        }
      } else if (message == null) {
        job.check();
        throw const ToolFailure('压缩工作线程中断；未提交成功备份。');
      } else if (message is List) {
        throw const ToolFailure('压缩工作线程异常；已有正式备份不受影响。');
      }
    }
    throw const ToolFailure('压缩工作线程结束但未返回结果。');
  } finally {
    receive.close();
    isolate.kill(priority: Isolate.immediate);
  }
}

Future<Map<String, dynamic>> _unpackGame(
  Map request,
  void Function() check,
  void Function(int, int, String) report,
) async {
  final input = arc.InputFileStream(request['archive'] as String);
  arc.Archive? archive;
  try {
    final central = arc.ZipDirectory()..read(input);
    final names = <String>{};
    var expanded = 0;
    if (central.fileHeaders.length > 100002) {
      throw const ToolFailure('备份条目超过100002项。');
    }
    for (final header in central.fileHeaders) {
      final raw = header.filename,
          name = raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
      if (!safeGameRelative(name) ||
          !(raw == 'manifest.json' ||
              raw == 'data/' ||
              raw.startsWith('data/')) ||
          !names.add(raw.toLowerCase()) ||
          ((header.externalFileAttributes >> 16) & 0xf000) == 0xa000 ||
          header.uncompressedSize < 0) {
        throw const ToolFailure('备份含越界、链接、重名或未知条目，拒绝恢复。');
      }
      expanded += header.uncompressedSize;
      if (expanded > maxGameBytes + 16 * 1024 * 1024) {
        throw const ToolFailure('展开数据超过20GiB上限。');
      }
      if (raw == 'manifest.json' &&
          header.uncompressedSize > 16 * 1024 * 1024) {
        throw const ToolFailure('备份清单过大。');
      }
    }
    input.reset();
    archive = arc.ZipDecoder().decodeStream(input);
    final manifestEntry = archive.find('manifest.json');
    if (manifestEntry == null || !manifestEntry.isFile) {
      throw const ToolFailure('缺少游戏备份清单。');
    }
    final manifest = jsonDecode(utf8.decode(manifestEntry.readBytes()!)) as Map;
    if (manifest['schemaVersion'] != 1 ||
        manifest['files'] is! List ||
        manifest['directories'] is! List) {
      throw const ToolFailure('备份清单版本无效。');
    }
    final files = List<Map<String, dynamic>>.from(
          (manifest['files'] as List).map(
            (e) => Map<String, dynamic>.from(e as Map),
          ),
        ),
        dirs = List<String>.from(manifest['directories'] as List);
    if (files.length > 50000 || dirs.length > 50000) {
      throw const ToolFailure('文件或目录数量超限。');
    }
    final expected = <String>{'manifest.json', 'data/'}, keys = <String>{};
    var total = 0;
    for (final dir in dirs) {
      if (!safeGameRelative(dir) || !keys.add('d:${dir.toLowerCase()}')) {
        throw const ToolFailure('清单目录无效。');
      }
      expected.add('data/$dir/');
    }
    for (final file in files) {
      final name = file['path'] as String, size = file['size'] as int;
      if (!safeGameRelative(name) ||
          !keys.add('f:${name.toLowerCase()}') ||
          size < 0 ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(file['sha256'] as String)) {
        throw const ToolFailure('清单文件无效。');
      }
      total += size;
      expected.add('data/$name');
      final entry = archive.find('data/$name');
      if (entry == null || !entry.isFile || entry.size != size) {
        throw const ToolFailure('备份文件大小或清单不一致。');
      }
    }
    if (total > maxGameBytes ||
        total != manifest['totalBytes'] ||
        !expected.containsAll(archive.map((e) => e.name)) ||
        archive.length != expected.length) {
      throw const ToolFailure('备份目录与清单不一致。');
    }
    final output = Directory(request['directory'] as String),
        restoring = request['mode'] == 'restore';
    if (restoring) {
      for (final dir in dirs) {
        check();
        await Directory(p.join(output.path, p.fromUri(Uri(path: dir))))
            .create(recursive: true);
      }
    }
    for (var i = 0; i < files.length; i++) {
      check();
      final file = files[i],
          relative = file['path'] as String,
          target = File(p.join(output.path, p.fromUri(Uri(path: relative))));
      if (!p.isWithin(output.path, p.normalize(target.path))) {
        throw const ToolFailure('恢复路径越界。');
      }
      await target.parent.create(recursive: true);
      if (archivePathKey(await target.parent.resolveSymbolicLinks()) !=
          archivePathKey(p.normalize(p.absolute(target.parent.path)))) {
        throw const ToolFailure('恢复父目录包含链接。');
      }
      await target.create(exclusive: true);
      final sink = arc.OutputFileStream(target.path);
      try {
        archive.find('data/$relative')!.writeContent(sink);
      } finally {
        sink.closeSync();
      }
      if (await target.length() != file['size'] ||
          await archiveHash(target, _WorkerCancellation(check)) !=
              file['sha256']) {
        throw const ToolFailure('恢复内容SHA256不匹配，未提交目标目录。');
      }
      if (restoring) {
        await target.setLastModified(
          DateTime.parse(file['modified'] as String),
        );
      } else {
        await target.delete();
      }
      report(
        (request['offset'] as int? ?? 0) + i + 1,
        (request['totalSteps'] as int? ?? files.length),
        '核验 $relative',
      );
      await Future<void>.delayed(Duration.zero);
    }
    return {
      'fileCount': files.length,
      'directoryCount': dirs.length,
      'totalBytes': total,
    };
  } finally {
    await archive?.clear();
    await input.close();
  }
}

class _WorkerCancellation extends TaskCancellation {
  _WorkerCancellation(this.callback);
  final void Function() callback;
  @override
  void check() => callback();
}

Future<void> _gameArchiveWorker(Map request) async {
  final reply = request['reply'] as SendPort, control = ReceivePort();
  var cancelled = false;
  control.listen((_) => cancelled = true);
  reply.send({'control': control.sendPort});
  void check() {
    if (cancelled) throw const ToolFailure('任务已取消；当前文件压缩结束后停止，未提交新备份。');
  }

  void report(int n, int total, String file) =>
      reply.send({'progress': n, 'total': total, 'file': file});
  try {
    Map<String, dynamic> result;
    if (request['mode'] == 'backup') {
      final files = List<Map<String, dynamic>>.from(
            (request['files'] as List).map(
              (v) => Map<String, dynamic>.from(v as Map),
            ),
          ),
          dirs = List<String>.from(request['directories'] as List),
          source = request['source'] as String;
      final manifest = <Map<String, dynamic>>[];
      var total = 0;
      final encoder = arc.ZipFileEncoder();
      encoder.create(request['archive'] as String, level: 6);
      try {
        encoder.addArchiveFile(arc.ArchiveFile.directory('data/'));
        for (final dir in dirs) {
          check();
          if (!safeGameRelative(dir)) throw const ToolFailure('目录名无效。');
          encoder.addArchiveFile(arc.ArchiveFile.directory('data/$dir/'));
        }
        for (var i = 0; i < files.length; i++) {
          check();
          final entry = files[i],
              relative = entry['path'] as String,
              file = File(p.join(source, p.fromUri(Uri(path: relative))));
          if (!safeGameRelative(relative) ||
              await FileSystemEntity.type(file.path, followLinks: false) !=
                  FileSystemEntityType.file) {
            throw const ToolFailure('源文件变化或变成链接。');
          }
          final before = await file.stat();
          if (before.size != entry['size'] ||
              before.modified.toUtc().toIso8601String() != entry['modified']) {
            throw const ToolFailure('预检后源存档变化，请关闭游戏并重新预检。');
          }
          final hash = await archiveHash(file, _WorkerCancellation(check));
          check();
          report(i, files.length * 2, '压缩 $relative');
          await encoder.addFile(file, 'data/$relative');
          final after = await file.stat();
          if (after.size != before.size ||
              after.modified != before.modified ||
              await archiveHash(file, _WorkerCancellation(check)) != hash) {
            throw const ToolFailure('压缩期间存档发生变化，未提交备份。');
          }
          total += before.size;
          if (total > maxGameBytes) throw const ToolFailure('本版完整备份最多20GiB。');
          manifest.add({...entry, 'sha256': hash});
          report(i + 1, files.length * 2, '已压缩 $relative');
          await Future<void>.delayed(Duration.zero);
        }
        encoder.addArchiveFile(
          arc.ArchiveFile.string(
            'manifest.json',
            jsonEncode({
              'schemaVersion': 1,
              'createdAt': DateTime.now().toUtc().toIso8601String(),
              'files': manifest,
              'directories': dirs,
              'totalBytes': total,
            }),
          ),
        );
      } finally {
        await encoder.close();
      }
      check();
      result = await _unpackGame(
        {...request, 'offset': files.length, 'totalSteps': files.length * 2},
        check,
        report,
      );
      for (final entry in files) {
        check();
        final stat = await File(
          p.join(source, p.fromUri(Uri(path: entry['path'] as String))),
        ).stat();
        if (stat.size != entry['size'] ||
            stat.modified.toUtc().toIso8601String() != entry['modified']) {
          throw const ToolFailure('备份结束前源目录变化，请关闭游戏后重试。');
        }
      }
      result['sha256'] = await archiveHash(
        File(request['archive'] as String),
        _WorkerCancellation(check),
      );
    } else {
      result = await _unpackGame(request, check, report);
    }
    check();
    reply.send({'result': result});
  } catch (error) {
    reply.send({
      'error': error is ToolFailure
          ? error.message
          : '压缩、校验或文件访问失败：${error.runtimeType}',
    });
  } finally {
    control.close();
  }
}
