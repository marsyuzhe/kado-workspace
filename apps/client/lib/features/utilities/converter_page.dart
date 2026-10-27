import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/record_ui.dart';
import 'utilities_page.dart';
import 'media_converter.dart';
import 'utility_providers.dart';
import 'job_widgets.dart';
import 'document_converter_page.dart';

class ConverterPage extends StatelessWidget {
  const ConverterPage({super.key, this.initialTab = 0});
  final int initialTab;
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    initialIndex: initialTab,
    child: const Column(
      children: [
        TabBar(
          tabs: [
            Tab(text: '图片格式'),
            Tab(text: '音频与视频'),
            Tab(text: '文本文档'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              ImageWorkbench(conversionOnly: true),
              MediaConverterPage(),
              DocumentConverterPage(),
            ],
          ),
        ),
      ],
    ),
  );
}

class MediaConverterPage extends ConsumerStatefulWidget {
  const MediaConverterPage({super.key});
  @override
  ConsumerState<MediaConverterPage> createState() => _MediaConverterPageState();
}

class _MediaConverterPageState extends ConsumerState<MediaConverterPage> {
  String? input, directory;
  MediaInfo? info;
  String format = 'mp3';
  bool remux = false, busy = false;
  final name = TextEditingController(),
      bitrate = TextEditingController(text: '192'),
      rate = TextEditingController(text: '44100'),
      channels = TextEditingController(text: '2');
  final width = TextEditingController(text: '0'),
      height = TextEditingController(text: '0'),
      videoBitrate = TextEditingController(text: '2000');
  @override
  void dispose() {
    for (final c in [
      name,
      bitrate,
      rate,
      channels,
      width,
      height,
      videoBitrate,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  MediaOptions get options => MediaOptions(
    format: format,
    audioBitrate: int.tryParse(bitrate.text) ?? 0,
    sampleRate: int.tryParse(rate.text) ?? 0,
    channels: int.tryParse(channels.text) ?? 0,
    remux: remux,
    width: int.tryParse(width.text) ?? -1,
    height: int.tryParse(height.text) ?? -1,
    videoBitrate: int.tryParse(videoBitrate.text) ?? 0,
  );
  Future<void> selectRuntime() async => runUi(context, () async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: '选择可信FFmpeg的bin目录',
    );
    if (path == null) return;
    setState(() => busy = true);
    try {
      final runtime = ref.read(mediaRuntimeProvider),
          inspected = await ref.read(mediaRuntimeProvider).inspect(path);
      if (!mounted) return;
      if (await ltConfirm(
        context,
        title: '信任并验证此本地执行器？',
        message:
            '将执行所选ffmpeg.exe/ffprobe.exe读取版本和编码能力。仅从你信任的来源获取。\n\n$path\n\nSHA256\n${(inspected['checksums'] as Map).entries.where((e) => e.key.toString().endsWith('.exe')).map((e) => '${e.key}\n${e.value}').join('\n')}',
      )) {
        await runtime.trust(inspected, confirmed: true);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  });
  Future<void> selectInput() async => runUi(context, () async {
    final chosen = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: mediaExtensions.toList(),
    );
    if (chosen?.path == null) return;
    final path = chosen!.path!;
    setState(() {
      input = path;
      info = null;
      name.text = '${p.basenameWithoutExtension(path)}-converted.$format';
      busy = true;
    });
    try {
      final metadata = await ref.read(mediaConverterProvider).probe(path);
      if (mounted) setState(() => info = metadata);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  });
  Future<void> submit() async => runUi(context, () async {
    final config = options;
    config.validate();
    final path = input, out = directory, outputName = name.text;
    if (path == null || out == null || info == null) {
      throw const ToolFailure('请先检测输入媒体并选择输出目录。');
    }
    final service = ref.read(mediaConverterProvider),
        runtime = await ref.read(mediaRuntimeProvider).verified();
    service.conversionArgs(info!, config, runtime);
    if (!mounted ||
        !await ltConfirm(
          context,
          title: config.remux ? '确认无损重新封装？' : '确认重新编码？',
          message:
              '$path\n→ ${p.join(out, outputName)}\n${info!.summary}\n输出不覆盖；成功后重新探测轨道并计算SHA256。',
        )) {
      return;
    }
    await ref
        .read(utilityJobsProvider)
        .submit(
          'converter',
          'media_conversion',
          '${config.remux ? '重新封装' : '转换'} ${p.basename(path)}',
          {
            'input': path,
            'outputDirectory': out,
            'outputName': outputName,
            'format': config.format,
          },
          confirmed: true,
          run: (job, _) async =>
              (await service.convert(path, out, outputName, config, job)).id,
        );
  });
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const Text('音频与视频转换', style: TextStyle(fontSize: 24)),
      const Text(
        'Windows：可选FFmpeg执行器，按实际编码器检测。MP3/WAV/FLAC/M4A/AAC；MP4/MKV/MOV。输出文件保存在所选目录，备份仅包含处理记录。',
      ),
      if (!Platform.isWindows)
        const LTErrorState(message: '当前移动平台未接入经验证的音视频执行器；图片转换仍可使用。'),
      ref
          .watch(recordsProvider('utility_runtime'))
          .when(
            loading: () => const LTLoadingState(),
            error: (_, _) => const LTErrorState(),
            data: (rows) => Column(
              children: [
                for (final row in rows.where(
                  (r) => r.text('engine') == 'ffmpeg',
                ))
                  ListTile(
                    title: Text(row.text('version')),
                    subtitle: Text(row.text('directory')),
                  ),
              ],
            ),
          ),
      LTToolbar(
        children: [
          LTButton(
            label: '选择并验证执行器',
            onPressed: !Platform.isWindows || busy ? null : selectRuntime,
          ),
          LTButton(
            label: '选择媒体并检测',
            onPressed: !Platform.isWindows || busy ? null : selectInput,
          ),
          TextButton(
            onPressed: !Platform.isWindows || busy
                ? null
                : () => runUi(context, () async {
                    final path = await FilePicker.getDirectoryPath(
                      dialogTitle: '选择输出目录',
                    );
                    if (mounted && path != null) {
                      setState(() => directory = path);
                    }
                  }),
            child: const Text('选择输出目录'),
          ),
        ],
      ),
      if (busy) const LinearProgressIndicator(),
      SelectableText(input ?? '尚未选择媒体'),
      if (info != null) Text(info!.summary),
      Text('输出目录：${directory ?? '尚未选择'}'),
      DropdownButton<String>(
        value: format,
        items: [
          for (final value in [
            'mp3',
            'wav',
            'flac',
            'm4a',
            'aac',
            'mp4',
            'mkv',
            'mov',
          ])
            DropdownMenuItem(value: value, child: Text(value.toUpperCase())),
        ],
        onChanged: (v) => setState(() {
          format = v!;
          remux = false;
          if (input != null) {
            name.text =
                '${p.basenameWithoutExtension(input!)}-converted.$format';
          }
        }),
      ),
      TextField(
        controller: name,
        decoration: const InputDecoration(labelText: '输出文件名（保留所选扩展名）'),
      ),
      if (options.video)
        CheckboxListTile(
          title: const Text('无损重新封装（复制轨道；先检查容器兼容性）'),
          value: remux,
          onChanged: (v) => setState(() => remux = v!),
        ),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final item in [
            (bitrate, '音频码率 kbps'),
            (rate, '采样率 Hz'),
            (channels, '声道 1/2'),
            if (options.video) ...[
              (videoBitrate, '视频码率 kbps'),
              (width, '最大宽度（0=保留）'),
              (height, '最大高度（0=保留）'),
            ],
          ])
            SizedBox(
              width: 200,
              child: TextField(
                controller: item.$1,
                decoration: InputDecoration(labelText: item.$2),
              ),
            ),
        ],
      ),
      const SizedBox(height: 16),
      LTButton(
        label: '预览并加入任务队列',
        onPressed: busy || info == null || directory == null ? null : submit,
      ),
      const UtilityJobHistory(moduleId: 'converter'),
      ref
          .watch(recordsProvider('utility_output'))
          .when(
            loading: () => const LTLoadingState(),
            error: (_, _) => const LTErrorState(),
            data: (rows) => Column(
              children: [
                for (final row
                    in rows
                        .where((r) => r.text('source') == 'mediaConverter')
                        .take(20))
                  ListTile(
                    title: Text(row.title),
                    subtitle: SelectableText(
                      '${row.text('outputPath')}\n${row.text('codecSummary')}\n${row.number('size')} bytes · SHA256 ${row.text('checksum')}',
                    ),
                  ),
              ],
            ),
          ),
    ],
  );
}
