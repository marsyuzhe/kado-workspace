import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/storage/utility_files.dart';
import '../archive/archive_service.dart';

const mediaExtensions = {
  'wav',
  'mp3',
  'flac',
  'm4a',
  'aac',
  'amr',
  'mp4',
  'mkv',
  'mov',
};
const _formats = 'wav,mp3,flac,mov,aac,matroska,webm,amr';

class MediaOptions {
  const MediaOptions({
    this.format = 'mp3',
    this.audioBitrate = 192,
    this.sampleRate = 44100,
    this.channels = 2,
    this.remux = false,
    this.videoBitrate = 2000,
    this.width = 0,
    this.height = 0,
  });
  final String format;
  final int audioBitrate, sampleRate, channels, videoBitrate, width, height;
  final bool remux;
  bool get video => {'mp4', 'mkv', 'mov'}.contains(format);
  void validate() {
    if (!{
          'wav',
          'mp3',
          'flac',
          'm4a',
          'aac',
          'mp4',
          'mkv',
          'mov',
        }.contains(format) ||
        audioBitrate < 32 ||
        audioBitrate > 320 ||
        !{16000, 22050, 44100, 48000}.contains(sampleRate) ||
        !{1, 2}.contains(channels) ||
        videoBitrate < 100 ||
        videoBitrate > 50000 ||
        width < 0 ||
        height < 0 ||
        width > 3840 ||
        height > 2160 ||
        ((width == 0) != (height == 0)) ||
        width.isOdd ||
        height.isOdd ||
        remux && !video) {
      throw const ToolFailure(
        '媒体参数无效：采样率16/22.05/44.1/48kHz，1/2声道，视频尺寸为偶数且最多3840×2160。',
      );
    }
  }
}

class MediaInfo {
  MediaInfo(this.json);
  final Map<String, dynamic> json;
  List<Map<String, dynamic>> get streams => (json['streams'] as List? ?? [])
      .map((s) => Map<String, dynamic>.from(s as Map))
      .toList();
  bool get hasAudio => streams.any((s) => s['codec_type'] == 'audio');
  bool get hasVideo => streams.any(
    (s) =>
        s['codec_type'] == 'video' &&
        (s['disposition'] as Map?)?['attached_pic'] != 1,
  );
  double get seconds =>
      double.tryParse('${(json['format'] as Map?)?['duration']}') ?? 0;
  String get summary =>
      '${hasVideo ? '视频' : '音频'} · ${seconds.toStringAsFixed(2)}秒 · ${streams.map((s) => s['codec_name']).join('/')}';
}

class MediaRuntimeService {
  MediaRuntimeService(this.store);
  final RecordStore store;
  Future<Map<String, dynamic>> inspect(
    String directory, {
    Set<String> executables = const {'ffmpeg.exe', 'ffprobe.exe'},
  }) async {
    if (!Platform.isWindows) {
      throw const ToolFailure('音视频执行器当前仅验证Windows；移动端仍可使用图片和文档转换。');
    }
    final root = Directory(p.normalize(p.absolute(directory)));
    if (!await root.exists() ||
        archivePathKey(await root.resolveSymbolicLinks()) !=
            archivePathKey(root.path)) {
      throw const ToolFailure('请选择实际执行器目录，不支持链接。');
    }
    final checksums = <String, String>{};
    var total = 0;
    final entries = await root.list(followLinks: false).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entries) {
      if (!{'.exe', '.dll'}.contains(p.extension(entity.path).toLowerCase())) {
        continue;
      }
      if (entity is! File) throw const ToolFailure('执行器目录包含链接，未信任。');
      total += await entity.length();
      if (total > 500 * 1024 * 1024 || checksums.length > 100) {
        throw const ToolFailure('执行器目录过大，请只选择可信FFmpeg的bin目录。');
      }
      checksums[p.basename(entity.path)] = await archiveHash(
        entity,
        TaskCancellation(),
      );
    }
    if (!executables.every(checksums.containsKey)) {
      throw ToolFailure('目录需要${executables.join('、')}及配套DLL。');
    }
    return {'directory': root.path, 'checksums': checksums, 'size': total};
  }

  Future<ToolRecord> trust(
    Map<String, dynamic> inspected, {
    required bool confirmed,
  }) async {
    if (!confirmed) throw const ToolFailure('需要确认执行器来源与指纹后才能运行。');
    final current = await inspect(inspected['directory'] as String);
    if (jsonEncode(current) != jsonEncode(inspected)) {
      throw const ToolFailure('执行器检查后发生变化，请重新选择。');
    }
    final dir = current['directory'] as String;
    final version = await boundedProcess(p.join(dir, 'ffmpeg.exe'), [
      '-version',
    ]);
    if (!version.startsWith('ffmpeg version')) {
      throw const ToolFailure('执行器没有返回有效FFmpeg版本。');
    }
    final probe = await boundedProcess(p.join(dir, 'ffprobe.exe'), [
      '-version',
    ]);
    if (!probe.startsWith('ffprobe version')) {
      throw const ToolFailure('配套ffprobe不可用。');
    }
    final encoders = await boundedProcess(p.join(dir, 'ffmpeg.exe'), [
      '-hide_banner',
      '-encoders',
    ]);
    final previous = await store.find('utility_runtime', 'engine', 'ffmpeg');
    final data = {
      ...current,
      'engine': 'ffmpeg',
      'version': version.split('\n').first,
      'encoders': encoders,
      'verifiedAt': DateTime.now().toUtc().toIso8601String(),
      'syncAllowed': false,
      'isSensitive': true,
    };
    return previous == null
        ? store.create('utility_runtime', 'FFmpeg本地执行器', data: data)
        : store.save(previous.copyWith(data: data));
  }

  Future<ToolRecord> verified() async {
    final row = await store.find('utility_runtime', 'engine', 'ffmpeg');
    if (row == null) throw const ToolFailure('请先选择并验证FFmpeg执行器目录。');
    final current = await inspect(row.text('directory'));
    if (jsonEncode(current['checksums']) != jsonEncode(row.data['checksums'])) {
      throw const ToolFailure('执行器文件或DLL指纹已变化，必须重新验证。');
    }
    return row;
  }
}

Future<String> boundedProcess(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 15),
  bool combined = false,
}) async {
  final process = await Process.start(executable, arguments, runInShell: false);
  final stdout = BytesBuilder(copy: false), stderr = BytesBuilder(copy: false);
  var overflow = false;
  final timer = Timer(timeout, () {
    process.kill();
  });
  Future<void> collect(Stream<List<int>> stream, BytesBuilder out) async {
    await for (final chunk in stream) {
      if (out.length + chunk.length > 512 * 1024) {
        overflow = true;
        process.kill();
        continue;
      }
      out.add(chunk);
    }
  }

  try {
    final readers = Future.wait([
      collect(process.stdout, stdout),
      collect(process.stderr, stderr),
    ]);
    final code = await process.exitCode;
    await readers;
    if (code != 0 || overflow) throw const ToolFailure('执行器检测失败、超时或输出超限。');
    return utf8.decode(stdout.takeBytes(), allowMalformed: true) +
        (combined ? utf8.decode(stderr.takeBytes(), allowMalformed: true) : '');
  } finally {
    timer.cancel();
  }
}

class MediaConverterService {
  MediaConverterService(this.store, this.files, this.runtime, this.workRoot);
  final RecordStore store;
  final UtilityFileService files;
  final MediaRuntimeService runtime;
  final Future<Directory> Function() workRoot;
  Future<File> selectedInput(String path) async {
    if (!p.isAbsolute(path) ||
        !mediaExtensions.contains(
          p.extension(path).replaceFirst('.', '').toLowerCase(),
        ) ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const ToolFailure('请选择受支持的真实媒体文件，不支持链接或播放列表。');
    }
    final file = File(path);
    if (await file.length() == 0 ||
        archivePathKey(await file.resolveSymbolicLinks()) !=
            archivePathKey(p.normalize(path))) {
      throw const ToolFailure('媒体为空或路径包含链接。');
    }
    return file;
  }

  Future<MediaInfo> probe(String path, {ToolRecord? engine}) async {
    await selectedInput(path);
    final runner = engine ?? await runtime.verified();
    final json = jsonDecode(
      await boundedProcess(p.join(runner.text('directory'), 'ffprobe.exe'), [
        '-v',
        'error',
        '-protocol_whitelist',
        'file,pipe',
        '-format_whitelist',
        _formats,
        '-show_format',
        '-show_streams',
        '-of',
        'json',
        '-i',
        path,
      ]),
    );
    final info = MediaInfo(Map<String, dynamic>.from(json as Map));
    if ((!info.hasAudio && !info.hasVideo) ||
        !info.seconds.isFinite ||
        info.seconds <= 0) {
      throw const ToolFailure('媒体损坏、没有可处理轨道或无法确定时长。');
    }
    return info;
  }

  List<String> conversionArgs(
    MediaInfo input,
    MediaOptions options,
    ToolRecord engine,
  ) {
    options.validate();
    if (options.video && !input.hasVideo || !options.video && !input.hasAudio) {
      throw const ToolFailure('输入缺少所选输出需要的音频或视频轨道。');
    }
    final encoders = engine.text('encoders');
    void encoder(String name) {
      if (!RegExp('(^|\\s)$name(\\s|\$)', multiLine: true).hasMatch(encoders)) {
        throw ToolFailure('当前执行器缺少编码器$name，请使用包含该编码器的可信构建。');
      }
    }

    final args = <String>['-map_metadata', '-1', '-map_chapters', '-1'];
    if (options.video) {
      args.addAll(['-map', '0:v:0', '-map', '0:a:0?']);
      if (options.remux) {
        for (final stream in input.streams.where(
          (s) => {'video', 'audio'}.contains(s['codec_type']),
        )) {
          if (options.format != 'mkv' &&
              !(stream['codec_type'] == 'video'
                      ? {'h264', 'hevc', 'mpeg4'}
                      : {'aac', 'mp3', 'alac'})
                  .contains(stream['codec_name'])) {
            throw const ToolFailure('该轨道与目标容器未验证兼容，请改为重新编码或MKV。');
          }
        }
        args.addAll(['-c', 'copy']);
      } else {
        encoder('libopenh264');
        encoder('aac');
        args.addAll([
          '-c:v',
          'libopenh264',
          '-pix_fmt',
          'yuv420p',
          '-b:v',
          '${options.videoBitrate}k',
          '-c:a',
          'aac',
          '-b:a',
          '${options.audioBitrate}k',
        ]);
        if (options.width > 0) {
          args.addAll([
            '-vf',
            'scale=${options.width}:${options.height}:force_original_aspect_ratio=decrease:force_divisible_by=2',
          ]);
        }
      }
    } else {
      final codec = switch (options.format) {
        'wav' => 'pcm_s16le',
        'mp3' => 'libmp3lame',
        'flac' => 'flac',
        _ => 'aac',
      };
      encoder(codec);
      args.addAll([
        '-map',
        '0:a:0',
        '-vn',
        '-c:a',
        codec,
        '-ar',
        '${options.sampleRate}',
        '-ac',
        '${options.channels}',
      ]);
      if (!{'wav', 'flac'}.contains(options.format)) {
        args.addAll(['-b:a', '${options.audioBitrate}k']);
      }
    }
    return args;
  }

  Future<ToolRecord> convert(
    String path,
    String directory,
    String name,
    MediaOptions options,
    UtilityJobContext job,
  ) async {
    options.validate();
    job.check();
    final source = await selectedInput(path), before = await File(path).stat();
    final engine = await runtime.verified(),
        info = await probe(path, engine: engine);
    final args = conversionArgs(info, options, engine);
    final outDir = await files.selectedDirectory(directory);
    if (!validArchiveName(name) ||
        p.basename(name) != name ||
        p.extension(name).toLowerCase() != '.${options.format}' ||
        await FileSystemEntity.type(
              p.join(outDir.path, name),
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
      throw const ToolFailure('输出名称无效或已存在。');
    }
    final work = Directory(
      p.join((await workRoot()).path, 'utility-work', job.id),
    );
    await work.create(recursive: true);
    final temporary = File(p.join(work.path, '${newId()}.${options.format}'));
    String diagnostics = '';
    try {
      await files.ensureSpace(work.path, before.size * 2 + 16 * 1024 * 1024);
      job.check();
      final process = await Process.start(
        p.join(engine.text('directory'), 'ffmpeg.exe'),
        [
          '-hide_banner',
          '-nostdin',
          '-n',
          '-v',
          'warning',
          '-protocol_whitelist',
          'file,pipe',
          '-format_whitelist',
          _formats,
          '-i',
          source.path,
          ...args,
          '-progress',
          'pipe:1',
          '-nostats',
          temporary.path,
        ],
        runInShell: false,
      );
      var exited = false;
      job.onCancel(() async {
        if (!exited) process.kill();
      });
      final err = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((chunk) {
            diagnostics += chunk;
            if (diagnostics.length > 16000) {
              diagnostics = diagnostics.substring(diagnostics.length - 16000);
            }
          });
      try {
        job.check();
        await for (final line
            in process.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          job.check();
          if (line.startsWith('out_time_us=')) {
            final us = int.tryParse(line.substring(12));
            if (us != null) {
              await job.progress(
                0,
                1,
                currentFile: p.basename(path),
                fraction: (us / 1000000 / info.seconds).clamp(0, .99),
              );
            }
          }
        }
        final code = await process.exitCode;
        exited = true;
        job.check();
        if (code != 0 ||
            !await temporary.exists() ||
            await temporary.length() == 0) {
          throw const ToolFailure('媒体转换失败，请检查编码、输入和日志。');
        }
      } finally {
        if (!exited) {
          process.kill();
          await process.exitCode;
          exited = true;
        }
        await err.cancel();
      }
      final after = await source.stat();
      if (after.size != before.size || after.modified != before.modified) {
        throw const ToolFailure('处理期间源文件变化，未导出。');
      }
      final outputInfo = await probe(temporary.path, engine: engine);
      if (options.video ? !outputInfo.hasVideo : !outputInfo.hasAudio) {
        throw const ToolFailure('生成媒体校验失败。');
      }
      final output = await files.exportFile(
        outDir.path,
        name,
        temporary,
        job.cancellation,
      );
      final row = await store.create(
        'utility_output',
        name,
        data: {
          'payloadVersion': 1,
          'source': 'mediaConverter',
          'jobId': job.id,
          'outputPath': output.path,
          'format': options.format,
          'size': await output.length(),
          'checksum': await archiveHash(output, job.cancellation),
          'duration': outputInfo.seconds,
          'codecSummary': outputInfo.summary,
          'log': diagnostics,
          'runtimeVersion': engine.text('version'),
          'runtimeChecksums': engine.data['checksums'],
          'syncAllowed': false,
          'isSensitive': true,
        },
      );
      await job.output(row.id);
      await job.progress(1, 1, currentFile: name, force: true);
      return row;
    } catch (error) {
      if (diagnostics.isNotEmpty) {
        await store.create(
          'utility_log',
          '媒体处理日志',
          body: diagnostics,
          data: {'jobId': job.id, 'syncAllowed': false, 'isSensitive': true},
        );
      }
      rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
      if (await work.exists() && await work.list().isEmpty) await work.delete();
    }
  }
}
