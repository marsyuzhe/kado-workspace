import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/platform/system_actions.dart';
import '../../core/ui/lt_components.dart';
import '../../core/ui/lt_scroll_page.dart';
import '../../shared/record_ui.dart';
import '../hub/hub_actions.dart';
import 'utility_providers.dart';
import 'transcribe_service.dart';
import 'media_converter.dart';
import 'job_widgets.dart';

class TranscribePage extends StatelessWidget {
  const TranscribePage({super.key, this.recordId});
  final String? recordId;
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    initialIndex: recordId == null ? 0 : 2,
    child: Column(
      children: [
        const TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: '本地转写'),
            Tab(text: '模型与执行器'),
            Tab(text: '结果与字幕编辑'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              const TranscribeInputPage(),
              const SpeechModelsPage(),
              TranscriptResultsPage(recordId: recordId),
            ],
          ),
        ),
      ],
    ),
  );
}

class TranscribeInputPage extends ConsumerStatefulWidget {
  const TranscribeInputPage({super.key});
  @override
  ConsumerState<TranscribeInputPage> createState() =>
      _TranscribeInputPageState();
}

class _TranscribeInputPageState extends ConsumerState<TranscribeInputPage> {
  String? input, modelId;
  String language = 'auto';
  MediaInfo? info;
  bool busy = false;
  Future<void> choose() async => runUi(context, () async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['wav', 'mp3', 'm4a', 'flac', 'amr', 'aac'],
    );
    if (file?.path == null) return;
    setState(() {
      input = file!.path;
      info = null;
      busy = true;
    });
    try {
      final metadata = await ref.read(mediaConverterProvider).probe(input!);
      if (mounted) setState(() => info = metadata);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  });
  Future<void> submit(ToolRecord model) async => runUi(context, () async {
    final source = input, lang = language;
    if (source == null || info == null) throw const ToolFailure('请先选择并检测音频。');
    if (!await ltConfirm(
      context,
      title: '开始本地识别？',
      message:
          '${p.basename(source)}\n${info!.summary}\n模型${model.title} · ${model.flag('englishOnly') ? '仅英文' : '多语言'} · 预计模型内存约${model.number('memoryMiB')}MiB\n语言：$lang。音频每10分钟分段，最多2小时；不会上传录音。结果需人工复核，不提供说话人身份。',
    )) {
      return;
    }
    if (!mounted) return;
    final service = ref.read(transcribeServiceProvider);
    await ref
        .read(utilityJobsProvider)
        .submit(
          'transcribe',
          'transcribe',
          '识别 ${p.basename(source)}',
          {'sourcePath': source, 'modelId': model.id, 'language': lang},
          confirmed: true,
          run: (job, _) async =>
              (await service.transcribe(source, model, lang, job)).id,
        );
  });
  @override
  Widget build(BuildContext context) {
    final models =
        ref.watch(recordsProvider('speech_model')).asData?.value ?? [];
    final selected =
        models.where((m) => m.id == modelId).firstOrNull ?? models.firstOrNull;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('本地语音转文字', style: TextStyle(fontSize: 24)),
        const Text(
          'WAV/MP3/M4A/FLAC/AMR/AAC按真实轨道探测后转码。Windows使用可选CPU执行器和独立模型；识别准确率取决于录音与模型。移动端推理尚未接入，可查看、编辑和导出已有结果。',
        ),
        TextButton(
          onPressed: () => context.go('/modules/converter?view=media'),
          child: const Text('先配置或检查FFmpeg音频解码器'),
        ),
        LTButton(
          label: '选择录音并检测',
          onPressed: busy || !Platform.isWindows ? null : choose,
        ),
        if (busy) const LinearProgressIndicator(),
        SelectableText(input ?? '尚未选择录音'),
        if (info != null) Text(info!.summary),
        const SizedBox(height: 16),
        if (selected == null)
          const Text('尚无模型，请在「模型与执行器」页导入。')
        else
          DropdownButton<String>(
            isExpanded: true,
            value: selected.id,
            items: [
              for (final m in models)
                DropdownMenuItem(
                  value: m.id,
                  child: Text(
                    '${m.title} · ${m.flag('englishOnly') ? 'English' : '多语言'}',
                  ),
                ),
            ],
            onChanged: (v) => setState(() => modelId = v),
          ),
        DropdownButton<String>(
          value: language,
          items: [
            for (final item in const {
              'auto': '自动检测',
              'zh': '中文',
              'en': '英文',
              'ja': '日文',
              'ko': '韩文',
              'fr': '法文',
              'de': '德文',
              'es': '西班牙文',
            }.entries)
              DropdownMenuItem(value: item.key, child: Text(item.value)),
          ],
          onChanged: (v) => setState(() => language = v!),
        ),
        LTButton(
          label: '确认并加入转写队列',
          onPressed:
              busy || selected == null || info == null || !Platform.isWindows
              ? null
              : () => submit(selected),
        ),
        const SizedBox(height: 16),
        const UtilityJobHistory(moduleId: 'transcribe'),
      ],
    );
  }
}

class SpeechModelsPage extends ConsumerStatefulWidget {
  const SpeechModelsPage({super.key});
  @override
  ConsumerState<SpeechModelsPage> createState() => _SpeechModelsPageState();
}

class _SpeechModelsPageState extends ConsumerState<SpeechModelsPage> {
  SpeechModelSpec spec = speechModels.first;
  bool busy = false;
  Future<void> runtime() async => runUi(context, () async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: '选择whisper-cli.exe和配套DLL目录',
    );
    if (path == null) return;
    setState(() => busy = true);
    try {
      final service = ref.read(whisperRuntimeProvider),
          preview = await ref.read(whisperRuntimeProvider).inspect(path);
      if (!mounted) return;
      if (await ltConfirm(
        context,
        title: '信任此whisper.cpp执行器？',
        message:
            '将运行所选程序读取版本。请确认来自可信来源。\n$path\nSHA256\n${(preview['checksums'] as Map)['whisper-cli.exe']}',
      )) {
        await service.trust(preview, confirmed: true);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  });
  Future<void> importModel() async => runUi(context, () async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['bin'],
    );
    if (file?.path == null) return;
    final selected = spec, path = file!.path!;
    if (!mounted ||
        !await ltConfirm(
          context,
          title: '导入${selected.id}模型副本？',
          message:
              '将核对官方登记SHA1并复制到独立模型目录。\n${selected.sha1}\n约${selected.diskMiB}MiB磁盘 / ${selected.memoryMiB}MiB模型内存。模型不随完整备份和基础安装包携带。',
        )) {
      return;
    }
    if (!mounted) return;
    final manager = ref.read(speechModelsProvider);
    await ref
        .read(utilityJobsProvider)
        .submit(
          'transcribe',
          'import_model',
          '导入${selected.id}模型',
          {'modelName': selected.id, 'sourcePath': path},
          confirmed: true,
          run: (job, _) async =>
              (await manager.importModel(path, selected, job)).id,
        );
  });
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const Text('模型与执行器', style: TextStyle(fontSize: 24)),
      const Text(
        '模型手动导入，首次导入后完全离线使用。仅接受已登记校验值的tiny/base完整模型，不接受for-tests空权重。可在官方whisper.cpp模型页获取，不自动下载。',
      ),
      if (!Platform.isWindows) const Text('当前平台尚未验证本地执行器；可导出和编辑已有转写记录。'),
      LTButton(
        label: '选择并验证whisper.cpp',
        onPressed: busy || !Platform.isWindows ? null : runtime,
      ),
      if (busy) const LinearProgressIndicator(),
      ref
          .watch(recordsProvider('utility_runtime'))
          .when(
            loading: () => const LTLoadingState(),
            error: (_, _) => const LTErrorState(),
            data: (rows) => Column(
              children: [
                for (final r in rows.where(
                  (r) => r.text('engine') == 'whisper',
                ))
                  ListTile(
                    title: Text(r.text('version')),
                    subtitle: SelectableText(r.text('directory')),
                  ),
              ],
            ),
          ),
      DropdownButton<SpeechModelSpec>(
        value: spec,
        isExpanded: true,
        items: [
          for (final model in speechModels)
            DropdownMenuItem(
              value: model,
              child: Text(
                '${model.id} · ${model.diskMiB}MiB · ${model.englishOnly ? '英文' : '多语言'}',
              ),
            ),
        ],
        onChanged: (v) => setState(() => spec = v!),
      ),
      LTButton(
        label: '选择并导入模型',
        onPressed: busy || !Platform.isWindows ? null : importModel,
      ),
      ref
          .watch(recordsProvider('speech_model'))
          .when(
            loading: () => const LTLoadingState(),
            error: (_, _) => const LTErrorState(),
            data: (rows) => Column(
              children: [
                for (final row in rows)
                  LTCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '${row.title} · ${readableBytes(row.number('size'))} · 已校验',
                        ),
                        SelectableText(
                          'SHA256 ${row.text('checksum')}\n${row.text('managedName')}\n预计模型内存约${row.number('memoryMiB')}MiB',
                        ),
                        ref
                            .watch(appDirectoryProvider)
                            .when(
                              loading: () => const Text('读取模型位置…'),
                              error: (_, _) => const Text('模型位置不可读'),
                              data: (dir) => SelectableText(
                                p.join(
                                  dir.path,
                                  'speech-models',
                                  row.text('managedName'),
                                ),
                              ),
                            ),
                        if (Platform.isWindows)
                          TextButton(
                            onPressed: () => runUi(context, () async {
                              final dir = await ref.read(
                                appDirectoryProvider.future,
                              );
                              if (!context.mounted) return;
                              await openTarget(
                                context,
                                ref,
                                TargetAction(
                                  'folder',
                                  p.join(dir.path, 'speech-models'),
                                ),
                              );
                            }),
                            child: const Text('打开模型目录'),
                          ),
                        TextButton(
                          onPressed: () => runUi(context, () async {
                            if (!await ltConfirm(
                              context,
                              title: '删除应用内模型副本？',
                              message: '保留原始导入文件与转写结果；之后识别需重新导入。',
                            )) {
                              return;
                            }
                            await ref
                                .read(speechModelsProvider)
                                .remove(row, confirmed: true);
                          }),
                          child: const Text('删除模型副本'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      const UtilityJobHistory(moduleId: 'transcribe'),
    ],
  );
}

class TranscriptResultsPage extends ConsumerStatefulWidget {
  const TranscriptResultsPage({super.key, this.recordId});
  final String? recordId;
  @override
  ConsumerState<TranscriptResultsPage> createState() =>
      _TranscriptResultsPageState();
}

class _TranscriptResultsPageState extends ConsumerState<TranscriptResultsPage> {
  String? selectedId;
  @override
  void initState() {
    super.initState();
    selectedId = widget.recordId;
  }

  int parseTime(String value) {
    final match = RegExp(r'^(\d{2}):(\d{2}):(\d{2})[,.](\d{3})$')
        .firstMatch(value.trim());
    if (match == null) throw const ToolFailure('时间格式为HH:MM:SS,mmm。');
    final h = int.parse(match[1]!),
        m = int.parse(match[2]!),
        s = int.parse(match[3]!),
        ms = int.parse(match[4]!);
    if (m > 59 || s > 59) throw const ToolFailure('分钟和秒必须小于60。');
    return h * 3600000 + m * 60000 + s * 1000 + ms;
  }

  Future<void> edit(ToolRecord row, int index, String action) async =>
      runUi(context, () async {
        final segments = transcriptSegments(row), segment = segments[index];
        if (action == 'merge') {
          if (index + 1 >= segments.length) return;
          final next = segments.removeAt(index + 1);
          segments[index] = TranscriptSegment(
            segment.startMs,
            next.endMs,
            '${segment.text} ${next.text}',
          );
        } else if (action == 'delete') {
          if (!await ltConfirm(
            context,
            title: '删除这条字幕？',
            message: segment.text,
          )) {
            return;
          }
          segments.removeAt(index);
        } else if (action == 'split') {
          final fields = await ltEditForm(
            context,
            title: '拆分字幕',
            fields: [
              LTField(
                'index',
                '前半句字符数',
                initial: '${segment.text.runes.length ~/ 2}',
                required: true,
              ),
              LTField(
                'time',
                '拆分时间 HH:MM:SS,mmm',
                initial: TranscriptRepository.time(
                  (segment.startMs + segment.endMs) ~/ 2,
                ),
                required: true,
              ),
            ],
          );
          if (fields == null) return;
          final at = int.tryParse(fields['index']!) ?? 0,
              time = parseTime(fields['time']!),
              runes = segment.text.runes.toList();
          if (at <= 0 ||
              at >= runes.length ||
              time <= segment.startMs ||
              time >= segment.endMs) {
            throw const ToolFailure('拆分位置必须在文字和时间范围内。');
          }
          segments[index] = TranscriptSegment(
            segment.startMs,
            time,
            String.fromCharCodes(runes.take(at)).trim(),
          );
          segments.insert(
            index + 1,
            TranscriptSegment(
              time,
              segment.endMs,
              String.fromCharCodes(runes.skip(at)).trim(),
            ),
          );
        } else {
          final fields = await ltEditForm(
            context,
            title: '修订字幕',
            fields: [
              LTField(
                'start',
                '开始 HH:MM:SS,mmm',
                initial: TranscriptRepository.time(segment.startMs),
                required: true,
              ),
              LTField(
                'end',
                '结束 HH:MM:SS,mmm',
                initial: TranscriptRepository.time(segment.endMs),
                required: true,
              ),
              LTField(
                'text',
                '文字',
                initial: segment.text,
                multiline: true,
                required: true,
              ),
            ],
          );
          if (fields == null) return;
          segments[index] = TranscriptSegment(
            parseTime(fields['start']!),
            parseTime(fields['end']!),
            fields['text']!,
          );
        }
        await ref.read(transcriptRepositoryProvider).revise(row, segments);
      });
  @override
  Widget build(BuildContext context) => ref
      .watch(recordsProvider('transcript'))
      .when(
        loading: () => const LTLoadingState(),
        error: (_, _) => const LTErrorState(),
        data: (rows) {
          if (rows.isEmpty) {
            return const SingleChildScrollView(
              child: LTEmptyState(
                title: '还没有识别结果',
                message: '完成一次真实本地识别后，文字和时间戳会保存在这里。',
              ),
            );
          }
          final row =
                  rows.where((r) => r.id == selectedId).firstOrNull ??
                  rows.first,
              segments = transcriptSegments(
                rows.where((r) => r.id == selectedId).firstOrNull ?? rows.first,
              ),
              editing = row.text('status') != 'processing';
          return LTScrollPage(
            title: '转写结果',
            description: '可修订文字/时间、拆分和合并。已有失败或取消的分段保留，并明确显示状态；请人工核对识别内容。',
            header: [
              DropdownButton<String>(
                isExpanded: true,
                value: row.id,
                items: [
                  for (final r in rows)
                    DropdownMenuItem(
                      value: r.id,
                      child: Text(
                        r.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => selectedId = v),
              ),
              Text(
                '${row.text('status')} · ${row.text('modelName')} · ${row.text('language')} · ${segments.length}条 · 修订${row.number('editCount')}次',
              ),
              if (row.text('error').isNotEmpty) Text(row.text('error')),
              if (row.number('timingAdjustmentCount') > 0)
                Text(
                  '识别器返回的${row.number('timingAdjustmentCount')}处时间重叠/零时长已按已有边界顺序合并或裁剪，请人工复核。原边界记录在JSON中。',
                ),
              Wrap(
                spacing: 8,
                children: [
                  for (final format in ['txt', 'srt', 'vtt', 'json'])
                    TextButton(
                      onPressed: !editing || segments.isEmpty
                          ? null
                          : () => runUi(context, () async {
                              await FilePicker.saveFile(
                                fileName:
                                    '${p.basenameWithoutExtension(row.title)}-${row.id.substring(0, 8)}${row.text('status') == 'complete' ? '' : '-partial'}.$format',
                                bytes: Uint8List.fromList(
                                  utf8.encode(
                                    TranscriptRepository.export(row, format),
                                  ),
                                ),
                                mimeType: format == 'json'
                                    ? 'application/json'
                                    : format == 'vtt'
                                    ? 'text/vtt'
                                    : 'text/plain',
                              );
                            }),
                      child: Text('导出${format.toUpperCase()}'),
                    ),
                ],
              ),
            ],
            itemCount: segments.length,
            itemBuilder: (context, i) {
              final s = segments[i];
              return LTCard(
                child: ListTile(
                  title: Text(s.text),
                  subtitle: Text(
                    '${TranscriptRepository.time(s.startMs)} → ${TranscriptRepository.time(s.endMs)}',
                  ),
                  trailing: !editing
                      ? null
                      : PopupMenuButton<String>(
                          onSelected: (v) => edit(row, i, v),
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'edit',
                              child: Text('修订文字和时间'),
                            ),
                            const PopupMenuItem(
                              value: 'split',
                              child: Text('拆分字幕'),
                            ),
                            if (i + 1 < segments.length)
                              const PopupMenuItem(
                                value: 'merge',
                                child: Text('与下一条合并'),
                              ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('删除这条'),
                            ),
                          ],
                        ),
                ),
              );
            },
          );
        },
      );
}
