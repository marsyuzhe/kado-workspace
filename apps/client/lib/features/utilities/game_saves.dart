import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/platform/system_actions.dart';
import '../../core/storage/utility_files.dart';
import '../archive/archive_service.dart';
import 'game_archive_worker.dart';

class GameBackupPlan {
  const GameBackupPlan(this.profile, this.scan);
  final ToolRecord profile;
  final ScanResult scan;
}

class GameSaveService {
  GameSaveService(
    this.store,
    this.files,
    this.native, {
    Future<void> Function(String, String)? mover,
  }) : move = mover ?? native.moveFileExclusive;
  final RecordStore store;
  final UtilityFileService files;
  final NativePlatformAdapter native;
  final Future<void> Function(String, String) move;
  Future<ToolRecord> save(
    String name,
    String platform,
    String source,
    String backup, {
    int keep = 5,
    ToolRecord? existing,
  }) async {
    if (name.trim().isEmpty ||
        name.length > 100 ||
        platform.length > 100 ||
        keep < 1 ||
        keep > 100 ||
        existing != null && existing.kind != 'game_profile') {
      throw const ToolFailure('游戏名称、平台或保留数无效。');
    }
    final src = await files.selectedDirectory(source),
        dest = await files.selectedDirectory(backup);
    if (p.equals(src.path, dest.path) || p.isWithin(src.path, dest.path)) {
      throw const ToolFailure('备份目录不能位于源存档之内。');
    }
    final data = {
      ...existing?.data ?? {},
      'payloadVersion': 1,
      'platform': platform,
      'sourceDirectory': src.path,
      'backupDirectory': dest.path,
      'strategy': 'full-manual',
      'keepCount': keep,
      'syncAllowed': false,
      'isSensitive': true,
    };
    return existing == null
        ? store.create('game_profile', name, data: data)
        : store.save(existing.copyWith(title: name, data: data));
  }

  Future<GameBackupPlan> plan(
    ToolRecord profile,
    TaskCancellation cancel,
  ) async {
    if (profile.kind != 'game_profile') throw const ToolFailure('游戏实例无效。');
    await files.selectedDirectory(profile.text('sourceDirectory'));
    await files.selectedDirectory(profile.text('backupDirectory'));
    final scan = await ArchiveScanner().scan(
      profile.text('sourceDirectory'),
      cancel,
    );
    cancel.check();
    if (scan.errors.isNotEmpty ||
        scan.limited ||
        scan.files.isEmpty ||
        scan.bytes > maxGameBytes) {
      throw const ToolFailure('源目录为空、不可读、超出文件/目录上限或20GiB，请改选较小实例。');
    }
    await files.ensureSpace(
      profile.text('backupDirectory'),
      scan.bytes * 2 + 32 * 1024 * 1024,
    );
    return GameBackupPlan(profile, scan);
  }

  Future<void> removeProfile(ToolRecord row, {required bool confirmed}) async {
    if (!confirmed || row.kind != 'game_profile') {
      throw const ToolFailure('移除实例需要确认。');
    }
    for (final job in await store.list('utility_job', limit: 10000)) {
      if (!utilityJobStatus(job).terminal &&
          (job.data['inputReferences'] as Map?)?['profileId'] == row.id) {
        throw const ToolFailure('请先等待或取消此实例的备份任务。');
      }
    }
    await store.delete(
      row,
    ); // Metadata only. Preserve all source and backup files.
  }

  Future<void> _cleanup(String root, Directory dir, String expected) async {
    if (p.basename(dir.path) != expected ||
        !p.isWithin(root, p.normalize(p.absolute(dir.path)))) {
      throw const ToolFailure('临时目录边界校验失败，未删除。');
    }
    if (await FileSystemEntity.type(dir.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    if (await FileSystemEntity.type(dir.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        archivePathKey(await dir.resolveSymbolicLinks()) !=
            archivePathKey(p.normalize(p.absolute(dir.path)))) {
      throw const ToolFailure('临时目录变成链接，未清理。');
    }
    await dir.delete(recursive: true);
  }

  Future<ToolRecord> backup(
    GameBackupPlan plan,
    String note,
    UtilityJobContext job,
  ) async {
    if (note.length > 4000) throw const ToolFailure('版本备注最多4000字符。');
    final profile = plan.profile, current = await store.get(profile.id);
    if (current?.kind != 'game_profile' ||
        current!.text('sourceDirectory') != profile.text('sourceDirectory') ||
        current.text('backupDirectory') != profile.text('backupDirectory')) {
      throw const ToolFailure('游戏实例路径变化，请重新预检。');
    }
    final root = await files.selectedDirectory(profile.text('backupDirectory')),
        source = profile.text('sourceDirectory'),
        id = newId(),
        name = 'links-game-${profile.id}-$id.zip';
    final partial = File(p.join(root.path, '$name.part')),
        target = File(p.join(root.path, name)),
        verify = Directory(p.join(root.path, '.links-verify-${job.id}'));
    await files.ensureSpace(root.path, plan.scan.bytes * 2 + 32 * 1024 * 1024);
    if (await FileSystemEntity.type(partial.path, followLinks: false) !=
            FileSystemEntityType.notFound ||
        await FileSystemEntity.type(target.path, followLinks: false) !=
            FileSystemEntityType.notFound ||
        await FileSystemEntity.type(verify.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const ToolFailure('输出或临时位置已存在，未覆盖。');
    }
    await verify.create();
    var row = await store.create(
      'game_backup',
      '${profile.title}完整备份',
      body: note,
      data: {
        'payloadVersion': 1,
        'profileId': profile.id,
        'backupRoot': root.path,
        'fileName': name,
        'partialName': '$name.part',
        'status': 'processing',
        'sourceDirectory': source,
        'fileCount': plan.scan.files.length,
        'totalBytes': plan.scan.bytes,
        'jobId': job.id,
        'syncAllowed': false,
        'isSensitive': true,
      },
    );
    var committed = false;
    try {
      await job.output(row.id);
      final result = await runGameArchive({
        'mode': 'backup',
        'archive': partial.path,
        'directory': verify.path,
        'source': source,
        'files': [
          for (final f in plan.scan.files)
            {
              'path': p.posix.fromUri(
                p.toUri(p.relative(f.path, from: source)),
              ),
              'size': f.size,
              'modified': f.modified.toUtc().toIso8601String(),
            },
        ],
        'directories': plan.scan.directories
            .map((d) => p.posix.fromUri(p.toUri(p.relative(d, from: source))))
            .toList(),
      }, job);
      job.check();
      final finalScan = await ArchiveScanner().scan(source, job.cancellation);
      job.check();
      final expectedFiles = {
        for (final f in plan.scan.files) archivePathKey(f.path): f,
      };
      if (finalScan.errors.isNotEmpty ||
          finalScan.limited ||
          finalScan.files.length != expectedFiles.length ||
          finalScan.directories.length != plan.scan.directories.length ||
          !finalScan.directories
              .map(archivePathKey)
              .toSet()
              .containsAll(plan.scan.directories.map(archivePathKey)) ||
          finalScan.files.any(
            (f) =>
                expectedFiles[archivePathKey(f.path)]?.size != f.size ||
                expectedFiles[archivePathKey(f.path)]?.modified != f.modified,
          )) {
        throw const ToolFailure('压缩后源目录内容变化，未提交备份。');
      }
      // Persist verified fingerprints before the atomic rename. Recovery can
      // validate a committed file even if the following DB write is interrupted.
      row = await store.save(
        row.copyWith(
          data: {
            ...row.data,
            ...result,
            'size': await partial.length(),
            'status': 'committing',
          },
        ),
      );
      job.check();
      await move(partial.path, target.path);
      committed = true;
      row = await store.save(
        row.copyWith(
          data: {
            ...row.data,
            ...result,
            'size': await target.length(),
            'status': 'complete',
            'completedAt': DateTime.now().toUtc().toIso8601String(),
            'partialName': '',
          },
        ),
      );
      final latest = await store.get(profile.id);
      if (latest != null && latest.kind == 'game_profile') {
        try {
          await store.save(
            latest.copyWith(
              data: {
                ...latest.data,
                'lastBackupAt': DateTime.now().toUtc().toIso8601String(),
              },
            ),
          );
        } on RecordConflict {
          /* Version record is authoritative. */
        }
      }
      return row;
    } catch (error) {
      row = await store.save(
        row.copyWith(
          data: {
            ...row.data,
            'status': committed
                ? 'committed-needs-review'
                : job.cancellation.cancelled
                ? 'cancelled'
                : 'failed',
            'error': error is ToolFailure
                ? error.message
                : '压缩、校验或写入失败；未修改源存档。',
          },
        ),
      );
      rethrow;
    } finally {
      if (await partial.exists()) await partial.delete();
      await _cleanup(root.path, verify, '.links-verify-${job.id}');
    }
  }

  Future<File> requireBackup(ToolRecord row, TaskCancellation cancel) async {
    if (row.kind != 'game_backup' ||
        !{
          'complete',
          'committing',
          'committed-needs-review',
          'interrupted',
        }.contains(row.text('status')) ||
        !RegExp(r'^links-game-[a-f0-9-]{36}-[a-f0-9-]{36}\.zip$')
            .hasMatch(row.text('fileName'))) {
      throw const ToolFailure('请选择已完整提交的备份。');
    }
    final root = await files.selectedDirectory(row.text('backupRoot')),
        file = File(p.join(row.text('backupRoot'), row.text('fileName')));
    if (!p.isWithin(root.path, file.path) ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() != row.number('size') ||
        await archiveHash(file, cancel) != row.text('sha256')) {
      throw const ToolFailure('备份文件缺失、变化或哈希不匹配。');
    }
    return file;
  }

  Future<ToolRecord> restore(
    ToolRecord backup,
    String parent,
    String directoryName,
    UtilityJobContext job,
  ) async {
    if (!validArchiveName(directoryName) ||
        !directoryName.startsWith('Links-restored-')) {
      throw const ToolFailure('恢复目录名无效。');
    }
    final zip = await requireBackup(backup, job.cancellation),
        destination = await files.selectedDirectory(parent),
        target = Directory(p.join(parent, directoryName)),
        work = Directory(p.join(parent, '.links-restore-${job.id}'));
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
            FileSystemEntityType.notFound ||
        await FileSystemEntity.type(work.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const ToolFailure('恢复目标已存在，禁止覆盖；请选择新的目录。');
    }
    await files.ensureSpace(
      destination.path,
      backup.number('totalBytes') + 32 * 1024 * 1024,
    );
    await work.create();
    var row = await store.create(
      'game_restore',
      '恢复${backup.title}',
      data: {
        'backupId': backup.id,
        'outputDirectory': target.path,
        'status': 'processing',
        'jobId': job.id,
        'syncAllowed': false,
        'isSensitive': true,
      },
    );
    var committed = false;
    try {
      await job.output(row.id);
      final result = await runGameArchive({
        'mode': 'restore',
        'archive': zip.path,
        'directory': work.path,
      }, job);
      job.check();
      await move(work.path, target.path);
      committed = true;
      return await store.save(
        row.copyWith(data: {...row.data, ...result, 'status': 'complete'}),
      );
    } catch (error) {
      await store.save(
        row.copyWith(
          data: {
            ...row.data,
            'status': committed
                ? 'committed-needs-review'
                : job.cancellation.cancelled
                ? 'cancelled'
                : 'failed',
            'error': error is ToolFailure
                ? error.message
                : '恢复失败；源存档和正式备份保持不变。',
          },
        ),
      );
      rethrow;
    } finally {
      if (!committed) {
        await _cleanup(destination.path, work, '.links-restore-${job.id}');
      }
    }
  }

  Future<List<ToolRecord>> retentionPreview(ToolRecord profile) async {
    final versions =
        (await store.list('game_backup', limit: 10000))
            .where(
              (r) =>
                  r.text('profileId') == profile.id &&
                  r.text('status') == 'complete',
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return versions.skip(profile.number('keepCount', 5)).toList();
  }

  Future<void> deleteBackups(
    List<String> ids,
    UtilityJobContext job, {
    required bool confirmed,
  }) async {
    if (!confirmed || ids.length > 100) {
      throw const ToolFailure('清理备份需要确认，单次最多100个版本。');
    }
    for (var i = 0; i < ids.length; i++) {
      job.check();
      final row = await store.get(ids[i]);
      if (row == null) throw const ToolFailure('备份记录已不存在。');
      final file = await requireBackup(row, job.cancellation);
      job.check();
      await file.delete();
      await store.save(
        row.copyWith(
          data: {
            ...row.data,
            'status': 'deleted',
            'deletedAt': DateTime.now().toUtc().toIso8601String(),
          },
        ),
      );
      await job.progress(
        i + 1,
        ids.length,
        currentFile: row.title,
        force: true,
      );
    }
  }
}
