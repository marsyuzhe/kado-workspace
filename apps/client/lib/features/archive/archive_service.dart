import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/platform/system_actions.dart';

class TaskCancellation {
  bool cancelled = false;
  void cancel() => cancelled = true;
  void check() {
    if (cancelled) throw const ToolFailure('任务已取消，已有文件保持原样。');
  }
}

class ArchiveFile {
  const ArchiveFile(this.path, this.size, this.modified, this.category);
  final String path, category;
  final int size;
  final DateTime modified;
  String get name => p.basename(path);
}

const defaultArchiveRules = <String, String>{
  '图片': 'jpg,jpeg,png,gif,webp,bmp,svg,heic',
  '视频': 'mp4,mkv,mov,avi,webm',
  '音频': 'mp3,wav,flac,aac,m4a,ogg',
  '文档': 'pdf,doc,docx,xls,xlsx,ppt,pptx,txt,md,csv',
  '压缩包': 'zip,rar,7z,tar,gz',
  '安装包': 'exe,msi,apk,ipa,dmg',
  '代码': 'dart,js,ts,tsx,jsx,py,java,cpp,h,c,html,css,json,yaml,sql,rs,go',
};
String classifyFile(String path, Map<String, String> rules) {
  final extension = p.extension(path).toLowerCase().replaceFirst('.', '');
  for (final entry in rules.entries) {
    if (entry.value
        .toLowerCase()
        .split(',')
        .map((s) => s.trim())
        .contains(extension)) {
      return entry.key;
    }
  }
  return '其他';
}

class ScanResult {
  const ScanResult(
    this.files,
    this.errors, {
    this.cancelled = false,
    this.limited = false,
    this.elapsed = Duration.zero,
    this.directories = const [],
  });
  final List<ArchiveFile> files;
  final List<String> errors;
  final bool cancelled, limited;
  final Duration elapsed;
  final List<String> directories;
  int get bytes => files.fold(0, (n, f) => n + f.size);
  Map<String, int> get categories {
    final result = <String, int>{};
    for (final f in files) {
      result.update(f.category, (n) => n + 1, ifAbsent: () => 1);
    }
    return result;
  }

  List<ArchiveFile> get largest =>
      [...files]..sort((a, b) => b.size.compareTo(a.size));
  List<ArchiveFile> get recent =>
      [...files]..sort((a, b) => b.modified.compareTo(a.modified));
}

class ArchiveScanner {
  Future<ScanResult> scan(
    String root,
    TaskCancellation cancel, {
    Map<String, String> rules = defaultArchiveRules,
    void Function(int, int)? onProgress,
    int limit = 50000,
  }) async {
    if (await FileSystemEntity.type(root, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const ToolFailure('授权目录已不存在或是链接，请重新选择。');
    }
    final files = <ArchiveFile>[],
        errors = <String>[],
        directories = <String>[];
    var bytes = 0, limited = false;
    final watch = Stopwatch()..start();
    Future<void> visit(String dir, [int depth = 0]) async {
      if (depth > 128 || directories.length >= 50000) {
        limited = true;
        return;
      }
      try {
        await for (final entity in Directory(dir).list(followLinks: false)) {
          if (cancel.cancelled || limited) break;
          if (entity is Directory) {
            if (await FileSystemEntity.type(entity.path, followLinks: false) !=
                FileSystemEntityType.directory) {
              continue;
            }
            directories.add(p.normalize(p.absolute(entity.path)));
            await visit(entity.path, depth + 1);
          } else if (entity is File) {
            try {
              if (await FileSystemEntity.type(
                    entity.path,
                    followLinks: false,
                  ) !=
                  FileSystemEntityType.file) {
                continue;
              }
              final stat = await entity.stat();
              files.add(
                ArchiveFile(
                  p.normalize(p.absolute(entity.path)),
                  stat.size,
                  stat.modified,
                  classifyFile(entity.path, rules),
                ),
              );
              bytes += stat.size;
              if (files.length % 50 == 0) {
                onProgress?.call(files.length, bytes);
                await Future<void>.delayed(Duration.zero);
              }
              if (files.length >= limit) limited = true;
            } on FileSystemException {
              errors.add('${entity.path}：无法读取文件属性');
            }
          }
        }
      } on FileSystemException {
        errors.add('$dir：无法访问或读取目录');
      }
    }

    await visit(p.normalize(p.absolute(root)));
    onProgress?.call(files.length, bytes);
    return ScanResult(
      List.unmodifiable(files),
      List.unmodifiable(errors),
      cancelled: cancel.cancelled,
      limited: limited,
      elapsed: watch.elapsed,
      directories: List.unmodifiable(directories),
    );
  }
}

Future<String> archiveHash(
  File file,
  TaskCancellation cancel, {
  bool quick = false,
}) async {
  cancel.check();
  if (!quick) {
    final stream = file.openRead().map((chunk) {
      cancel.check();
      return chunk;
    });
    return (await sha256.bind(stream).first).toString();
  }
  final handle = await file.open();
  try {
    final length = await handle.length();
    final bytes = <int>[...utf8.encode('$length:')];
    bytes.addAll(await handle.read(65536));
    if (length > 65536) {
      await handle.setPosition((length - 65536).clamp(65536, length));
      bytes.addAll(await handle.read(65536));
    }
    cancel.check();
    return sha256.convert(bytes).toString();
  } finally {
    await handle.close();
  }
}

class DuplicateDetector {
  Future<List<List<ArchiveFile>>> find(
    List<ArchiveFile> files,
    TaskCancellation cancel, {
    void Function(int, int)? onProgress,
  }) async {
    final sizes = <int, List<ArchiveFile>>{};
    for (final f in files) {
      sizes.putIfAbsent(f.size, () => []).add(f);
    }
    final candidates = sizes.values
        .where((g) => g.length > 1)
        .expand((g) => g)
        .toList();
    final quick = <String, List<ArchiveFile>>{},
        full = <String, List<ArchiveFile>>{};
    var done = 0;
    for (final f in candidates) {
      cancel.check();
      try {
        quick
            .putIfAbsent(
              '${f.size}:${await archiveHash(File(f.path), cancel, quick: true)}',
              () => [],
            )
            .add(f);
      } on FileSystemException {
        throw ToolFailure('重复检测中无法读取：${f.path}。请重新扫描。');
      }
      onProgress?.call(++done, candidates.length * 2);
    }
    for (final group in quick.values.where((g) => g.length > 1)) {
      for (final f in group) {
        cancel.check();
        final before = await File(f.path).stat();
        if (before.size != f.size || before.modified != f.modified) {
          throw const ToolFailure('文件在扫描后发生变化，请重新扫描。');
        }
        final hash = await archiveHash(File(f.path), cancel);
        final after = await File(f.path).stat();
        if (after.size != before.size || after.modified != before.modified) {
          throw const ToolFailure('文件在检测期间发生变化，请重试。');
        }
        full.putIfAbsent('${f.size}:$hash', () => []).add(f);
        onProgress?.call(++done, candidates.length * 2);
      }
    }
    onProgress?.call(candidates.length * 2, candidates.length * 2);
    return full.values.where((g) => g.length > 1).toList();
  }
}

class RenameRule {
  const RenameRule({
    this.prefix = '',
    this.suffix = '',
    this.date = false,
    this.sequence = false,
    this.find = '',
    this.replace = '',
    this.clean = false,
    this.regex = false,
    this.sequenceStart = 1,
    this.sequenceWidth = 3,
    this.sequenceStep = 1,
    this.keepOriginal = true,
    this.datePattern = 'yyyyMMdd',
  });
  final String prefix, suffix, find, replace;
  final bool date, sequence, clean;
  final bool regex;
  final int sequenceStart, sequenceWidth, sequenceStep;
  final bool keepOriginal;
  final String datePattern;
  String apply(ArchiveFile file, int index) {
    if (sequenceStart < 0 ||
        sequenceStart > 999999 ||
        sequenceWidth < 1 ||
        sequenceWidth > 8 ||
        sequenceStep < 1 ||
        sequenceStep > 999999 ||
        index < 0 ||
        datePattern.length > 40) {
      throw const ToolFailure('编号起点0–999999，位数1–8，日期模板最多40字符。');
    }
    var name = p.basenameWithoutExtension(file.name);
    if (find.isNotEmpty) {
      if (regex) {
        if (find.length > 120 ||
            find.contains('(?') ||
            RegExp(r'\\[1-9]|[{}]|\)[+*?]').hasMatch(find)) {
          throw const ToolFailure('正则仅支持有限的字符类、捕获和锚点；不支持回溯引用、环视、分组重复或花括号。');
        }
        var repeat = 0, escaped = false, characterClass = false;
        for (final rune in find.runes) {
          if (escaped) {
            escaped = false;
            continue;
          }
          if (rune == 92) {
            escaped = true;
            continue;
          }
          if (rune == 91) characterClass = true;
          if (rune == 93) characterClass = false;
          if (!characterClass && {42, 43, 63}.contains(rune)) repeat++;
        }
        if (repeat > 1) {
          throw const ToolFailure('为避免阻塞界面，正则最多使用一个 *、+ 或 ? 重复符。');
        }
        try {
          name = name.replaceAllMapped(
            RegExp(find),
            (match) => replace.replaceAllMapped(RegExp(r'\$(\d)'), (group) {
              final number = int.parse(group[1]!);
              if (number > match.groupCount) {
                throw const ToolFailure('替换引用了不存在的捕获组。');
              }
              return match[number] ?? '';
            }),
          );
        } on FormatException {
          throw const ToolFailure('正则表达式格式无效。');
        }
      } else {
        name = name.replaceAll(find, replace);
      }
    }
    if (clean) {
      name = name
          .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
    final time = file.modified.toLocal();
    final parts = {
      'yyyy': '${time.year}',
      'MM': '${time.month}'.padLeft(2, '0'),
      'dd': '${time.day}'.padLeft(2, '0'),
      'HH': '${time.hour}'.padLeft(2, '0'),
      'mm': '${time.minute}'.padLeft(2, '0'),
    };
    var stamp = datePattern;
    for (final entry in parts.entries) {
      stamp = stamp.replaceAll(entry.key, entry.value);
    }
    final number = (index * sequenceStep + sequenceStart).toString().padLeft(
      sequenceWidth,
      '0',
    );
    return '$prefix${date ? '${stamp}_' : ''}${sequence ? '$number${keepOriginal ? '_' : ''}' : ''}${keepOriginal ? name : ''}$suffix${p.extension(file.name)}';
  }
}

class PlannedFile {
  const PlannedFile(
    this.source,
    this.target,
    this.size,
    this.modified,
    this.hash, {
    this.error = '',
  });
  final String source, target, hash, error;
  final int size;
  final DateTime modified;
  Map<String, dynamic> toJson() => {
    'source': source,
    'target': target,
    'size': size,
    'modified': modified.toIso8601String(),
    'hash': hash,
    'error': error,
  };
  factory PlannedFile.fromJson(Map<String, dynamic> j) => PlannedFile(
    j['source'] as String,
    j['target'] as String,
    j['size'] as int,
    DateTime.parse(j['modified'] as String),
    j['hash'] as String,
    error: j['error'] as String? ?? '',
  );
}

class ArchivePlan {
  const ArchivePlan(this.operation, this.files);
  final String operation;
  final List<PlannedFile> files;
  bool get valid => files.isNotEmpty && files.every((f) => f.error.isEmpty);
}

String archivePathKey(String path) =>
    Platform.isWindows ? p.normalize(path).toLowerCase() : p.normalize(path);
bool validArchiveName(String name) =>
    name.isNotEmpty &&
    name.length <= 240 &&
    name != '.' &&
    name != '..' &&
    !name.endsWith(' ') &&
    !name.endsWith('.') &&
    !RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(name) &&
    !RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
      caseSensitive: false,
    ).hasMatch(name);

class ArchiveService {
  ArchiveService(
    this.store,
    this.native, {
    Future<void> Function(String, String)? mover,
  }) : _mover = mover ?? native.moveFileExclusive;
  final RecordStore store;
  final NativePlatformAdapter native;
  final Future<void> Function(String, String) _mover;
  bool _busy = false;
  Future<ToolRecord> grant(String path) async {
    final dir = Directory(path);
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const ToolFailure('请选择真实目录，不支持链接目录。');
    }
    final canonical = await dir.resolveSymbolicLinks();
    final existing = await store.find('archive_root', 'path', canonical);
    return existing ??
        await store.create(
          'archive_root',
          p.basename(canonical),
          data: {'path': canonical},
        );
  }

  Future<void> index(ToolRecord root, ScanResult result) async {
    if (result.cancelled || result.limited) return;
    final old = (await store.list(
      'archive_file',
      limit: 10000,
    )).where((r) => r.text('rootId') == root.id).toList();
    final paths = <String>{};
    await store.transaction(() async {
      for (final file in result.files) {
        paths.add(file.path);
        final existing = await store.find('archive_file', 'path', file.path);
        final data = {
          'path': file.path,
          'rootId': root.id,
          'size': file.size,
          'modified': file.modified.toUtc().toIso8601String(),
          'category': file.category,
        };
        if (existing == null) {
          await store.create(
            'archive_file',
            file.name,
            body: file.path,
            data: data,
          );
        } else {
          await store.save(
            existing.copyWith(title: file.name, body: file.path, data: data),
          );
        }
      }
      // Inaccessible subdirectories do not erase previous metadata.
      if (result.errors.isEmpty) {
        for (final row in old.where((r) => !paths.contains(r.text('path')))) {
          await store.delete(row);
        }
      }
    });
  }

  Future<ArchivePlan> plan(
    List<ArchiveFile> files,
    String operation,
    TaskCancellation cancel, {
    RenameRule rule = const RenameRule(),
    String? destination,
    bool byCategory = false,
    bool stagedRename = false,
    List<String>? names,
  }) async {
    if (!{'rename', 'move', 'copy'}.contains(operation)) {
      throw const ToolFailure('未知文件操作。');
    }
    if (names != null &&
        (operation != 'rename' || names.length != files.length)) {
      throw const ToolFailure('重命名清单与源文件数量不一致。');
    }
    if (files.length > 1000) throw const ToolFailure('单次最多1000个文件，请分批。');
    final sources = files.map((f) => archivePathKey(f.path)).toSet();
    if (operation != 'rename' &&
        (destination == null || !await Directory(destination).exists())) {
      throw const ToolFailure('请先选择目标目录。');
    }
    final targets = <String>{}, items = <PlannedFile>[];
    for (var i = 0; i < files.length; i++) {
      cancel.check();
      final f = files[i];
      final name = operation == 'rename'
          ? (names?[i] ?? rule.apply(f, i))
          : f.name;
      final target = p.join(
        operation == 'rename'
            ? p.dirname(f.path)
            : byCategory
            ? p.join(destination!, f.category)
            : destination!,
        name,
      );
      var error = '';
      if (!validArchiveName(name)) {
        error = '文件名含保留字符、设备名或长度超限';
      } else if (stagedRename
          ? p.normalize(f.path) == p.normalize(target)
          : archivePathKey(f.path) == archivePathKey(target)) {
        error = '源路径和目标相同';
      } else if (!targets.add(archivePathKey(target))) {
        error = '计划内目标重名';
      } else if (await FileSystemEntity.type(target, followLinks: false) !=
              FileSystemEntityType.notFound &&
          !(stagedRename &&
              operation == 'rename' &&
              sources.contains(archivePathKey(target)))) {
        error = '目标已存在，禁止覆盖';
      }
      var hash = '';
      try {
        final stat = await File(f.path).stat();
        if (stat.size != f.size || stat.modified != f.modified) {
          error = '扫描后文件已变化';
        } else {
          hash = await archiveHash(File(f.path), cancel);
        }
      } on FileSystemException {
        error = '源文件不可读';
      }
      items.add(
        PlannedFile(f.path, target, f.size, f.modified, hash, error: error),
      );
    }
    return ArchivePlan(
      stagedRename && operation == 'rename' ? 'rename_staged' : operation,
      List.unmodifiable(items),
    );
  }

  Future<void> _check(
    PlannedFile f,
    TaskCancellation cancel, {
    bool target = false,
  }) async {
    cancel.check();
    final path = target ? f.target : f.source;
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const ToolFailure('文件缺失或变成链接，已跳过。');
    }
    if ((await File(path).length()) != f.size ||
        await archiveHash(File(path), cancel) != f.hash) {
      throw const ToolFailure('内容已变化，禁止执行或撤销。');
    }
  }

  Future<void> _copyExclusive(PlannedFile f, TaskCancellation cancel) async {
    final target = File(f.target);
    await target.create(exclusive: true);
    var complete = false;
    try {
      final out = await target.open(mode: FileMode.writeOnly);
      try {
        await for (final chunk in File(f.source).openRead()) {
          cancel.check();
          await out.writeFrom(chunk);
        }
        await out.flush();
      } finally {
        await out.close();
      }
      await _check(f, cancel, target: true);
      complete = true;
    } finally {
      if (!complete && await target.exists()) await target.delete();
    }
  }

  Future<ToolRecord> execute(
    ArchivePlan plan,
    TaskCancellation cancel, {
    required bool confirmed,
    FutureOr<void> Function(int, int)? onProgress,
  }) async {
    if (!confirmed || !plan.valid) throw const ToolFailure('操作计划无效或尚未确认。');
    if (_busy) throw const ToolFailure('另一个文件操作正在执行。');
    _busy = true;
    try {
      if (plan.operation == 'rename_staged') {
        return await _executeStagedRename(plan, cancel, onProgress);
      }
      final logs = <Map<String, dynamic>>[];
      var journal = await store.create(
        'archive_operation',
        '文件${plan.operation}',
        data: {'operation': plan.operation, 'status': 'running', 'items': logs},
      );
      for (final f in plan.files) {
        if (cancel.cancelled) break;
        final entry = <String, dynamic>{...f.toJson(), 'status': 'pending'};
        logs.add(entry);
        journal = await store.save(
          journal.copyWith(data: {...journal.data, 'items': logs}),
        );
        try {
          await _check(f, cancel);
          if (await FileSystemEntity.type(f.target, followLinks: false) !=
              FileSystemEntityType.notFound) {
            throw const ToolFailure('目标已存在，禁止覆盖。');
          }
          // Only selected destinations and generated category subdirectories are created.
          final parent = Directory(p.dirname(f.target));
          if (!await parent.exists()) await parent.create(recursive: true);
          final canonical = await parent.resolveSymbolicLinks();
          if (archivePathKey(canonical) !=
              archivePathKey(p.normalize(p.absolute(parent.path)))) {
            throw const ToolFailure('目标父目录包含链接，已拒绝。');
          }
          if (plan.operation == 'copy') {
            await _copyExclusive(f, cancel);
          } else {
            // Native MoveFileW never replaces an existing target. Cross-volume moves
            // are explicitly reported, so no implicit delete/copy fallback happens.
            await _mover(f.source, f.target);
          }
          entry['status'] = 'done';
        } catch (e) {
          entry['status'] = 'failed';
          entry['message'] = e is ToolFailure
              ? e.message
              : '文件操作失败（权限、跨卷移动或路径变化）。';
        }
        journal = await store.save(
          journal.copyWith(data: {...journal.data, 'items': logs}),
        );
        await onProgress?.call(logs.length, plan.files.length);
      }
      return await store.save(
        journal.copyWith(
          data: {
            ...journal.data,
            'items': logs,
            'status': cancel.cancelled ? 'cancelled' : 'finished',
            'requested': plan.files.length,
          },
        ),
      );
    } finally {
      _busy = false;
    }
  }

  Future<ToolRecord> undo(ToolRecord journal, {required bool confirmed}) async {
    if (!confirmed) throw const ToolFailure('撤销需要确认。');
    if (_busy) throw const ToolFailure('另一个文件任务正在执行。');
    _busy = true;
    try {
      if (journal.text('operation') == 'rename_staged') {
        return await _undoStagedRename(journal);
      }
      final items = (journal.data['items'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      for (final entry in items.reversed.where((e) => e['status'] == 'done')) {
        final f = PlannedFile.fromJson(entry);
        try {
          await _check(f, TaskCancellation(), target: true);
          if (journal.text('operation') == 'copy') {
            // Keep the copy: undo is a reversible move into an owned recovery
            // directory beside the destination, never deletion of user contents.
            final recovery = Directory(
              p.join(p.dirname(f.target), '.links-toolbox-recovery'),
            );
            await recovery.create();
            await _mover(
              f.target,
              p.join(recovery.path, '${newId()}_${p.basename(f.target)}'),
            );
          } else {
            if (await FileSystemEntity.type(f.source, followLinks: false) !=
                FileSystemEntityType.notFound) {
              throw const ToolFailure('原路径已被占用，不能撤销。');
            }
            final parent = Directory(p.dirname(f.source));
            if (!await parent.exists() ||
                archivePathKey(await parent.resolveSymbolicLinks()) !=
                    archivePathKey(p.normalize(p.absolute(parent.path)))) {
              throw const ToolFailure('原父目录发生变化，不能撤销。');
            }
            await _mover(f.target, f.source);
          }
          entry['status'] = 'undone';
        } catch (e) {
          entry['undoError'] = e is ToolFailure ? e.message : '撤销失败，文件保持当前位置。';
        }
        journal = await store.save(
          journal.copyWith(data: {...journal.data, 'items': items}),
        );
      }
      return journal;
    } finally {
      _busy = false;
    }
  }

  Future<void> _realParent(String path) async {
    final parent = Directory(p.dirname(path));
    if (!await parent.exists() ||
        archivePathKey(await parent.resolveSymbolicLinks()) !=
            archivePathKey(p.normalize(p.absolute(parent.path)))) {
      throw const ToolFailure('父目录缺失或包含链接，拒绝操作。');
    }
  }

  Future<void> _verifyAt(
    Map<String, dynamic> entry,
    String path,
    TaskCancellation cancel,
  ) => _check(
    PlannedFile(
      path,
      path,
      entry['size'] as int,
      DateTime.parse(entry['modified'] as String),
      entry['hash'] as String,
    ),
    cancel,
  );

  Future<ToolRecord> _executeStagedRename(
    ArchivePlan plan,
    TaskCancellation cancel,
    FutureOr<void> Function(int, int)? progress,
  ) async {
    final entries = plan.files
        .map(
          (f) => <String, dynamic>{
            ...f.toJson(),
            'status': 'planned',
            'temporary': p.join(
              p.dirname(f.source),
              '.links-rename-${newId()}.tmp',
            ),
          },
        )
        .toList();
    var journal = await store.create(
      'archive_operation',
      '批量重命名（两阶段）',
      data: {
        'operation': 'rename_staged',
        'status': 'running',
        'requested': entries.length,
        'items': entries,
      },
    );
    Future<void> persist() async {
      journal = await store.save(
        journal.copyWith(data: {...journal.data, 'items': entries}),
      );
    }

    try {
      final sourceKeys = plan.files
              .map((f) => archivePathKey(f.source))
              .toSet(),
          targetKeys = <String>{};
      for (final f in plan.files) {
        await _check(f, cancel);
        await _realParent(f.source);
        await _realParent(f.target);
        if (p.dirname(f.source) != p.dirname(f.target) ||
            !validArchiveName(p.basename(f.target)) ||
            !targetKeys.add(archivePathKey(f.target))) {
          throw const ToolFailure('重命名目标无效或重复。');
        }
        if (await FileSystemEntity.type(f.target, followLinks: false) !=
                FileSystemEntityType.notFound &&
            !sourceKeys.contains(archivePathKey(f.target))) {
          throw const ToolFailure('预览后目标被占用，请重新生成计划。');
        }
      }
      for (final e in entries) {
        cancel.check();
        e['status'] = 'staging';
        await persist();
        await _verifyAt(e, e['source'] as String, cancel);
        await _mover(e['source'] as String, e['temporary'] as String);
        e['status'] = 'staged';
        await persist();
      }
      var done = 0;
      for (final e in entries) {
        cancel.check();
        e['status'] = 'committing';
        await persist();
        await _verifyAt(e, e['temporary'] as String, cancel);
        await _realParent(e['target'] as String);
        await _mover(e['temporary'] as String, e['target'] as String);
        await _verifyAt(e, e['target'] as String, cancel);
        e['status'] = 'done';
        await persist();
        await progress?.call(++done, entries.length);
      }
      return await store.save(
        journal.copyWith(
          data: {...journal.data, 'status': 'finished', 'items': entries},
        ),
      );
    } catch (error) {
      // Keep exact journal references. Cancellation never deletes or guesses at
      // temporary files; the same conditional undo handles partial execution.
      return await store.save(
        journal.copyWith(
          data: {
            ...journal.data,
            'items': entries,
            'status': cancel.cancelled ? 'cancelled' : 'failed',
            'error': error is ToolFailure
                ? error.message
                : '文件被占用、权限不足或路径变化；可检查记录后撤销。',
          },
        ),
      );
    }
  }

  Future<ToolRecord> _undoStagedRename(ToolRecord journal) async {
    // Refresh so a second click never replays a stale journal.
    journal = (await store.get(journal.id))!;
    final entries = (journal.data['items'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final pending = <Map<String, dynamic>>[];
    final locations = <String>{};
    Future<bool> exists(String path) async =>
        await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.notFound;
    Future<void> persist() async {
      journal = await store.save(
        journal.copyWith(data: {...journal.data, 'items': entries}),
      );
    }

    try {
      for (final e in entries) {
        final state = e['status'];
        if (state == 'planned' || state == 'undone') continue;
        String current;
        if (state == 'done') {
          current = e['target'] as String;
        } else if (state == 'staging') {
          current = await exists(e['temporary'] as String)
              ? e['temporary'] as String
              : e['source'] as String;
        } else if (state == 'staged' || state == 'committing') {
          current = await exists(e['temporary'] as String)
              ? e['temporary'] as String
              : e['target'] as String;
        } else if (state == 'undoStaging') {
          current = await exists(e['undoTemporary'] as String)
              ? e['undoTemporary'] as String
              : e['undoFrom'] as String;
        } else if (state == 'undoStaged' || state == 'undoCommitting') {
          current = await exists(e['undoTemporary'] as String)
              ? e['undoTemporary'] as String
              : e['source'] as String;
        } else {
          throw const ToolFailure('记录状态未知，请人工检查日志。');
        }
        await _verifyAt(e, current, TaskCancellation());
        await _realParent(current);
        await _realParent(e['source'] as String);
        e['undoFrom'] = current;
        if (p.normalize(current) == p.normalize(e['source'] as String)) {
          e['status'] = 'undone';
          continue;
        }
        locations.add(archivePathKey(current));
        pending.add(e);
      }
      // Validate every original location before moving anything, including cycles.
      for (final e in pending) {
        if (await exists(e['source'] as String) &&
            !locations.contains(archivePathKey(e['source'] as String))) {
          throw const ToolFailure('原名称已被其他文件占用，未执行撤销。');
        }
      }
      for (final e in pending) {
        final from = e['undoFrom'] as String;
        final staging = e['undoTemporary'] as String?;
        if (staging != null && p.equals(staging, from)) continue;
        e['undoTemporary'] = p.join(
          p.dirname(from),
          '.links-undo-${newId()}.tmp',
        );
        e['status'] = 'undoStaging';
        await persist();
        await _verifyAt(e, from, TaskCancellation());
        await _mover(from, e['undoTemporary'] as String);
        e['status'] = 'undoStaged';
        await persist();
      }
      for (final e in pending) {
        e['status'] = 'undoCommitting';
        await persist();
        await _verifyAt(e, e['undoTemporary'] as String, TaskCancellation());
        await _mover(e['undoTemporary'] as String, e['source'] as String);
        e['status'] = 'undone';
        e.remove('undoError');
        await persist();
      }
      return await store.save(
        journal.copyWith(
          data: {...journal.data, 'status': 'undone', 'items': entries},
        ),
      );
    } catch (error) {
      return await store.save(
        journal.copyWith(
          data: {
            ...journal.data,
            'items': entries,
            'undoError': error is ToolFailure
                ? error.message
                : '撤销失败，实际位置保存在记录中，修复占用后可重试。',
          },
        ),
      );
    }
  }
}
