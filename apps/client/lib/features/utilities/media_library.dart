import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/jobs/utility_process.dart';
import '../../core/storage/utility_files.dart';
import '../archive/archive_service.dart';
import 'media_converter.dart';

class MediaLibraryService {
  MediaLibraryService(this.store, this.media, this.files, this.root);
  final RecordStore store;
  final MediaConverterService media;
  final UtilityFileService files;
  final Future<Directory> Function() root;
  static const extensions = {'mp4', 'mkv', 'mov'};
  static bool matches(ToolRecord row, String query) =>
      '${row.title} ${row.body} ${row.strings('tags').join(' ')}'
          .toLowerCase()
          .contains(query.trim().toLowerCase());
  Future<List<ToolRecord>> search(String query) async => (await store.list(
    'media_asset',
    limit: 10000,
  )).where((row) => matches(row, query)).toList();
  Future<Directory> cacheDirectory() async {
    final dir = Directory(
      p.join((await root()).path, 'cache', 'media-thumbnails'),
    );
    await dir.create(recursive: true);
    return files.selectedDirectory(dir.path);
  }

  Future<List<File>> cachedFiles() async => [
    await for (final entry in (await cacheDirectory()).list(followLinks: false))
      if (entry is File &&
          RegExp(r'^[0-9a-f-]{36}\.png$').hasMatch(p.basename(entry.path)))
        entry,
  ];
  Future<int> cacheSize() async {
    var size = 0;
    for (final file in await cachedFiles()) {
      size += await file.length();
    }
    return size;
  }

  Future<int> cacheLimit() async =>
      (int.tryParse(await store.setting('media.cacheMiB') ?? '128') ?? 128)
          .clamp(16, 512);
  Future<void> setCacheLimit(int mib) async {
    if (mib < 16 || mib > 512) throw const ToolFailure('缩略图缓存限额16–512MiB。');
    await store.setSetting('media.cacheMiB', '$mib');
    await prune();
  }

  Future<void> clearCache({
    required bool confirmed,
    UtilityJobContext? job,
  }) async {
    if (!confirmed) throw const ToolFailure('清理缓存需要确认。');
    final files = await cachedFiles();
    for (var i = 0; i < files.length; i++) {
      job?.check();
      await files[i].delete();
      await job?.progress(i + 1, files.length, force: true);
    }
  }

  Future<void> prune() async {
    final files = await cachedFiles(), stats = <String, FileStat>{};
    var total = 0;
    for (final f in files) {
      final s = await f.stat();
      stats[f.path] = s;
      total += s.size;
    }
    files.sort(
      (a, b) => stats[a.path]!.modified.compareTo(stats[b.path]!.modified),
    );
    final budget = await cacheLimit() * 1024 * 1024;
    for (final f in files) {
      if (total <= budget) break;
      total -= stats[f.path]!.size;
      await f.delete();
    }
  }

  Future<Uint8List?> thumbnail(ToolRecord row) async {
    final name = row.text('thumbnail');
    if (!RegExp(r'^[0-9a-f-]{36}\.png$').hasMatch(name)) return null;
    final file = File(p.join((await cacheDirectory()).path, name));
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > 2 * 1024 * 1024) {
      return null;
    }
    return file.readAsBytes();
  }

  Future<ToolRecord> poster(
    ToolRecord row,
    double seconds,
    UtilityJobContext job,
  ) async {
    if (row.kind != 'media_asset' ||
        !seconds.isFinite ||
        seconds < 0 ||
        seconds >= ((row.data['duration'] as num?)?.toDouble() ?? 0)) {
      throw const ToolFailure('封面时间需要在视频时长范围内。');
    }
    final input = await media.selectedInput(row.text('path')),
        engine = await media.runtime.verified(),
        name = '${newId()}.png';
    final target = File(p.join((await cacheDirectory()).path, name));
    await files.ensureSpace(target.parent.path, 2 * 1024 * 1024);
    late ToolRecord updated;
    try {
      final run = await runUtilityProcess(
        p.join(engine.text('directory'), 'ffmpeg.exe'),
        [
          '-v',
          'error',
          '-nostdin',
          '-n',
          '-protocol_whitelist',
          'file,pipe',
          '-format_whitelist',
          'wav,mp3,flac,mov,aac,matroska,webm,amr',
          '-ss',
          '$seconds',
          '-i',
          input.path,
          '-frames:v',
          '1',
          '-vf',
          'scale=320:240:force_original_aspect_ratio=decrease:force_divisible_by=2',
          '-an',
          target.path,
        ],
        job,
        timeout: const Duration(seconds: 30),
      );
      if (run.code != 0 ||
          !await target.exists() ||
          await target.length() == 0 ||
          await target.length() > 2 * 1024 * 1024) {
        throw const ToolFailure('封面提取失败，原始视频保持不变。');
      }
      updated = await store.save(
        row.copyWith(
          data: {
            ...row.data,
            'thumbnail': name,
            'thumbnailTime': seconds,
            'thumbnailChecksum': await archiveHash(target, job.cancellation),
          },
        ),
      );
    } catch (_) {
      if (await target.exists()) await target.delete();
      rethrow;
    }
    await prune();
    return updated;
  }

  Future<List<ToolRecord>> importPaths(
    List<String> paths,
    UtilityJobContext job,
  ) async {
    if (paths.isEmpty || paths.length > 500) {
      throw const ToolFailure('单次选择1–500个媒体文件。');
    }
    final engine = await media.runtime.verified(), results = <ToolRecord>[];
    for (var i = 0; i < paths.length; i++) {
      job.check();
      final file = await media.selectedInput(paths[i]),
          stat = await File(paths[i]).stat();
      await job.progress(
        i,
        paths.length,
        currentFile: p.basename(file.path),
        force: true,
      );
      final existing = await store.find(
        'media_asset',
        'pathKey',
        archivePathKey(file.path),
      );
      if (existing != null &&
          existing.number('size') == stat.size &&
          existing.text('modified') ==
              stat.modified.toUtc().toIso8601String()) {
        results.add(existing);
        await job.output(existing.id);
        await job.progress(i + 1, paths.length, force: true);
        continue;
      }
      final info = await media.probe(file.path, engine: engine);
      if (!info.hasVideo) throw ToolFailure('${p.basename(file.path)}没有视频轨道。');
      final video = info.streams.firstWhere(
        (s) =>
            s['codec_type'] == 'video' &&
            (s['disposition'] as Map?)?['attached_pic'] != 1,
      );
      final after = await file.stat();
      if (after.size != stat.size || after.modified != stat.modified) {
        throw const ToolFailure('索引期间源文件变化，请重试。');
      }
      final data = {
        ...existing?.data ?? {},
        'payloadVersion': 1,
        'path': file.path,
        'pathKey': archivePathKey(file.path),
        'size': stat.size,
        'modified': stat.modified.toUtc().toIso8601String(),
        'format': p.extension(file.path).replaceFirst('.', '').toLowerCase(),
        'duration': info.seconds,
        'width': video['width'],
        'height': video['height'],
        'frameRate': video['avg_frame_rate'],
        'videoCodec': video['codec_name'],
        'audio': info.streams.where((s) => s['codec_type'] == 'audio').toList(),
        'lastExists': true,
        'lastCheckedAt': DateTime.now().toUtc().toIso8601String(),
        'syncAllowed': false,
        'isSensitive': true,
      };
      var row = existing == null
          ? await store.create('media_asset', p.basename(file.path), data: data)
          : await store.save(existing.copyWith(data: data));
      await job.output(row.id);
      try {
        row = await poster(row, info.seconds > 1 ? 1 : 0, job);
      } on ToolFailure catch (error) {
        row = await store.save(
          row.copyWith(data: {...row.data, 'thumbnailError': error.message}),
        );
      }
      results.add(row);
      await job.progress(
        i + 1,
        paths.length,
        currentFile: p.basename(file.path),
        force: true,
      );
    }
    return results;
  }

  Future<ToolRecord> edit(
    ToolRecord row, {
    required String title,
    required List<String> tags,
    required String notes,
    required bool favorite,
    int rating = 0,
    String projectId = '',
    String studioTaskId = '',
    String archiveId = '',
  }) async {
    if (row.kind != 'media_asset' ||
        title.trim().isEmpty ||
        title.length > 300 ||
        tags.length > 30 ||
        notes.length > 20000 ||
        rating < 0 ||
        rating > 5) {
      throw const ToolFailure('素材名称、标签、备注或评分无效。');
    }
    for (final link in [
      (projectId, 'project'),
      (studioTaskId, 'studio_task'),
      (archiveId, 'archive_file'),
    ]) {
      if (link.$1.isNotEmpty && (await store.get(link.$1))?.kind != link.$2) {
        throw const ToolFailure('关联记录已不存在。');
      }
    }
    return store.save(
      row.copyWith(
        title: title,
        body: notes,
        data: {
          ...row.data,
          'tags': tags.toSet().toList(),
          'favorite': favorite,
          'rating': rating,
          'projectId': projectId,
          'studioTaskId': studioTaskId,
          'archiveId': archiveId,
        },
      ),
    );
  }

  Future<ToolRecord> check(ToolRecord row) async {
    final file = File(row.text('path')),
        exists =
            await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.file;
    final changed =
        exists &&
        ((await file.stat()).size != row.number('size') ||
            (await file.stat()).modified.toUtc().toIso8601String() !=
                row.text('modified'));
    return store.save(
      row.copyWith(
        data: {
          ...row.data,
          'lastExists': exists,
          'changed': changed,
          'lastCheckedAt': DateTime.now().toUtc().toIso8601String(),
        },
      ),
    );
  }
}
