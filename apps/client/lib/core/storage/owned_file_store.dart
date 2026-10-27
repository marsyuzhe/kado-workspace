import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../data/tool_record.dart';
import 'data_mutation_gate.dart';

class OwnedFileStore {
  OwnedFileStore(this.root);
  final Directory root;
  File resolve(String relative) {
    if (p.isAbsolute(relative) ||
        relative.split(RegExp(r'[/\\]')).contains('..')) {
      throw const ToolFailure('无效的附件路径。');
    }
    final absolute = p.normalize(p.join(root.path, relative));
    final allowed = p.join(root.path, 'attachments');
    if (!p.isWithin(allowed, absolute)) throw const ToolFailure('附件不在应用受控目录内。');
    return File(absolute);
  }

  /// 写入/删除前逐层检查真实父目录，拒绝附件目录被junction移到应用根外。
  /// resolve保持同步轻量；卡片渲染不会因这项检查发起磁盘遍历。
  Future<bool> _guardParents(File file, {required bool create}) async {
    if (!await root.exists()) {
      if (!create) return false;
      await root.create(recursive: true);
    }
    final canonicalRoot = await root.resolveSymbolicLinks();
    var logical = root.path, expected = canonicalRoot;
    for (final part in p.split(p.relative(file.parent.path, from: root.path))) {
      logical = p.join(logical, part);
      expected = p.join(expected, part);
      final directory = Directory(logical);
      if (!await directory.exists()) {
        if (!create) return false;
        await directory.create();
      }
      if (!p.equals(
        p.normalize(await directory.resolveSymbolicLinks()),
        p.normalize(expected),
      )) {
        throw const ToolFailure('附件目录包含链接或重定向，未写入或删除文件。');
      }
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const ToolFailure('附件文件不能是链接。');
    }
    return true;
  }

  Future<String> write(
    String namespace,
    Uint8List bytes, {
    String extension = 'bin',
  }) => DataMutationGate.shared.run(() async {
    if (!RegExp(r'^[a-z_]+$').hasMatch(namespace) ||
        !RegExp(r'^[a-z0-9]+$').hasMatch(extension)) {
      throw const ToolFailure('附件类型无效。');
    }
    final relative = p.join('attachments', namespace, '${newId()}.$extension');
    final file = resolve(relative);
    await _guardParents(file, create: true);
    await file.create(exclusive: true);
    try {
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
    return relative;
  });

  Future<void> remove(String relative) => DataMutationGate.shared.run(() async {
    final file = resolve(relative);
    if (!await _guardParents(file, create: false)) return;
    if (await file.exists()) await file.delete();
  });
}
