import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/storage/utility_files.dart';
import 'controlled_worker.dart';
import 'data_formatter_service.dart';
import 'hash_service.dart';

const workflowSteps = {'copy', 'json-format', 'json-minify', 'yaml-json'};

/// A form-defined data pipeline, never a command/shell interpreter. Formatters
/// and checksum implementations are shared with the standalone tools.
class LocalWorkflowService {
  LocalWorkflowService(this.store, this.files);
  final RecordStore store;
  final UtilityFileService files;
  Future<ToolRecord> run(
    String input,
    String destination,
    List<String> steps,
    UtilityJobContext job,
  ) async {
    if (steps.isEmpty ||
        steps.length > 8 ||
        steps.any((s) => !workflowSteps.contains(s))) {
      throw const ToolFailure('工作流包含无效步骤。');
    }
    final source = File(input), before = await source.stat();
    if (before.type != FileSystemEntityType.file ||
        before.size > 1024 * 1024 * 1024) {
      throw const ToolFailure('请选择不超过1GiB的普通文件。');
    }
    await files.selectedDirectory(destination);
    job.check();
    final temp = await Directory.systemTemp.createTemp('kado-workflow-'),
        work = File(p.join(temp.path, 'input.bin'));
    final cancel = DevCancellation();
    job.onCancel(() async => cancel.cancel());
    try {
      final sink = await work.open(mode: FileMode.writeOnly);
      var count = 0;
      try {
        await for (final chunk in source.openRead()) {
          job.check();
          await sink.writeFrom(chunk);
          count += chunk.length;
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      final after = await source.stat();
      if (count != before.size ||
          after.size != before.size ||
          after.modified != before.modified) {
        throw const ToolFailure('输入在复制期间发生变化。');
      }
      for (var i = 0; i < steps.length; i++) {
        job.check();
        await job.progress(
          i,
          steps.length + 2,
          currentFile: steps[i],
          force: true,
        );
        if (steps[i] == 'copy') continue;
        if (await work.length() > 2 * 1024 * 1024) {
          throw const ToolFailure('格式转换步骤输入最多2MiB；直接复制/哈希可处理更大文件。');
        }
        final task = ControlledWorker(formatData, {
          'text': await work.readAsString(),
          'mode': switch (steps[i]) {
            'json-minify' => 'minify',
            'yaml-json' => 'yaml-json',
            _ => 'format',
          },
        }, timeout: const Duration(seconds: 5));
        job.onCancel(() async => task.cancel());
        final result = await task.result as Map;
        job.check();
        await work.writeAsString(result['text'] as String, flush: true);
      }
      await job.progress(
        steps.length,
        steps.length + 2,
        currentFile: 'SHA-256 / SHA-512',
        force: true,
      );
      final hashes = await hashFile(work, cancel);
      job.check();
      final name =
          'workflow-${DateTime.now().microsecondsSinceEpoch}-${p.basenameWithoutExtension(input).substring(0, p.basenameWithoutExtension(input).length.clamp(0, 80))}${steps.any((s) => s != 'copy') ? '.json' : p.extension(input)}';
      final exported = await files.exportFile(
        destination,
        name,
        work,
        job.cancellation,
      );
      job.check();
      final record = await store.create(
        'workflow_result',
        name,
        data: {
          'path': exported.path,
          'size': hashes.size,
          'sha256': hashes.sha256,
          'sha512': hashes.sha512,
          'steps': steps,
          'syncAllowed': false,
          'isSensitive': true,
        },
      );
      await job.output(record.id);
      await job.progress(
        steps.length + 2,
        steps.length + 2,
        currentFile: '已导出并校验',
        force: true,
      );
      return record;
    } finally {
      if (await work.exists()) await work.delete();
      await temp.delete();
    }
  }
}
