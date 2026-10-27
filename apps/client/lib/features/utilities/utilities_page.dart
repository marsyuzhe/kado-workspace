export '../../core/storage/selected_input.dart' show readToolFile;
import '../../core/storage/selected_input.dart';

import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/record_ui.dart';
import '../archive/archive_service.dart';
import 'image_service.dart';
import 'personal_tools.dart';
import 'utility_providers.dart';
import 'job_widgets.dart';
import '../web_library/web_library_page.dart';

final bookmarkServiceProvider = Provider(
  (ref) => BookmarkService(ref.watch(hubRepositoryProvider)),
);
final personalTimelineProvider = Provider(
  (ref) => PersonalTimeline(ref.watch(recordStoreProvider)),
);
final imageToolProvider = Provider(
  (ref) => ImageToolService(
    ref.watch(recordStoreProvider),
    () => ref.read(ownedFilesProvider.future),
  ),
);

class UtilitiesPage extends StatelessWidget {
  const UtilitiesPage({super.key});
  @override
  Widget build(BuildContext context) => const DefaultTabController(
    length: 4,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'UTILITIES',
                style: TextStyle(fontSize: 10, letterSpacing: 2),
              ),
              Text(
                '工具中心',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: '网页收藏'),
            Tab(text: '图片处理'),
            Tab(text: '格式转换'),
            Tab(text: '个人时间轴'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              BookmarksPage(),
              ImageWorkbench(),
              ImageWorkbench(conversionOnly: true),
              PersonalTimelinePage(),
            ],
          ),
        ),
      ],
    ),
  );
}

/// 保留旧路由/工具中心入口，统一到同一个网站库。
class BookmarksPage extends StatelessWidget {
  const BookmarksPage({super.key});
  @override
  Widget build(BuildContext context) => const WebLibraryPage();
}

class ImageWorkbench extends ConsumerStatefulWidget {
  const ImageWorkbench({super.key, this.conversionOnly = false});
  final bool conversionOnly;
  @override
  ConsumerState<ImageWorkbench> createState() => _ImageWorkbenchState();
}

class _ImageWorkbenchState extends ConsumerState<ImageWorkbench> {
  final files = <({String name, Uint8List bytes})>[];
  final width = TextEditingController(text: '0'),
      height = TextEditingController(text: '0'),
      quality = TextEditingController(text: '85'),
      crop = TextEditingController(text: '0,0,0,0');
  final percent = TextEditingController(text: '100'),
      textMark = TextEditingController(),
      markSize = TextEditingController(text: '24'),
      markMargin = TextEditingController(text: '0'),
      markPercent = TextEditingController(text: '25'),
      markColor = TextEditingController(text: 'FFFFFF');
  String? outputDirectory;
  int rotation = 0;
  bool flipH = false, flipV = false, aspect = true, noUpscale = false;
  String markPosition = 'bottomRight', markFont = '系统默认', cropRatio = '自由';
  double markOpacity = 1;
  String format = 'png', status = '添加静态 PNG、JPG 或 WebP。原始文件保持原样。';
  bool stripExif = true, white = false, busy = false;
  Uint8List? watermark;
  ImageOutput? preview;
  TaskCancellation? token;
  @override
  void dispose() {
    for (final c in [
      width,
      height,
      quality,
      crop,
      percent,
      textMark,
      markSize,
      markMargin,
      markPercent,
      markColor,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  ImageOptions options() {
    final region = crop.text.split(',').map(int.tryParse).toList();
    if (region.length != 4 || region.any((v) => v == null)) {
      throw const ToolFailure('裁剪格式为 x,y,width,height；全部0代表不裁剪。');
    }
    return ImageOptions(
      format: format,
      width: widget.conversionOnly ? 0 : int.tryParse(width.text) ?? -1,
      height: widget.conversionOnly ? 0 : int.tryParse(height.text) ?? -1,
      quality: int.tryParse(quality.text) ?? -1,
      cropX: widget.conversionOnly ? 0 : region[0]!,
      cropY: widget.conversionOnly ? 0 : region[1]!,
      cropWidth: widget.conversionOnly ? 0 : region[2]!,
      cropHeight: widget.conversionOnly ? 0 : region[3]!,
      stripExif: stripExif,
      whiteBackground: white,
      watermark: widget.conversionOnly ? null : watermark,
      rotation: rotation,
      flipHorizontal: flipH,
      flipVertical: flipV,
      scalePercent: int.tryParse(percent.text) ?? -1,
      maintainAspect: aspect,
      noUpscale: noUpscale,
      watermarkOpacity: markOpacity,
      watermarkPosition: markPosition,
      watermarkMargin: int.tryParse(markMargin.text) ?? -1,
      watermarkPercent: watermark == null
          ? 0
          : int.tryParse(markPercent.text) ?? -1,
    );
  }

  Future<ImageOptions> preparedOptions() async {
    Uint8List? mark = watermark;
    if (!widget.conversionOnly && textMark.text.trim().isNotEmpty) {
      final color = int.tryParse('FF${markColor.text}', radix: 16),
          size = int.tryParse(markSize.text);
      if (color == null ||
          markColor.text.length != 6 ||
          size == null ||
          size < 8 ||
          size > 128 ||
          textMark.text.length > 200) {
        throw const ToolFailure('水印颜色为6位RGB，字号8–128，文字最多200字符。');
      }
      final painter = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: textMark.text,
          style: TextStyle(
            color: Color(color),
            fontSize: size.toDouble(),
            fontFamily: markFont == '等宽' ? 'monospace' : null,
          ),
        ),
      )..layout();
      if (painter.width > 4096 || painter.height > 512) {
        throw const ToolFailure('文字水印过大，请减小字号或文字长度。');
      }
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), Offset.zero);
      final picture = recorder.endRecording(),
          image = await picture.toImage(
            painter.width.ceil().clamp(1, 4096),
            painter.height.ceil().clamp(1, 512),
          );
      try {
        mark = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
            .asUint8List();
      } finally {
        image.dispose();
        picture.dispose();
        painter.dispose();
      }
    }
    final c = options();
    return ImageOptions(
      format: c.format,
      width: c.width,
      height: c.height,
      quality: c.quality,
      cropX: c.cropX,
      cropY: c.cropY,
      cropWidth: c.cropWidth,
      cropHeight: c.cropHeight,
      stripExif: c.stripExif,
      whiteBackground: c.whiteBackground,
      watermark: mark,
      rotation: c.rotation,
      flipHorizontal: c.flipHorizontal,
      flipVertical: c.flipVertical,
      scalePercent: c.scalePercent,
      maintainAspect: c.maintainAspect,
      noUpscale: c.noUpscale,
      watermarkOpacity: c.watermarkOpacity,
      watermarkPosition: c.watermarkPosition,
      watermarkMargin: c.watermarkMargin,
      watermarkPercent: textMark.text.isNotEmpty ? 0 : c.watermarkPercent,
    );
  }

  Future<void> add() async => runUi(context, () async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
    );
    if (files.length + picked.length > 50) throw const ToolFailure('批次最多50张。');
    final imported = <({String name, Uint8List bytes})>[];
    var total = files.fold<int>(0, (n, f) => n + f.bytes.length);
    for (final file in picked) {
      final bytes = await readToolFile(file, 25 * 1024 * 1024);
      total += bytes.length;
      if (total > 100 * 1024 * 1024) {
        throw const ToolFailure('批次原始图片总计最多100MB。');
      }
      imported.add((name: file.name, bytes: bytes));
    }
    if (mounted) {
      setState(() {
        files.addAll(imported);
        preview = null;
      });
    }
  });
  Future<void> generate() async {
    if (files.isEmpty) return;
    final config = (await preparedOptions())..validate();
    if (outputDirectory != null) {
      await ref.read(utilityFilesProvider).selectedDirectory(outputDirectory!);
      for (final input in files) {
        final target = p.join(
          outputDirectory!,
          '${p.basenameWithoutExtension(input.name)}.${config.format}',
        );
        if (await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw ToolFailure('输出冲突：${p.basename(target)}，请改选目录。');
        }
      }
    }
    if (!mounted) return;
    if (!await ltConfirm(
          context,
          title: '生成 ${files.length} 张 $format 图片？',
          message:
              '输出先保存为应用附件${outputDirectory == null ? '' : '，并导出到 $outputDirectory（冲突时失败，不覆盖）'}。不会修改原图。${stripExif ? ' EXIF 将清除。' : ' EXIF 可能包含位置信息。'}',
          confirmLabel: '确认生成',
        ) ||
        !mounted) {
      return;
    }
    setState(() => busy = true);
    try {
      final inputs = List.of(files),
          service = ref.read(imageToolProvider),
          outputService = ref.read(utilityFilesProvider),
          destination = outputDirectory;
      final names = <String>{};
      for (final input in inputs) {
        final name =
            '${p.basenameWithoutExtension(input.name)}.${config.format}';
        if (!names.add(name.toLowerCase())) {
          throw const ToolFailure('批次中有同名输出，请分批或调整源文件名。');
        }
      }
      await ref
          .read(utilityJobsProvider)
          .submit(
            widget.conversionOnly ? 'converter' : 'image_studio',
            'image_batch',
            '处理${inputs.length}张图片',
            {
              'names': inputs.map((f) => f.name).toList(),
              'outputDirectory': destination ?? '应用附件',
              'format': config.format,
            },
            confirmed: true,
            retainedBytes: inputs.fold<int>(0, (n, f) => n + f.bytes.length),
            run: (job, _) async {
              for (var i = 0; i < inputs.length; i++) {
                job.check();
                final input = inputs[i];
                await job.progress(
                  i,
                  inputs.length,
                  currentFile: input.name,
                  force: true,
                );
                final result = await service.process(
                  input.name,
                  input.bytes,
                  config,
                  job.cancellation,
                  confirmed: true,
                  jobId: job.id,
                );
                await job.output(result.id);
                if (destination != null) {
                  final owned = await service.files();
                  await outputService.exportFile(
                    destination,
                    '${p.basenameWithoutExtension(input.name)}.${config.format}',
                    owned.resolve(result.text('attachment')),
                    job.cancellation,
                  );
                }
                await job.progress(
                  i + 1,
                  inputs.length,
                  currentFile: input.name,
                  force: true,
                );
              }
              return null;
            },
          );
      if (mounted) {
        setState(() {
          files.clear();
          preview = null;
          status = '任务已进入后台队列，离开页面仍会处理。输入需重新选择才可再次提交。';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              status = e is ToolFailure ? e.message : '处理失败；已生成的文件保留，请检查输入或磁盘。',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> export(ToolRecord output) async => runUi(context, () async {
    final file = (await ref.read(ownedFilesProvider.future))
        .resolve(output.text('attachment'));
    await FilePicker.saveFile(
      fileName:
          '${p.basenameWithoutExtension(output.title)}-${output.id.substring(0, 8)}.${output.text('format')}',
      bytes: await file.readAsBytes(),
      mimeType: output.text('format') == 'jpg'
          ? 'image/jpeg'
          : 'image/${output.text('format')}',
    );
  });
  @override
  Widget build(BuildContext context) {
    final outputs = ref.watch(recordsProvider('utility_output'));
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          widget.conversionOnly ? '静态图格式转换 · PNG / JPG / WebP' : '批量图片处理',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        LTToolbar(
          children: [
            LTButton(
              label: '添加图片',
              icon: Icons.add_photo_alternate_outlined,
              onPressed: busy ? null : add,
            ),
            LTButton(
              label: '清空本次输入',
              style: LTButtonStyle.ghost,
              onPressed: busy
                  ? null
                  : () => setState(() {
                      files.clear();
                      preview = null;
                    }),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '输入 ${files.length} 张 · ${readableBytes(files.fold<int>(0, (n, f) => n + f.bytes.length))}',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: 160,
              child: DropdownButtonFormField<String>(
                initialValue: format,
                decoration: const InputDecoration(labelText: '输出格式'),
                items: [
                  for (final f in ['png', 'jpg', 'webp'])
                    DropdownMenuItem(value: f, child: Text(f.toUpperCase())),
                ],
                onChanged: busy ? null : (v) => setState(() => format = v!),
              ),
            ),
            SizedBox(
              width: 150,
              child: LTTextField(
                controller: quality,
                label: format == 'png' ? 'PNG 无损编码' : '质量 1–100',
                enabled: !busy && format != 'png',
              ),
            ),
            if (!widget.conversionOnly) ...[
              SizedBox(
                width: 150,
                child: LTTextField(
                  controller: width,
                  label: '宽度（0保持比例）',
                  enabled: !busy,
                ),
              ),
              SizedBox(
                width: 150,
                child: LTTextField(
                  controller: height,
                  label: '高度（0保持比例）',
                  enabled: !busy,
                ),
              ),
              SizedBox(
                width: 260,
                child: LTTextField(
                  controller: crop,
                  label: '裁剪 x,y,width,height',
                  enabled: !busy,
                ),
              ),
            ],
          ],
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('清除 EXIF'),
          value: stripExif,
          onChanged: busy ? null : (v) => setState(() => stripExif = v ?? true),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.folder_open),
              label: Text(
                outputDirectory == null
                    ? '选择批量输出目录（可选）'
                    : '输出：$outputDirectory',
              ),
              onPressed: busy || !Platform.isWindows
                  ? null
                  : () => runUi(context, () async {
                      final dir = await FilePicker.getDirectoryPath();
                      if (dir != null && mounted) {
                        setState(() => outputDirectory = dir);
                      }
                    }),
            ),
            if (outputDirectory != null)
              TextButton(
                onPressed: () => setState(() => outputDirectory = null),
                child: const Text('仅保存附件'),
              ),
            if (!Platform.isWindows) const Text('当前移动端通过系统保存逐个导出。'),
          ],
        ),
        if (!widget.conversionOnly)
          ExpansionTile(
            title: const Text('旋转、比例和文字水印'),
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 150,
                    child: DropdownButtonFormField<int>(
                      initialValue: rotation,
                      decoration: const InputDecoration(labelText: '旋转'),
                      items: [
                        for (final r in [0, 90, 180, 270])
                          DropdownMenuItem(value: r, child: Text('$r°')),
                      ],
                      onChanged: (v) => setState(() => rotation = v!),
                    ),
                  ),
                  SizedBox(
                    width: 160,
                    child: LTTextField(
                      controller: percent,
                      label: '缩放百分比 1–400',
                    ),
                  ),
                  SizedBox(
                    width: 160,
                    child: DropdownButtonFormField<String>(
                      initialValue: cropRatio,
                      decoration: const InputDecoration(labelText: '居中裁剪比例'),
                      items: [
                        for (final r in ['自由', '1:1', '4:3', '16:9', '9:16'])
                          DropdownMenuItem(value: r, child: Text(r)),
                      ],
                      onChanged: (v) => runUi(context, () async {
                        setState(() => cropRatio = v!);
                        if (v == '自由' || files.isEmpty) return;
                        final original = await ref
                            .read(imageToolProvider)
                            .preview(files.first.bytes, const ImageOptions());
                        final parts = v!.split(':').map(int.parse).toList(),
                            ratio = parts[0] / parts[1];
                        final cw = original.width / original.height > ratio
                            ? (original.height * ratio).floor()
                            : original.width;
                        final ch = (cw / ratio).floor();
                        crop.text =
                            '${(original.width - cw) ~/ 2},${(original.height - ch) ~/ 2},$cw,$ch';
                      }),
                    ),
                  ),
                ],
              ),
              CheckboxListTile(
                value: aspect,
                onChanged: (v) => setState(() => aspect = v!),
                title: const Text('保持比例（宽高均填写时适合边界）'),
              ),
              CheckboxListTile(
                value: noUpscale,
                onChanged: (v) => setState(() => noUpscale = v!),
                title: const Text('禁止放大'),
              ),
              CheckboxListTile(
                value: flipH,
                onChanged: (v) => setState(() => flipH = v!),
                title: const Text('水平翻转'),
              ),
              CheckboxListTile(
                value: flipV,
                onChanged: (v) => setState(() => flipV = v!),
                title: const Text('垂直翻转'),
              ),
              LTTextField(controller: textMark, label: '文字水印（中文可用，填写后优先于PNG）'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 120,
                    child: LTTextField(controller: markSize, label: '文字字号'),
                  ),
                  SizedBox(
                    width: 150,
                    child: LTTextField(
                      controller: markColor,
                      label: '文字颜色 RGB',
                    ),
                  ),
                  SizedBox(
                    width: 150,
                    child: LTTextField(
                      controller: markPercent,
                      label: 'PNG宽度百分比',
                    ),
                  ),
                  SizedBox(
                    width: 120,
                    child: LTTextField(controller: markMargin, label: '水印边距'),
                  ),
                  SizedBox(
                    width: 160,
                    child: DropdownButtonFormField<String>(
                      initialValue: markFont,
                      decoration: const InputDecoration(labelText: '水印字体'),
                      items: [
                        for (final f in ['系统默认', '等宽'])
                          DropdownMenuItem(value: f, child: Text(f)),
                      ],
                      onChanged: (v) => setState(() => markFont = v!),
                    ),
                  ),
                  SizedBox(
                    width: 180,
                    child: DropdownButtonFormField<String>(
                      initialValue: markPosition,
                      decoration: const InputDecoration(labelText: '水印位置'),
                      items: [
                        for (final e in {
                          'topLeft': '左上',
                          'topRight': '右上',
                          'bottomLeft': '左下',
                          'bottomRight': '右下',
                          'center': '居中',
                        }.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) => setState(() => markPosition = v!),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  const Text('水印透明度'),
                  Expanded(
                    child: Slider(
                      value: markOpacity,
                      onChanged: (v) => setState(() => markOpacity = v),
                    ),
                  ),
                ],
              ),
            ],
          ),
        if (!widget.conversionOnly) ...[
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('透明区域填充白底'),
            value: white,
            onChanged: busy ? null : (v) => setState(() => white = v ?? false),
          ),
          TextButton.icon(
            icon: const Icon(Icons.branding_watermark),
            label: Text(watermark == null ? '添加右下角图片水印' : '已选水印 · 点击替换'),
            onPressed: busy
                ? null
                : () => runUi(context, () async {
                    final file = await FilePicker.pickFile(
                      type: FileType.custom,
                      allowedExtensions: ['png'],
                    );
                    if (file != null) {
                      final bytes = await readToolFile(file, 2 * 1024 * 1024);
                      if (mounted) setState(() => watermark = bytes);
                    }
                  }),
          ),
        ],
        LTToolbar(
          children: [
            LTButton(
              label: '预览第一张',
              style: LTButtonStyle.secondary,
              onPressed: busy || files.isEmpty
                  ? null
                  : () => runUi(context, () async {
                      final image = await ref
                          .read(imageToolProvider)
                          .preview(files.first.bytes, await preparedOptions());
                      if (mounted) setState(() => preview = image);
                    }),
            ),
            LTButton(
              label: '确认并生成',
              loading: busy,
              onPressed: files.isEmpty ? null : () => runUi(context, generate),
            ),
            if (busy)
              TextButton(
                onPressed: () => token?.cancel(),
                child: const Text('取消后续处理'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(status),
        const SizedBox(height: 12),
        UtilityJobHistory(
          moduleId: widget.conversionOnly ? 'converter' : 'image_studio',
        ),
        if (preview != null) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 240,
            child: Image.memory(preview!.bytes, fit: BoxFit.contain),
          ),
          Text(
            '${preview!.width} × ${preview!.height} · ${readableBytes(preview!.bytes.length)}',
          ),
          if (files.isNotEmpty)
            Text(
              '处理前 ${readableBytes(files.first.bytes.length)} → 处理后 ${readableBytes(preview!.bytes.length)} · ${((preview!.bytes.length / files.first.bytes.length) * 100).toStringAsFixed(1)}%（大小比例不代表画质）',
            ),
          ExpansionTile(
            title: const Text('查看来源 EXIF（仅本机显示）'),
            children: [
              SelectableText(
                preview!.exif.isEmpty ? '来源没有 EXIF' : preview!.exif,
              ),
            ],
          ),
        ],
        const Divider(height: 32),
        const Text('已保存的真实输出'),
        outputs.when(
          loading: () => const LTLoadingState(),
          error: (_, stack) => const LTErrorState(),
          data: (items) => Column(
            children: [
              for (final output in items.take(50))
                ListTile(
                  title: Text(
                    output.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${output.number('width')} × ${output.number('height')} · ${output.text('format')} · ${readableBytes(output.number('size'))}',
                  ),
                  trailing: IconButton(
                    tooltip: '导出图片',
                    icon: const Icon(Icons.save_alt),
                    onPressed: () => export(output),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class PersonalTimelinePage extends ConsumerStatefulWidget {
  const PersonalTimelinePage({super.key});
  @override
  ConsumerState<PersonalTimelinePage> createState() =>
      _PersonalTimelinePageState();
}

class _PersonalTimelinePageState extends ConsumerState<PersonalTimelinePage> {
  DateTime? day;
  bool calendar = false;
  Future<void> edit([ToolRecord? record]) async {
    final projects = await ref.read(recordStoreProvider).list('project');
    if (!mounted) return;
    final values = await ltEditForm(
      context,
      title: record == null ? '新建个人待办' : '编辑个人待办',
      description: '个人待办不会触发 Agent 执行。提醒目前为应用内到期提示。',
      fields: [
        LTField('title', '标题', initial: record?.title ?? '', required: true),
        LTField('body', '说明', initial: record?.body ?? '', multiline: true),
        LTField(
          'due',
          '本地截止时间（YYYY-MM-DD HH:MM，可留空）',
          initial: record == null
              ? ''
              : PersonalTimeline.due(record)
                        ?.toIso8601String()
                        .substring(0, 16)
                        .replaceFirst('T', ' ') ??
                    '',
        ),
        LTField(
          'priority',
          '优先级 0–3（3最高）',
          initial: '${record?.number('priority', 1) ?? 1}',
        ),
        LTField(
          'projectId',
          '所属项目',
          initial: record?.text('projectId') ?? '',
          options: {
            '': '无项目',
            for (final project in projects) project.id: project.title,
          },
        ),
      ],
    );
    if (values == null || !mounted) return;
    await runUi(context, () async {
      final date = PersonalTimeline.parseLocalDate(values['due']!);
      if (values['due']!.trim().isNotEmpty && date == null) {
        throw const ToolFailure('截止时间格式无效。');
      }
      await ref
          .read(personalTimelineProvider)
          .save(
            values['title']!,
            description: values['body']!,
            projectId: values['projectId']!,
            due: date,
            priority: int.tryParse(values['priority']!) ?? -1,
            existing: record,
          );
    });
  }

  @override
  Widget build(BuildContext context) {
    final todos = ref.watch(recordsProvider('personal_todo'));
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        LTToolbar(
          children: [
            LTButton(label: '新建个人待办', icon: Icons.add_task, onPressed: edit),
            LTButton(
              label: calendar ? '时间轴视图' : '日历视图',
              style: LTButtonStyle.secondary,
              onPressed: () => setState(() => calendar = !calendar),
            ),
            if (day != null)
              TextButton(
                onPressed: () => setState(() => day = null),
                child: const Text('显示全部日期'),
              ),
          ],
        ),
        if (calendar)
          CalendarDatePicker(
            initialDate: day ?? DateTime.now(),
            firstDate: DateTime(2000),
            lastDate: DateTime(2100),
            onDateChanged: (v) => setState(() => day = v),
          ),
        const SizedBox(height: 16),
        todos.when(
          loading: () => const LTLoadingState(),
          error: (_, stack) => const LTErrorState(),
          data: (all) {
            final items =
                all.where((r) {
                  final d = PersonalTimeline.due(r);
                  return day == null ||
                      (d != null &&
                          d.year == day!.year &&
                          d.month == day!.month &&
                          d.day == day!.day);
                }).toList()..sort((a, b) {
                  final first = (PersonalTimeline.due(a) ?? DateTime(9999))
                      .compareTo(PersonalTimeline.due(b) ?? DateTime(9999));
                  return first != 0
                      ? first
                      : b.number('priority').compareTo(a.number('priority'));
                });
            if (items.isEmpty) {
              return const LTEmptyState(
                title: '为下一步留个位置',
                message: '按日期和优先级记录个人事项，与 Agent 任务分开。',
              );
            }
            return Column(
              children: [
                for (final r in items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: LTCard(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        leading: Checkbox(
                          value: r.text('status') == 'done',
                          onChanged: (v) => runUi(
                            context,
                            () => ref
                                .read(personalTimelineProvider)
                                .setState(r, v == true ? 'done' : 'todo'),
                          ),
                        ),
                        title: Text(r.title),
                        subtitle: Text(
                          '${PersonalTimeline.due(r) == null ? '未设截止' : readableTime(PersonalTimeline.due(r)!)} · 优先级${r.number('priority')} ${PersonalTimeline.overdue(r, DateTime.now()) ? '· 已到期' : ''}',
                        ),
                        onTap: () => edit(r),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) => runUi(
                            context,
                            () => v == 'delete'
                                ? ref.read(recordStoreProvider).delete(r)
                                : ref
                                      .read(personalTimelineProvider)
                                      .setState(r, v),
                          ),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'doing', child: Text('标为进行中')),
                            PopupMenuItem(value: 'todo', child: Text('标为待办')),
                            PopupMenuItem(value: 'delete', child: Text('删除待办')),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
