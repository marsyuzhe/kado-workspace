import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/platform/system_actions.dart';
import '../../core/storage/utility_files.dart';
import '../archive/archive_service.dart';
import 'game_archive_worker.dart' show safeGameRelative;

/// LocalSend remains a separately installed, user-confirmed application.
/// This service never claims remote delivery or opens a listening socket.
class LanTransferService {
  LanTransferService(this.store, this.files, this.native);
  final RecordStore store;
  final UtilityFileService files;
  final NativePlatformAdapter native;
  Future<File> selectedFile(String path) async {
    if (!p.isAbsolute(path) ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const ToolFailure('请选择可访问的本地文件，不接受链接。');
    }
    final file = File(path);
    if (archivePathKey(await file.resolveSymbolicLinks()) !=
        archivePathKey(p.normalize(path))) {
      throw const ToolFailure('文件父路径包含链接，请重新选择实际位置。');
    }
    return file;
  }

  Future<List<File>> _runtimeFiles(String executable) async {
    final root = File(executable).parent;
    final result = <File>[
      await selectedFile(executable),
      await selectedFile(p.join(root.path, 'data', 'app.so')),
    ];
    await for (final item in root.list(followLinks: false)) {
      if (p.extension(item.path).toLowerCase() == '.dll') {
        result.add(await selectedFile(item.path));
      }
      if (result.length > 100) {
        throw const ToolFailure('外部应用目录含过多DLL，请使用独立官方安装目录。');
      }
    }
    if (!result.any(
      (f) => p.basename(f.path).toLowerCase() == 'flutter_windows.dll',
    )) {
      throw const ToolFailure('LocalSend运行目录不完整。');
    }
    var total = 0;
    for (final file in result) {
      total += await file.length();
    }
    if (total > 200 * 1024 * 1024) {
      throw const ToolFailure('外部应用可执行组件超过200MiB限制。');
    }
    result.sort((a, b) => a.path.compareTo(b.path));
    return result;
  }

  Future<ToolRecord> configure(String path, UtilityJobContext job) async {
    final file = await selectedFile(path);
    if (!{
      'localsend_app.exe',
      'localsend.exe',
    }.contains(p.basename(path).toLowerCase())) {
      throw const ToolFailure('请选择从官方渠道安装的LocalSend图形应用EXE。');
    }
    final before = await file.stat(),
        hash = await archiveHash(file, job.cancellation);
    final metadata = await native.installerMetadata(path),
        after = await file.stat();
    if (before.size != after.size || before.modified != after.modified) {
      throw const ToolFailure('核对期间应用文件变化。');
    }
    if (!(metadata['name']?.toString().toLowerCase().contains('localsend') ??
        false)) {
      throw const ToolFailure('Windows产品名称未识别为LocalSend，请选择官方图形应用。');
    }
    final fingerprints = <String, String>{};
    for (final component in await _runtimeFiles(path)) {
      job.check();
      fingerprints[p.posix.fromUri(
        p.toUri(p.relative(component.path, from: file.parent.path)),
      )] = await archiveHash(
        component,
        job.cancellation,
      );
    }
    final row = await store.create(
      'transfer_runtime',
      'LocalSend（外部应用）',
      data: {
        'path': path,
        'sha256': hash,
        'fingerprints': fingerprints,
        'size': before.size,
        'version': metadata['version'] ?? '',
        'signatureStatus': metadata['signatureStatus'] ?? 'unverified',
        'publisher': metadata['publisher'] ?? '',
        'source': '用户选择；产品名称不是身份担保，首次启动前请核对官方来源。',
        'syncAllowed': false,
        'isSensitive': true,
      },
    );
    await job.output(row.id);
    return row;
  }

  Future<ToolRecord> prepare(
    List<String> paths,
    UtilityJobContext job, {
    String? directory,
  }) async {
    final inputs = <({String source, String name})>[];
    if (directory != null) {
      final root = await files.selectedDirectory(directory),
          scan = await ArchiveScanner().scan(
            root.path,
            job.cancellation,
            limit: 1001,
          );
      if (scan.limited || scan.errors.isNotEmpty || scan.files.length > 1000) {
        throw const ToolFailure('文件夹不可完整读取或超过1000文件。');
      }
      for (final file in scan.files) {
        inputs.add((
          source: file.path,
          name: p.posix.fromUri(
            p.toUri(p.relative(file.path, from: root.path)),
          ),
        ));
      }
    } else {
      if (paths.isEmpty || paths.length > 25) {
        throw const ToolFailure('单次选择1–25文件；文件夹可生成最多1000文件的校验清单。');
      }
      for (final path in paths) {
        inputs.add((source: path, name: p.basename(path)));
      }
    }
    if (inputs.isEmpty) {
      throw const ToolFailure('输入没有可校验文件。');
    }
    var total = 0;
    final entries = <Map<String, dynamic>>[], names = <String>{};
    for (var i = 0; i < inputs.length; i++) {
      job.check();
      final item = inputs[i];
      if (!safeGameRelative(item.name) || !names.add(item.name.toLowerCase())) {
        throw const ToolFailure('文件名无效或接收相对路径重名，请分开准备。');
      }
      final file = await selectedFile(item.source), before = await file.stat();
      total += before.size;
      if (total > 20 * 1024 * 1024 * 1024) {
        throw const ToolFailure('单次校验清单最多20GiB。');
      }
      await job.progress(i, inputs.length, currentFile: item.name, force: true);
      final hash = await archiveHash(file, job.cancellation),
          after = await file.stat();
      if (before.size != after.size || before.modified != after.modified) {
        throw const ToolFailure('计算哈希期间源文件变化，请重新准备。');
      }
      entries.add({
        'name': item.name,
        'source': file.path,
        'size': before.size,
        'sha256': hash,
        'modified': before.modified.toUtc().toIso8601String(),
      });
      await job.progress(
        i + 1,
        inputs.length,
        currentFile: item.name,
        force: true,
      );
    }
    final row = await store.create(
      'transfer_manifest',
      '${directory == null ? '文件' : '文件夹'}发送校验清单',
      data: {
        'schemaVersion': 1,
        'status': 'prepared',
        'files': entries,
        'fileCount': entries.length,
        'totalBytes': total,
        'directory': directory ?? '',
        'deliveryConfirmed': false,
        'syncAllowed': false,
        'isSensitive': true,
      },
    );
    await job.output(row.id);
    return row;
  }

  Map<String, dynamic> publicManifest(ToolRecord row) {
    if (row.kind != 'transfer_manifest') {
      throw const ToolFailure('清单记录无效。');
    }
    return {
      'schemaVersion': 1,
      'manifestId': row.id,
      'createdAt': row.createdAt.toUtc().toIso8601String(),
      'files': [
        for (final raw in row.data['files'] as List)
          {
            for (final key in ['name', 'size', 'sha256'])
              key: (raw as Map)[key],
          },
      ],
      'totalBytes': row.number('totalBytes'),
    };
  }

  Future<ToolRecord> export(
    ToolRecord row,
    String directory,
    UtilityJobContext job,
  ) async {
    final output = await files.exportBytes(
      directory,
      'Links-transfer-${row.id}.json',
      Uint8List.fromList(
        utf8.encode(
          const JsonEncoder.withIndent('  ').convert(publicManifest(row)),
        ),
      ),
      job.cancellation,
    );
    final result = await store.create(
      'transfer_export',
      '发送清单JSON',
      data: {
        'outputPath': output.path,
        'checksum': await archiveHash(output, job.cancellation),
        'manifestId': row.id,
        'syncAllowed': false,
        'isSensitive': true,
      },
    );
    await job.output(result.id);
    return result;
  }

  Map<String, dynamic> parseManifest(String text) {
    if (utf8.encode(text).length > 2 * 1024 * 1024) {
      throw const ToolFailure('校验清单超过2MiB。');
    }
    Map<String, dynamic> json;
    try {
      json = Map<String, dynamic>.from(jsonDecode(text) as Map);
    } catch (_) {
      throw const ToolFailure('校验清单必须是UTF-8 JSON对象。');
    }
    if (json['schemaVersion'] != 1 ||
        json['files'] is! List ||
        (json['files'] as List).isEmpty ||
        (json['files'] as List).length > 1000) {
      throw const ToolFailure('不支持的清单格式或文件数量。');
    }
    final seen = <String>{};
    var total = 0;
    for (final raw in json['files'] as List) {
      if (raw is! Map ||
          raw['name'] is! String ||
          !safeGameRelative(raw['name'] as String) ||
          !seen.add((raw['name'] as String).toLowerCase()) ||
          raw['size'] is! int ||
          (raw['size'] as int) < 0 ||
          raw['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['sha256'] as String)) {
        throw const ToolFailure('清单含非法路径、重名、大小或SHA256。');
      }
      total += raw['size'] as int;
    }
    if (total > 20 * 1024 * 1024 * 1024 || json['totalBytes'] != total) {
      throw const ToolFailure('清单总大小不一致或超出20GiB。');
    }
    return json;
  }

  Future<ToolRecord> verifyReceived(
    String manifestPath,
    String directory,
    UtilityJobContext job,
  ) async {
    final file = await selectedFile(manifestPath);
    if (await file.length() > 2 * 1024 * 1024) {
      throw const ToolFailure('清单超过2MiB。');
    }
    final manifest = parseManifest(await file.readAsString()),
        root = await files.selectedDirectory(directory),
        entries = manifest['files'] as List;
    final results = <Map<String, dynamic>>[];
    for (var i = 0; i < entries.length; i++) {
      job.check();
      final entry = entries[i] as Map, name = entry['name'] as String;
      final target = p.normalize(p.join(root.path, p.fromUri(Uri(path: name))));
      if (!p.isWithin(root.path, target)) {
        throw const ToolFailure('接收校验路径越界。');
      }
      var status = 'missing';
      if (await FileSystemEntity.type(target, followLinks: false) ==
          FileSystemEntityType.file) {
        final received = await selectedFile(target),
            before = await received.stat();
        status =
            before.size == entry['size'] &&
                await archiveHash(received, job.cancellation) == entry['sha256']
            ? 'match'
            : 'mismatch';
        final after = await received.stat();
        if (before.size != after.size || before.modified != after.modified) {
          status = 'changed-during-check';
        }
      }
      results.add({'name': name, 'status': status});
      await job.progress(i + 1, entries.length, currentFile: name, force: true);
    }
    final matched = results.where((r) => r['status'] == 'match').length;
    final row = await store.create(
      'transfer_verification',
      '接收后SHA256核验',
      data: {
        'status': matched == entries.length ? 'verified' : 'mismatch',
        'matched': matched,
        'fileCount': entries.length,
        'results': results,
        'directory': root.path,
        'manifestId': manifest['manifestId'] ?? '',
        'message': '仅证明所选目录内容与清单一致；清单本身需通过可信渠道核对。未验证设备身份。',
        'syncAllowed': false,
        'isSensitive': true,
      },
    );
    await job.output(row.id);
    return row;
  }

  Future<TargetAction> handoff(
    ToolRecord runtime,
    ToolRecord manifest,
    UtilityJobContext job,
  ) async {
    if (runtime.kind != 'transfer_runtime' ||
        manifest.kind != 'transfer_manifest') {
      throw const ToolFailure('外部应用或清单无效。');
    }
    final exe = await selectedFile(runtime.text('path'));
    if (await exe.length() != runtime.number('size') ||
        await archiveHash(exe, job.cancellation) != runtime.text('sha256')) {
      throw const ToolFailure('LocalSend应用文件变化，请重新配置并核对来源。');
    }
    final expected = runtime.data['fingerprints'];
    if (expected is! Map || expected.isEmpty) {
      throw const ToolFailure('缺少运行组件指纹，请重新配置LocalSend。');
    }
    final components = await _runtimeFiles(exe.path);
    if (components.length != expected.length) {
      throw const ToolFailure('LocalSend组件集合变化，请重新配置。');
    }
    for (final component in components) {
      final name = p.posix.fromUri(
        p.toUri(p.relative(component.path, from: exe.parent.path)),
      );
      if (await archiveHash(component, job.cancellation) != expected[name]) {
        throw const ToolFailure('LocalSend组件变化，请重新配置并核对来源。');
      }
    }
    final paths = <String>[];
    for (final raw in manifest.data['files'] as List) {
      final entry = raw as Map,
          file = await selectedFile(entry['source'] as String);
      if (await file.length() != entry['size'] ||
          await archiveHash(file, job.cancellation) != entry['sha256']) {
        throw const ToolFailure('发送源文件变化，请重新生成校验清单。');
      }
      paths.add(file.path);
    }
    // Folder trees are selected inside LocalSend to preserve their layout.
    // File arguments are the upstream GUI's documented positional path inputs.
    final action = TargetAction(
      'application',
      exe.path,
      arguments: manifest.text('directory').isEmpty ? paths : const [],
    );
    action.validate();
    return action;
  }

  Future<void> recordHandoff(ToolRecord row) async {
    final latest = await store.get(row.id);
    if (latest == null || latest.kind != 'transfer_manifest') {
      throw const ToolFailure('发送清单已不存在。');
    }
    await store.save(
      latest.copyWith(
        data: {
          ...latest.data,
          'status': 'external-opened',
          'deliveryConfirmed': false,
          'externalOpenedAt': DateTime.now().toUtc().toIso8601String(),
        },
      ),
    );
  }
}
