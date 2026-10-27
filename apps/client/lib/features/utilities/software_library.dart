import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/platform/system_actions.dart';
import '../archive/archive_service.dart';

class SoftwareLibraryService {
  SoftwareLibraryService(this.store, this.native);
  final RecordStore store;
  final NativePlatformAdapter native;
  static const extensions = {
    'exe',
    'msi',
    'zip',
    '7z',
    'msix',
    'msixbundle',
    'apk',
    'dmg',
    'pkg',
  };
  Future<File> selected(String path) async {
    if (!p.isAbsolute(path) ||
        !extensions.contains(
          p.extension(path).replaceFirst('.', '').toLowerCase(),
        ) ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const ToolFailure('请选择有效安装包文件，不接受链接。');
    }
    final file = File(path);
    if (await file.length() == 0 ||
        archivePathKey(await file.resolveSymbolicLinks()) !=
            archivePathKey(p.normalize(path))) {
      throw const ToolFailure('安装包为空或包含链接路径。');
    }
    return file;
  }

  Future<List<ToolRecord>> importPaths(
    List<String> paths,
    UtilityJobContext job,
  ) async {
    if (paths.isEmpty || paths.length > 100) {
      throw const ToolFailure('单次导入1–100个安装包。');
    }
    final rows = <ToolRecord>[];
    for (var i = 0; i < paths.length; i++) {
      job.check();
      final file = await selected(paths[i]),
          before = await File(paths[i]).stat();
      await job.progress(
        i,
        paths.length,
        currentFile: p.basename(file.path),
        force: true,
      );
      final checksum = await archiveHash(file, job.cancellation),
          key = '${archivePathKey(file.path)}:$checksum',
          existing = await store.find('software_package', 'packageKey', key);
      if (existing != null) {
        await job.output(existing.id);
        rows.add(existing);
        await job.progress(i + 1, paths.length, force: true);
        continue;
      }
      Map<String, dynamic> metadata;
      try {
        metadata = await native.installerMetadata(file.path);
      } on ToolFailure catch (error) {
        metadata = {'source': error.message, 'signatureStatus': 'unverified'};
      }
      final after = await file.stat();
      if (after.size != before.size || after.modified != before.modified) {
        throw const ToolFailure('校验期间安装包变化，请重新导入。');
      }
      final name =
          metadata['name'] is String &&
              (metadata['name'] as String).trim().isNotEmpty
          ? metadata['name'] as String
          : p.basenameWithoutExtension(file.path);
      final row = await store.create(
        'software_package',
        name,
        data: {
          'payloadVersion': 1,
          'packageKey': key,
          'installerPath': file.path,
          'installerType': p
              .extension(file.path)
              .replaceFirst('.', '')
              .toLowerCase(),
          'fileSize': before.size,
          'modified': before.modified.toUtc().toIso8601String(),
          'sha256': checksum,
          'version': metadata['version'] ?? '',
          'publisher': metadata['publisher'] ?? '',
          'signatureStatus': metadata['signatureStatus'] ?? 'unverified',
          'signatureCode': metadata['signatureCode'],
          'metadataSource': metadata['source'] ?? '',
          'lastExists': true,
          'checksumMatches': true,
          'lastVerifiedAt': DateTime.now().toUtc().toIso8601String(),
          'officialUrl': '',
          'category': '未分类',
          'favorite': false,
          'syncAllowed': false,
          'isSensitive': true,
        },
      );
      rows.add(row);
      await job.output(row.id);
      await job.progress(i + 1, paths.length, currentFile: name, force: true);
    }
    return rows;
  }

  Future<ToolRecord> edit(
    ToolRecord row, {
    required String name,
    required String version,
    required String publisher,
    required String category,
    required String officialUrl,
    required String notes,
    required bool favorite,
  }) async {
    if (row.kind != 'software_package' ||
        name.trim().isEmpty ||
        name.length > 300 ||
        version.length > 100 ||
        publisher.length > 200 ||
        category.length > 100 ||
        notes.length > 20000) {
      throw const ToolFailure('安装包信息过长或名称为空。');
    }
    if (officialUrl.isNotEmpty) TargetAction('url', officialUrl).validate();
    return store.save(
      row.copyWith(
        title: name,
        body: notes,
        data: {
          ...row.data,
          'version': version,
          'publisher': publisher,
          'category': category,
          'officialUrl': officialUrl,
          'favorite': favorite,
          'metadataEdited': true,
        },
      ),
    );
  }

  Future<ToolRecord> verify(String id, UtilityJobContext job) async {
    final row = await store.get(id);
    if (row?.kind != 'software_package') throw const ToolFailure('安装包记录已不存在。');
    var exists = false, matches = false;
    String error = '';
    try {
      final file = await selected(row!.text('installerPath'));
      exists = true;
      await job.progress(0, 1, currentFile: '核对${row.title}', force: true);
      matches =
          await file.length() == row.number('fileSize') &&
          await archiveHash(file, job.cancellation) == row.text('sha256');
    } on ToolFailure catch (e) {
      job.check();
      error = e.message;
    }
    final updated = await store.save(
      row!.copyWith(
        data: {
          ...row.data,
          'lastExists': exists,
          'checksumMatches': matches,
          'verificationError': error,
          'lastVerifiedAt': DateTime.now().toUtc().toIso8601String(),
        },
      ),
    );
    await job.output(updated.id);
    await job.progress(1, 1, force: true);
    if (!matches) throw const ToolFailure('安装包缺失或内容与登记SHA256不一致，不能从此记录启动。');
    return updated;
  }
}
