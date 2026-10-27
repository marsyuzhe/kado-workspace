import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../data/record_store.dart';
import '../data/tool_record.dart';
import 'owned_file_store.dart';
import '../../features/archive/archive_service.dart';

/// Shared selected-file intake and exclusive output boundary. No scan, model
/// or document is read until a user-supplied reference is handed to a service.
class UtilityFileService {
  UtilityFileService(this.store, this.files, {this.availableBytes});
  final RecordStore store;
  final Future<OwnedFileStore> Function() files;
  final Future<int?> Function(String)? availableBytes;
  Future<void> ensureSpace(String directory, int required) async {
    final free = await availableBytes?.call(directory);
    if (free != null && free < required + 4 * 1024 * 1024) {
      throw const ToolFailure('输出磁盘剩余空间不足；尚未创建输出。');
    }
  }

  Future<ToolRecord> importBytes(
    String name,
    Uint8List bytes, {
    int limit = 25 * 1024 * 1024,
  }) async {
    if (bytes.isEmpty ||
        bytes.length > limit ||
        !validArchiveName(p.basename(name))) {
      throw const ToolFailure('输入文件为空、过大或名称无效。');
    }
    final owned = await files(),
        ref = await (await files()).write(
          'utility_inputs',
          bytes,
          extension: 'bin',
        );
    try {
      return await store.create(
        'utility_input',
        p.basename(name),
        data: {
          'payloadVersion': 1,
          'attachment': ref,
          'size': bytes.length,
          'checksum': sha256.convert(bytes).toString(),
          'isSensitive': true,
          'syncAllowed': false,
        },
      );
    } catch (_) {
      await owned.remove(ref);
      rethrow;
    }
  }

  Future<File> input(String id) async {
    final row = await store.get(id);
    if (row?.kind != 'utility_input') {
      throw const ToolFailure('请选择仍然存在的授权输入文件。');
    }
    final file = (await files()).resolve(row!.text('attachment'));
    if (!await file.exists() || await file.length() != row.number('size')) {
      throw const ToolFailure('输入副本缺失或大小已变化。');
    }
    return file;
  }

  Future<Directory> selectedDirectory(String path) async {
    if (!p.isAbsolute(path) ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const ToolFailure('请选择有效输出目录，不接受链接。');
    }
    final dir = Directory(p.normalize(path));
    if (!p.equals(p.normalize(await dir.resolveSymbolicLinks()), dir.path)) {
      throw const ToolFailure('输出目录包含链接或重定向，请选择实际目录。');
    }
    return dir;
  }

  Future<File> exportBytes(
    String directory,
    String name,
    Uint8List bytes,
    TaskCancellation cancel,
  ) async {
    cancel.check();
    final dir = await selectedDirectory(directory);
    if (!validArchiveName(name) || p.basename(name) != name) {
      throw const ToolFailure('输出文件名无效。');
    }
    final target = File(p.join(dir.path, name));
    await ensureSpace(dir.path, bytes.length);
    await target.create(exclusive: true);
    var completed = false;
    try {
      cancel.check();
      await target.writeAsBytes(bytes, flush: true);
      cancel.check();
      if ((await sha256.bind(target.openRead()).first).toString() !=
          sha256.convert(bytes).toString()) {
        throw const ToolFailure('输出文件校验失败。');
      }
      completed = true;
      return target;
    } finally {
      if (!completed && await target.exists()) await target.delete();
    }
  }

  Future<File> exportFile(
    String directory,
    String name,
    File source,
    TaskCancellation cancel,
  ) async {
    cancel.check();
    final dir = await selectedDirectory(directory);
    if (!validArchiveName(name) || p.basename(name) != name) {
      throw const ToolFailure('输出名称无效。');
    }
    final target = File(p.join(dir.path, name));
    await ensureSpace(dir.path, await source.length());
    await target.create(exclusive: true);
    var completed = false;
    try {
      final out = await target.open(mode: FileMode.writeOnly);
      try {
        await for (final chunk in source.openRead()) {
          cancel.check();
          await out.writeFrom(chunk);
        }
        await out.flush();
      } finally {
        await out.close();
      }
      cancel.check();
      if (await archiveHash(source, cancel) !=
          await archiveHash(target, cancel)) {
        throw const ToolFailure('输出校验失败。');
      }
      completed = true;
      return target;
    } finally {
      if (!completed && await target.exists()) await target.delete();
    }
  }
}
