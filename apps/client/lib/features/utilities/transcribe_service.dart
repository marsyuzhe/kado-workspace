import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/jobs/utility_process.dart';
import '../../core/storage/utility_files.dart';
import '../archive/archive_service.dart';
import 'media_converter.dart';

class SpeechModelSpec {
  const SpeechModelSpec(
    this.id,
    this.sha1,
    this.diskMiB,
    this.memoryMiB, {
    this.englishOnly = false,
  });
  final String id, sha1;
  final int diskMiB, memoryMiB;
  final bool englishOnly;
}

const speechModels = [
  SpeechModelSpec('tiny', 'bd577a113a864445d4c299885e0cb97d4ba92b5f', 75, 273),
  SpeechModelSpec(
    'tiny.en',
    'c78c86eb1a8faa21b369bcd33207cc90d64ae9df',
    75,
    273,
    englishOnly: true,
  ),
  SpeechModelSpec('base', '465707469ff3a37a2b9b8d8f89f2f99de7299dac', 142, 388),
  SpeechModelSpec(
    'base.en',
    '137c40403d78fd54d454da0f9bd998f78703390c',
    142,
    388,
    englishOnly: true,
  ),
];

class WhisperRuntimeService {
  WhisperRuntimeService(this.store, this.mediaRuntime);
  final RecordStore store;
  final MediaRuntimeService mediaRuntime;
  Future<Map<String, dynamic>> inspect(String path) =>
      mediaRuntime.inspect(path, executables: {'whisper-cli.exe'});
  Future<ToolRecord> trust(
    Map<String, dynamic> preview, {
    required bool confirmed,
  }) async {
    if (!confirmed) throw const ToolFailure('本地识别执行器需要确认来源与指纹。');
    final current = await inspect(preview['directory'] as String);
    if (jsonEncode(current) != jsonEncode(preview)) {
      throw const ToolFailure('执行器检查后变化。');
    }
    final version = await boundedProcess(
      p.join(current['directory'] as String, 'whisper-cli.exe'),
      ['--version'],
      combined: true,
    );
    if (!version.contains('whisper.cpp version:')) {
      throw const ToolFailure('需要支持--version的whisper.cpp执行器。');
    }
    final previous = await store.find('utility_runtime', 'engine', 'whisper');
    final data = {
      ...current,
      'engine': 'whisper',
      'version': version.trim(),
      'syncAllowed': false,
      'isSensitive': true,
    };
    return previous == null
        ? store.create('utility_runtime', '本地语音识别执行器', data: data)
        : store.save(previous.copyWith(data: data));
  }

  Future<ToolRecord> verified() async {
    final row = await store.find('utility_runtime', 'engine', 'whisper');
    if (row == null) throw const ToolFailure('请先验证whisper.cpp执行器目录。');
    final current = await inspect(row.text('directory'));
    if (jsonEncode(current['checksums']) != jsonEncode(row.data['checksums'])) {
      throw const ToolFailure('识别执行器或DLL指纹变化，必须重新验证。');
    }
    return row;
  }
}

class SpeechModelManager {
  SpeechModelManager(this.store, this.files, this.root);
  final RecordStore store;
  final UtilityFileService files;
  final Future<Directory> Function() root;
  Future<Directory> directory() async {
    final dir = Directory(p.join((await root()).path, 'speech-models'));
    await dir.create(recursive: true);
    return files.selectedDirectory(dir.path);
  }

  Future<ToolRecord> importModel(
    String inputPath,
    SpeechModelSpec spec,
    UtilityJobContext job,
  ) async {
    if (!speechModels.contains(spec)) throw const ToolFailure('请选择已登记校验值的模型。');
    final source = File(inputPath);
    if (!p.isAbsolute(inputPath) ||
        await FileSystemEntity.type(inputPath, followLinks: false) !=
            FileSystemEntityType.file ||
        await source.length() < 50 * 1024 * 1024 ||
        await source.length() > 200 * 1024 * 1024) {
      throw const ToolFailure('需要完整tiny/base模型文件，50–200MB；测试空模型不支持。');
    }
    job.check();
    await job.progress(0, 1, currentFile: '校验${spec.id}模型', force: true);
    final hash =
        (await sha1
                .bind(
                  source.openRead().map((chunk) {
                    job.check();
                    return chunk;
                  }),
                )
                .first)
            .toString();
    if (hash != spec.sha1) throw const ToolFailure('模型与官方登记SHA1不匹配，未导入。');
    final existing = await store.find('speech_model', 'modelId', spec.id);
    if (existing != null) {
      var valid = false;
      try {
        await verify(existing);
        valid = true;
      } on ToolFailure {
        /* A restore may contain metadata without the optional model. */
      }
      if (valid) {
        await job.output(existing.id);
        await job.progress(1, 1, force: true);
        return existing;
      }
    }
    final target = await files.exportFile(
      (await directory()).path,
      '${newId()}.bin',
      source,
      job.cancellation,
    );
    ToolRecord row;
    try {
      final copiedHash = (await sha1.bind(target.openRead()).first).toString();
      if (copiedHash != spec.sha1) throw const ToolFailure('模型副本校验不匹配。');
      final data = <String, dynamic>{
        'payloadVersion': 1,
        'modelId': spec.id,
        'managedName': p.basename(target.path),
        'sha1': hash,
        'checksum': await archiveHash(target, job.cancellation),
        'size': await target.length(),
        'englishOnly': spec.englishOnly,
        'memoryMiB': spec.memoryMiB,
        'source': 'https://huggingface.co/ggerganov/whisper.cpp',
        'verified': true,
        'syncAllowed': false,
      };
      row = existing == null
          ? await store.create('speech_model', spec.id, data: data)
          : await store.save(existing.copyWith(data: data));
    } catch (_) {
      if (await target.exists()) await target.delete();
      rethrow;
    }
    await job.output(row.id);
    await job.progress(1, 1, currentFile: spec.id, force: true);
    return row;
  }

  Future<File> verify(ToolRecord row) async {
    if (row.kind != 'speech_model' ||
        !RegExp(r'^[0-9a-f-]{36}\.bin$').hasMatch(row.text('managedName'))) {
      throw const ToolFailure('模型引用无效。');
    }
    final file = File(
      p.join((await directory()).path, row.text('managedName')),
    );
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() != row.number('size') ||
        await archiveHash(file, TaskCancellation()) != row.text('checksum')) {
      throw const ToolFailure('模型缺失或指纹变化，请重新导入。');
    }
    return file;
  }

  Future<void> remove(ToolRecord row, {required bool confirmed}) async {
    if (!confirmed) throw const ToolFailure('删除模型副本需要确认。');
    for (final job in await store.list('utility_job', limit: 10000)) {
      if (!utilityJobStatus(job).terminal &&
          (job.data['inputReferences'] as Map?)?['modelId'] == row.id) {
        throw const ToolFailure('模型仍有排队/活动任务，先取消或等待完成。');
      }
    }
    final file = await verify(row);
    await file.delete();
    await store.delete(row);
  }
}

class TranscriptSegment {
  const TranscriptSegment(this.startMs, this.endMs, this.text);
  final int startMs, endMs;
  final String text;
  Map<String, dynamic> toJson() => {
    'startMs': startMs,
    'endMs': endMs,
    'text': text,
  };
  factory TranscriptSegment.fromJson(Map value) => TranscriptSegment(
    value['startMs'] as int,
    value['endMs'] as int,
    value['text'] as String,
  );
}

List<TranscriptSegment> transcriptSegments(ToolRecord row) =>
    (row.data['segments'] as List? ?? [])
        .map((v) => TranscriptSegment.fromJson(v as Map))
        .toList();

class TranscriptRepository {
  TranscriptRepository(this.store);
  final RecordStore store;
  static void validate(List<TranscriptSegment> segments) {
    if (segments.length > 10000 ||
        segments.fold<int>(0, (n, s) => n + s.text.length) > 500000) {
      throw const ToolFailure('转写结果超过本版可编辑上限。');
    }
    var end = 0;
    for (final s in segments) {
      if (s.text.length > 5000) {
        throw const ToolFailure('单条字幕超过5000字符，请拆分录音或字幕。');
      }
      if (s.startMs < end ||
          s.endMs <= s.startMs ||
          s.endMs > 24 * 3600 * 1000 ||
          s.text.trim().isEmpty ||
          s.text.contains('-->')) {
        throw const ToolFailure('字幕需按时间排序且不重叠、结束晚于开始、内容非空且不含-->。');
      }
      end = s.endMs;
    }
  }

  Future<ToolRecord> revise(
    ToolRecord row,
    List<TranscriptSegment> segments,
  ) async {
    if (row.kind != 'transcript' || row.text('status') == 'processing') {
      throw const ToolFailure('请等待识别停止后编辑结果。');
    }
    validate(segments);
    return store.transaction(() async {
      await store.create(
        'transcript_revision',
        row.title,
        body: row.body,
        data: {
          'transcriptId': row.id,
          'originalRevision': row.revision,
          'segments': row.data['segments'],
          'language': row.text('language'),
          'syncAllowed': false,
          'isSensitive': true,
        },
      );
      return store.save(
        row.copyWith(
          body: segments.map((s) => s.text).join('\n'),
          data: {
            ...row.data,
            'segments': segments.map((s) => s.toJson()).toList(),
            'editedAt': DateTime.now().toUtc().toIso8601String(),
            'editCount': row.number('editCount') + 1,
          },
        ),
      );
    });
  }

  static String time(int ms, {bool vtt = false}) {
    final h = ms ~/ 3600000,
        m = (ms ~/ 60000) % 60,
        s = (ms ~/ 1000) % 60,
        millis = ms % 1000;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}${vtt ? '.' : ','}${millis.toString().padLeft(3, '0')}';
  }

  static String export(ToolRecord row, String format) {
    final segments = transcriptSegments(row);
    validate(segments);
    if (segments.isEmpty) throw const ToolFailure('没有可导出的识别内容。');
    if (format == 'json') {
      return const JsonEncoder.withIndent('  ').convert({
        'title': row.title,
        'language': row.text('language'),
        'model': row.text('modelName'),
        'createdAt': row.createdAt.toIso8601String(),
        'status': row.text('status'),
        'timingAdjustments': row.data['timingAdjustments'] ?? [],
        'segments': segments.map((s) => s.toJson()).toList(),
      });
    }
    if (format == 'txt') {
      return '${row.title}\n语言：${row.text('language')} · 模型：${row.text('modelName')}\n时间：${row.createdAt.toIso8601String()} · 状态：${row.text('status')}\n\n${segments.map((s) => s.text).join('\n')}\n';
    }
    if (!{'srt', 'vtt'}.contains(format)) {
      throw const ToolFailure('仅支持TXT/SRT/VTT/JSON。');
    }
    final out = StringBuffer(format == 'vtt' ? 'WEBVTT\n\n' : '');
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      out.writeln(
        '${i + 1}\n${time(s.startMs, vtt: format == 'vtt')} --> ${time(s.endMs, vtt: format == 'vtt')}\n${s.text.replaceAll(RegExp(r'\r\n?|\n{2,}'), '\n')}\n',
      );
    }
    return out.toString();
  }
}

class TranscribeService {
  TranscribeService(
    this.store,
    this.media,
    this.whisper,
    this.models,
    this.root,
  );
  final RecordStore store;
  final MediaConverterService media;
  final WhisperRuntimeService whisper;
  final SpeechModelManager models;
  final Future<Directory> Function() root;
  Future<ToolRecord> transcribe(
    String path,
    ToolRecord model,
    String language,
    UtilityJobContext job,
  ) async {
    if (!{
          'auto',
          'zh',
          'en',
          'ja',
          'ko',
          'fr',
          'de',
          'es',
        }.contains(language) ||
        model.flag('englishOnly') && !{'en', 'auto'}.contains(language)) {
      throw const ToolFailure('请选择此模型支持的语言；.en模型仅识别英文。');
    }
    final engine = await whisper.verified(),
        ffmpeg = await media.runtime.verified(),
        modelFile = await models.verify(model);
    final info = await media.probe(path, engine: ffmpeg),
        source = await media.selectedInput(path),
        before = await File(path).stat();
    if (!info.hasAudio || info.seconds > 7200) {
      throw const ToolFailure('需要含音频的媒体，首版单任务最多2小时，请先分段。');
    }
    final chunks = (info.seconds / 600).ceil(),
        segments = <TranscriptSegment>[];
    final timingAdjustments = <Map<String, dynamic>>[];
    final work = Directory(p.join((await root()).path, 'utility-work', job.id));
    await work.create(recursive: true);
    var row = await store.create(
      'transcript',
      p.basename(path),
      data: {
        'payloadVersion': 1,
        'status': 'processing',
        'jobId': job.id,
        'modelId': model.id,
        'modelName': model.title,
        'language': language,
        'sourcePath': path,
        'duration': info.seconds,
        'segments': [],
        'isSensitive': true,
        'syncAllowed': false,
      },
    );
    try {
      await job.output(row.id);
      await media.files.ensureSpace(work.path, 64 * 1024 * 1024);
      for (var i = 0; i < chunks; i++) {
        job.check();
        await job.progress(
          i,
          chunks,
          currentFile: '转码 第${i + 1}/$chunks段 · ${p.basename(path)}',
          force: true,
        );
        final wav = File(p.join(work.path, 'chunk-$i.wav')),
            output = p.join(work.path, 'result-$i');
        try {
          final decoded = await runUtilityProcess(
            p.join(ffmpeg.text('directory'), 'ffmpeg.exe'),
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
              '${i * 600}',
              '-i',
              source.path,
              '-t',
              '600',
              '-map',
              '0:a:0',
              '-vn',
              '-ac',
              '1',
              '-ar',
              '16000',
              '-c:a',
              'pcm_s16le',
              wav.path,
            ],
            job,
          );
          if (decoded.code != 0 ||
              !await wav.exists() ||
              await wav.length() <= 44) {
            await store.create(
              'utility_log',
              '音频解码错误',
              body: decoded.stderr,
              data: {
                'jobId': job.id,
                'syncAllowed': false,
                'isSensitive': true,
              },
            );
            throw const ToolFailure('音频解码失败，可能是未支持的AMR/SILK编码，未生成空白成功结果。');
          }
          await job.progress(
            i,
            chunks,
            currentFile: '本地识别 第${i + 1}/$chunks段',
            force: true,
          );
          final inference = await runUtilityProcess(
            p.join(engine.text('directory'), 'whisper-cli.exe'),
            [
              '-m',
              modelFile.path,
              '-f',
              wav.path,
              '-l',
              language,
              '-t',
              '4',
              '-ng',
              '-pp',
              '-ml',
              '120',
              '-sow',
              '-oj',
              '-of',
              output,
            ],
            job,
            onLine: (line, _) async {
              final match = RegExp(r'progress\s*=\s*(\d+)%').firstMatch(line);
              if (match != null) {
                await job.progress(
                  i,
                  chunks,
                  currentFile: '本地识别 第${i + 1}/$chunks段',
                  fraction: (i + int.parse(match[1]!) / 100) / chunks,
                );
              }
            },
          );
          if (inference.code != 0) {
            await store.create(
              'utility_log',
              '本地识别错误',
              body: inference.stderr,
              data: {
                'jobId': job.id,
                'syncAllowed': false,
                'isSensitive': true,
              },
            );
            throw const ToolFailure('模型加载或识别失败，请检查模型、CPU支持和可用内存。');
          }
          final result = File('$output.json');
          if (!await result.exists() ||
              await result.length() > 2 * 1024 * 1024) {
            throw const ToolFailure('识别输出缺失或超过2MB。');
          }
          final data = jsonDecode(await result.readAsString()) as Map;
          final recognized = (data['transcription'] as List? ?? []);
          for (final value in recognized) {
            final entry = value as Map,
                offsets = entry['offsets'] as Map,
                text = (entry['text'] as String).trim();
            if (text.isEmpty) continue;
            final start = (offsets['from'] as num).toInt() + i * 600000,
                end = (offsets['to'] as num).toInt() + i * 600000;
            if (start < 0 || end < start || end > info.seconds * 1000 + 1000) {
              throw const ToolFailure('执行器返回了无效字幕时间。');
            }
            // Whisper can emit overlapping/zero-duration token groups. Keep
            // words, use existing timing boundaries and disclose adjustments.
            final previous = segments.lastOrNull;
            if (previous != null && end <= previous.endMs) {
              segments[segments.length - 1] = TranscriptSegment(
                previous.startMs,
                previous.endMs,
                '${previous.text} $text',
              );
              timingAdjustments.add({
                'chunk': i,
                'rawStartMs': start,
                'rawEndMs': end,
                'action': 'merged-with-previous',
              });
            } else if (end > start) {
              final adjusted = previous != null && start < previous.endMs
                  ? previous.endMs
                  : start;
              if (adjusted != start) {
                timingAdjustments.add({
                  'chunk': i,
                  'rawStartMs': start,
                  'rawEndMs': end,
                  'action': 'clipped-overlap',
                });
              }
              segments.add(TranscriptSegment(adjusted, end, text));
            } else {
              throw const ToolFailure('首条字幕没有有效时间范围，结果需人工检查。');
            }
          }
          TranscriptRepository.validate(segments);
          row = await store.save(
            row.copyWith(
              body: segments.map((s) => s.text).join('\n'),
              data: {
                ...row.data,
                'segments': segments.map((s) => s.toJson()).toList(),
                'language': (data['result'] as Map?)?['language'] ?? language,
                'completedChunks': i + 1,
                'totalChunks': chunks,
                'timingAdjustmentCount': timingAdjustments.length,
                'timingAdjustments': timingAdjustments,
              },
            ),
          );
          await job.progress(
            i + 1,
            chunks,
            currentFile: p.basename(path),
            force: true,
          );
        } finally {
          for (final file in [wav, File('$output.json')]) {
            if (await file.exists()) await file.delete();
          }
        }
      }
      job.check();
      final after = await source.stat();
      if (after.size != before.size || after.modified != before.modified) {
        throw const ToolFailure('识别期间源文件变化，结果保留为未完成。');
      }
      if (segments.isEmpty) throw const ToolFailure('未检测到可识别语音；未把空白结果当作成功。');
      return await store.save(
        row.copyWith(
          data: {
            ...row.data,
            'status': 'complete',
            'finishedAt': DateTime.now().toUtc().toIso8601String(),
          },
        ),
      );
    } catch (error) {
      await store.save(
        row.copyWith(
          data: {
            ...row.data,
            'status': job.cancellation.cancelled ? 'cancelled' : 'failed',
            'error': error is ToolFailure ? error.message : '识别或保存失败，已完成分段保留。',
          },
        ),
      );
      rethrow;
    } finally {
      if (await work.exists() && await work.list().isEmpty) await work.delete();
    }
  }
}
