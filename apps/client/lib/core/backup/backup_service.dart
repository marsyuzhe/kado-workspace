import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../data/record_store.dart';
import '../data/tool_record.dart';
import '../database/app_database.dart';
import '../storage/data_mutation_gate.dart';
import '../storage/owned_file_store.dart';

const maxBackupBytes = 250 * 1024 * 1024,
    maxExpandedBackupBytes = 500 * 1024 * 1024;
Future<String> _hash(File f) async =>
    (await sha256.bind(f.openRead()).first).toString();
String _archiveName(String relative) => p.posix.joinAll(p.split(relative));
bool _safeBackupPath(String name) {
  if (name.isEmpty ||
      name.length > 300 ||
      name.contains('\\') ||
      name.contains(':') ||
      name.contains('\u0000') ||
      p.posix.isAbsolute(name) ||
      name.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
    return false;
  }
  return name == 'database.sqlite' ||
      name == 'manifest.json' ||
      RegExp(r'^attachments/[a-z_]+/[a-f0-9-]+\.[a-z0-9]+$').hasMatch(name);
}

class BackupPreview {
  const BackupPreview(
    this.directory,
    this.createdAt,
    this.schema,
    this.counts,
    this.files,
  );
  final Directory directory;
  final DateTime createdAt;
  final int schema;
  final Map<String, int> counts;
  final Map<String, dynamic> files;
}

class LocalDataHome {
  LocalDataHome(this.base);
  final Directory base;
  File get pointer => File(p.join(base.path, 'active_data.json'));
  Future<Directory> active() async {
    if (!await pointer.exists()) return base;
    final data = jsonDecode(await pointer.readAsString()) as Map;
    final id = data['generation'];
    if (id is! String || !RegExp(r'^[a-f0-9-]{36}$').hasMatch(id)) {
      throw const ToolFailure('数据目录指针无效，原数据仍保留。');
    }
    final directory = Directory(p.join(base.path, 'restored', id));
    if (!await File(p.join(directory.path, 'links_toolbox.sqlite')).exists()) {
      throw const ToolFailure('恢复数据目录不完整，原数据仍保留。');
    }
    return directory;
  }

  Future<void> schedule(
    BackupPreview preview, {
    required bool confirmed,
  }) async {
    if (!confirmed) throw const ToolFailure('恢复前需要确认。');
    final allowed = p.join(base.path, 'restore-staging');
    if (!p.isWithin(allowed, preview.directory.path)) {
      throw const ToolFailure('恢复暂存目录无效。');
    }
    await File(p.join(base.path, 'pending_restore.json')).writeAsString(
      jsonEncode({
        'stage': p.basename(preview.directory.path),
        'requestedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
  }

  Future<bool> applyPending() async {
    final pending = File(p.join(base.path, 'pending_restore.json'));
    if (!await pending.exists()) return false;
    final data = jsonDecode(await pending.readAsString()) as Map;
    final id = data['stage'];
    if (id is! String || !RegExp(r'^[a-f0-9-]{36}$').hasMatch(id)) {
      throw const ToolFailure('待恢复目录标识无效，原数据保持不变。');
    }
    final stage = Directory(p.join(base.path, 'restore-staging', id));
    // Re-check after restart: a user may have changed the staging files.
    await validateBackupDirectory(stage);
    final database = AppDatabase.file(
      File(p.join(stage.path, 'database.sqlite')),
    );
    try {
      await database.initialize();
      final store = RecordStore(database);
      final clip = await store.setting('clipboard.config');
      if (clip != null) {
        final config = Map<String, dynamic>.from(jsonDecode(clip) as Map);
        config['enabled'] = false;
        config['paused'] = true;
        await store.setSetting('clipboard.config', jsonEncode(config));
      }
      final hotkey = await store.setting('hub.hotkey');
      if (hotkey != null) {
        final config = Map<String, dynamic>.from(jsonDecode(hotkey) as Map);
        config['enabled'] = false;
        await store.setSetting('hub.hotkey', jsonEncode(config));
      }
      await store.setSetting('deviceId', newId());
    } finally {
      await database.close();
    }
    await File(p.join(stage.path, 'database.sqlite'))
        .rename(p.join(stage.path, 'links_toolbox.sqlite'));
    final restored = Directory(p.join(base.path, 'restored'));
    await restored.create(recursive: true);
    final destination = p.join(restored.path, id);
    if (await Directory(destination).exists()) {
      throw const ToolFailure('目标恢复目录已存在，原数据保持不变。');
    }
    await stage.rename(destination);
    // Activating a complete generation leaves every previous database/attachment
    // directory untouched. The previous pointer is kept for explicit rollback.
    final previous = File(p.join(base.path, 'active_data.previous.json'));
    await previous.writeAsString(
      await pointer.exists()
          ? await pointer.readAsString()
          : jsonEncode({'generation': null}),
      flush: true,
    );
    final temp = File(p.join(base.path, 'active-${newId()}.tmp'));
    await temp.writeAsString(jsonEncode({'generation': id}), flush: true);
    await temp.rename(pointer.path);
    await pending.delete();
    return true;
  }

  Future<void> rollbackPointer({required bool confirmed}) async {
    if (!confirmed) throw const ToolFailure('回到恢复前数据需要确认。');
    final previous = File(p.join(base.path, 'active_data.previous.json'));
    if (!await previous.exists()) throw const ToolFailure('没有恢复前的数据指针。');
    final data = jsonDecode(await previous.readAsString()) as Map;
    if (data['generation'] == null) {
      if (await pointer.exists()) await pointer.delete();
    } else {
      final temp = File(p.join(base.path, 'rollback-${newId()}.tmp'));
      await temp.writeAsString(jsonEncode(data), flush: true);
      await temp.rename(pointer.path);
    }
  }
}

class BackupService {
  BackupService(this.database, this.files, this.home);
  final AppDatabase database;
  final OwnedFileStore files;
  final LocalDataHome home;
  Future<File> create() => DataMutationGate.shared.run(() async {
    final cache = Directory(p.join(home.base.path, 'backups'));
    await cache.create(recursive: true);
    final staging = await Directory(p.join(home.base.path, 'backup-work'))
        .create(recursive: true);
    final work = await staging.createTemp('snapshot-');
    try {
      final dbFile = File(p.join(work.path, 'database.sqlite'));
      await database.backupTo(dbFile);
      final snapshot = AppDatabase.file(dbFile);
      final hashes = <String, dynamic>{};
      Map<String, int> counts = {};
      try {
        await snapshot.initialize();
        counts = await _recordCounts(snapshot);
        final rows = await snapshot
            .customSelect(
              "SELECT data FROM local_records WHERE deleted_at IS NULL",
            )
            .get();
        final refs = <String>{};
        for (final row in rows) {
          final data = jsonDecode(row.read<String>('data')) as Map;
          final value = data['attachment'];
          if (value is String && value.isNotEmpty) refs.add(value);
        }
        var total = await dbFile.length();
        for (final ref in refs) {
          final source = files.resolve(ref);
          if (!await source.exists()) {
            throw const ToolFailure('附件缺失，备份未创建。请修复对应记录后重试。');
          }
          final relative = _archiveName(ref);
          if (!_safeBackupPath(relative)) {
            throw const ToolFailure('附件路径无效，备份未创建。');
          }
          final length = await source.length();
          total += length;
          if (total > maxExpandedBackupBytes) {
            throw const ToolFailure('备份数据超过500MB，当前版本请分批导出大附件。');
          }
          final destination = File(p.join(work.path, p.fromUri(relative)));
          await destination.parent.create(recursive: true);
          await source.copy(destination.path);
          hashes[relative] = {
            'size': length,
            'sha256': await _hash(destination),
          };
        }
      } finally {
        await snapshot.close();
      }
      hashes['database.sqlite'] = {
        'size': await dbFile.length(),
        'sha256': await _hash(dbFile),
      };
      final manifest = {
        'format': 'links-toolbox-backup',
        'version': 1,
        'schema': database.schemaVersion,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'counts': counts,
        'files': hashes,
        'credentialsIncluded': false,
      };
      await File(p.join(work.path, 'manifest.json'))
          .writeAsString(jsonEncode(manifest), flush: true);
      final destination = File(
        p.join(
          cache.path,
          'links-${DateTime.now().microsecondsSinceEpoch}.zip',
        ),
      );
      await _encodeBackupWorker(work.path, destination.path, [
        ...hashes.keys,
        'manifest.json',
      ]);
      if (await destination.length() > maxBackupBytes) {
        await destination.delete();
        throw const ToolFailure('压缩备份超过250MB上限，请分批导出附件。');
      }
      return destination;
    } finally {
      await work.delete(recursive: true);
    }
  });
  Future<BackupPreview> inspect(File archive) async {
    if (await archive.length() > maxBackupBytes) {
      throw const ToolFailure('备份文件超过250MB。');
    }
    final staging = Directory(
      p.join(home.base.path, 'restore-staging', newId()),
    );
    await staging.create(recursive: true);
    try {
      await _unpackBackupWorker(archive.path, staging.path);
      return await validateBackupDirectory(staging);
    } catch (_) {
      await staging.delete(recursive: true);
      rethrow;
    }
  }
}

Future<Map<String, int>> _recordCounts(AppDatabase db) async {
  final rows = await db
      .customSelect(
        'SELECT kind,count(*) AS count FROM local_records WHERE deleted_at IS NULL GROUP BY kind',
      )
      .get();
  return {for (final r in rows) r.read<String>('kind'): r.read<int>('count')};
}

Future<BackupPreview> validateBackupDirectory(Directory dir) async {
  final manifestFile = File(p.join(dir.path, 'manifest.json'));
  if (!await manifestFile.exists() ||
      await manifestFile.length() > 4 * 1024 * 1024) {
    throw const ToolFailure('缺少有效备份清单。');
  }
  final manifest = jsonDecode(await manifestFile.readAsString()) as Map;
  if (manifest['format'] != 'links-toolbox-backup' ||
      manifest['version'] != 1 ||
      manifest['schema'] != 3 ||
      manifest['credentialsIncluded'] != false) {
    throw const ToolFailure('不支持此备份格式或数据库版本。原数据保持不变。');
  }
  final entries = Map<String, dynamic>.from(manifest['files'] as Map);
  if (!entries.containsKey('database.sqlite') || entries.length > 10001) {
    throw const ToolFailure('备份清单不完整。');
  }
  var total = 0;
  for (final entry in entries.entries) {
    if (!_safeBackupPath(entry.key) || entry.key == 'manifest.json') {
      throw const ToolFailure('备份附件路径无效。');
    }
    final file = File(p.join(dir.path, p.fromUri(entry.key)));
    final data = entry.value as Map;
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const ToolFailure('备份文件缺失或是链接。');
    }
    final length = await file.length();
    total += length;
    if (total > maxExpandedBackupBytes ||
        length != data['size'] ||
        await _hash(file) != data['sha256']) {
      throw const ToolFailure('备份大小或SHA-256校验不一致。');
    }
  }
  final database = AppDatabase.file(File(p.join(dir.path, 'database.sqlite')));
  try {
    await database.initialize();
    if (!await database.verifyIntegrity()) {
      throw const ToolFailure('备份SQLite完整性校验失败。');
    }
    final counts = await _recordCounts(database);
    if (jsonEncode(
          Map.fromEntries(
            counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
          ),
        ) !=
        jsonEncode(
          Map.fromEntries(
            Map<String, int>.from(manifest['counts'] as Map).entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key)),
          ),
        )) {
      throw const ToolFailure('备份记录数量与清单不一致。');
    }
    final rows = await database
        .customSelect('SELECT data FROM local_records WHERE deleted_at IS NULL')
        .get();
    for (final row in rows) {
      final data = jsonDecode(row.read<String>('data')) as Map;
      final reference = data['attachment'];
      if (reference is String &&
          reference.isNotEmpty &&
          !entries.containsKey(_archiveName(reference))) {
        throw const ToolFailure('备份缺少数据库引用的附件。');
      }
    }
    return BackupPreview(
      dir,
      DateTime.parse(manifest['createdAt'] as String),
      3,
      counts,
      entries,
    );
  } finally {
    await database.close();
  }
}

Future<void> _encodeBackupWorker(
  String sourceRoot,
  String targetPath,
  List<String> names,
) => Isolate.run(() async {
  final encoder = ZipFileEncoder();
  encoder.create(targetPath);
  try {
    for (final name in names) {
      await encoder.addFile(File(p.join(sourceRoot, p.fromUri(name))), name);
    }
  } finally {
    await encoder.close();
  }
});

Future<void> _unpackBackupWorker(String archivePath, String stagingPath) =>
    Isolate.run(() async {
      final input = InputFileStream(archivePath);
      try {
        final directory = ZipDirectory()..read(input);
        var expanded = 0;
        if (directory.fileHeaders.length > 10002) {
          throw const ToolFailure('备份文件数量超限。');
        }
        for (final header in directory.fileHeaders) {
          expanded += header.uncompressedSize;
          final mode = header.externalFileAttributes >> 16;
          if (expanded > maxExpandedBackupBytes ||
              (mode & 0xf000) == 0xa000 ||
              !_safeBackupPath(header.filename)) {
            throw const ToolFailure('备份目录包含链接、非法路径或展开大小超限。');
          }
        }
        final decoder = ZipDecoder();
        final entries = decoder.decodeStream(input);
        final names = <String>{};
        var total = 0;
        for (final header in decoder.directory.fileHeaders) {
          final name = header.filename;
          if (!_safeBackupPath(name) || !names.add(name.toLowerCase())) {
            throw const ToolFailure('备份含非法路径、重名或不支持的文件。');
          }
        }
        if (entries.length > 10002) throw const ToolFailure('备份文件数量超限。');
        for (final entry in entries) {
          total += entry.size;
          if (!entry.isFile ||
              entry.isSymbolicLink ||
              entry.size < 0 ||
              total > maxExpandedBackupBytes ||
              (entry.name == 'manifest.json' && entry.size > 4 * 1024 * 1024)) {
            throw const ToolFailure('备份包含链接、目录或超出展开大小上限。');
          }
        }
        for (final entry in entries) {
          await File(p.join(stagingPath, p.fromUri(entry.name))).parent
              .create(recursive: true);
          final out = OutputFileStream(
            p.join(stagingPath, p.fromUri(entry.name)),
          );
          try {
            entry.writeContent(out);
          } finally {
            await out.close();
          }
        }
      } finally {
        await input.close();
      }
    });
