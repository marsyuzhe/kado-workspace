import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/platform/system_actions.dart';
import '../../core/ui/lt_components.dart';
import '../../core/ui/lt_scroll_page.dart';
import '../../shared/record_ui.dart';
import '../archive/archive_service.dart';
import '../hub/hub_actions.dart';
import 'media_library.dart';
import 'utility_providers.dart';
import 'job_widgets.dart';

class MediaLibraryPage extends ConsumerStatefulWidget {
  const MediaLibraryPage({super.key});
  @override
  ConsumerState<MediaLibraryPage> createState() => _MediaLibraryPageState();
}

class _MediaLibraryPageState extends ConsumerState<MediaLibraryPage> {
  String query = '', format = '全部', after = '';
  bool favorites = false;
  Future<void> importMedia(bool folder) async => runUi(context, () async {
    String? directory;
    final paths = <String>[];
    if (folder) {
      directory = await FilePicker.getDirectoryPath(
        dialogTitle: '授权扫描视频目录，只建立索引',
      );
      if (directory == null) return;
      await ref.read(archiveServiceProvider).grant(directory);
    } else {
      for (final file in await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: MediaLibraryService.extensions.toList(),
      )) {
        if (file.path != null) paths.add(file.path!);
      }
      if (paths.isEmpty) return;
    }
    if (!mounted ||
        !await ltConfirm(
          context,
          title: '建立视频素材索引？',
          message:
              '${directory ?? paths.take(5).join('\n')}\n不移动原始视频；实际探测轨道、时长和画面，最多500素材，缩略图保存在独立受限缓存。',
        )) {
      return;
    }
    if (!mounted) return;
    final service = ref.read(mediaLibraryProvider), root = directory;
    await ref
        .read(utilityJobsProvider)
        .submit(
          'media_library',
          'index',
          '索引视频素材',
          {'directory': root, 'paths': paths},
          confirmed: true,
          run: (job, _) async {
            if (root != null) {
              await job.progress(0, 0, currentFile: '扫描授权目录', force: true);
              final scan = await ArchiveScanner().scan(root, job.cancellation);
              job.check();
              if (scan.limited || scan.errors.isNotEmpty) {
                throw const ToolFailure('扫描超限或部分目录不可读，请改选较小目录或单独选择文件。');
              }
              paths.addAll(
                scan.files
                    .where(
                      (f) => MediaLibraryService.extensions.any(
                        (ext) => f.name.toLowerCase().endsWith('.$ext'),
                      ),
                    )
                    .map((f) => f.path),
              );
            }
            final rows = await service.importPaths(paths, job);
            return rows.isEmpty ? null : rows.first.id;
          },
        );
  });
  Future<void> edit(ToolRecord row) async {
    final projects = await ref.read(recordStoreProvider).list('project'),
        tasks = await ref.read(recordStoreProvider).list('studio_task'),
        archives = await ref.read(recordStoreProvider).list('archive_file');
    if (!mounted) return;
    final values = await ltEditForm(
      context,
      title: '素材信息',
      fields: [
        LTField('title', '名称', initial: row.title, required: true),
        LTField('tags', '标签（逗号分隔）', initial: row.strings('tags').join(',')),
        LTField(
          'favorite',
          '喜爱',
          initial: row.flag('favorite') ? 'true' : 'false',
          options: const {'true': '是', 'false': '否'},
        ),
        LTField(
          'rating',
          '评分0–5',
          initial: '${row.number('rating')}',
          options: {for (var i = 0; i <= 5; i++) '$i': '$i'},
        ),
        LTField(
          'project',
          'Memory项目',
          initial: projects.any((r) => r.id == row.text('projectId'))
              ? row.text('projectId')
              : '',
          options: {'': '无', for (final r in projects) r.id: r.title},
        ),
        LTField(
          'task',
          'Studio任务',
          initial: tasks.any((r) => r.id == row.text('studioTaskId'))
              ? row.text('studioTaskId')
              : '',
          options: {'': '无', for (final r in tasks) r.id: r.title},
        ),
        LTField(
          'archive',
          '归档记录',
          initial: archives.any((r) => r.id == row.text('archiveId'))
              ? row.text('archiveId')
              : '',
          options: {'': '无', for (final r in archives) r.id: r.title},
        ),
        LTField('notes', '备注', initial: row.body, multiline: true),
      ],
    );
    if (values == null || !mounted) return;
    await runUi(
      context,
      () => ref
          .read(mediaLibraryProvider)
          .edit(
            row,
            title: values['title']!,
            tags: values['tags']!
                .split(',')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList(),
            notes: values['notes']!,
            favorite: values['favorite'] == 'true',
            rating: int.parse(values['rating']!),
            projectId: values['project']!,
            studioTaskId: values['task']!,
            archiveId: values['archive']!,
          ),
    );
  }

  Future<void> poster(ToolRecord row) async {
    final values = await ltEditForm(
      context,
      title: '从视频提取封面',
      fields: [
        LTField(
          'seconds',
          '时间点（秒）',
          initial: '${row.data['thumbnailTime'] ?? 0}',
          required: true,
        ),
      ],
    );
    if (values == null || !mounted) return;
    await runUi(context, () async {
      final service = ref.read(mediaLibraryProvider);
      await ref
          .read(utilityJobsProvider)
          .submit(
            'media_library',
            'poster',
            '提取 ${row.title} 封面',
            {'recordId': row.id, 'seconds': values['seconds']},
            confirmed: true,
            run: (job, _) async {
              final updated = await service.poster(
                row,
                double.tryParse(values['seconds']!) ?? -1,
                job,
              );
              await job.output(updated.id);
              await job.progress(1, 1, force: true);
              return updated.id;
            },
          );
    });
  }

  @override
  Widget build(BuildContext context) => ref
      .watch(recordsProvider('media_asset'))
      .when(
        loading: () => const LTLoadingState(),
        error: (_, _) => const LTErrorState(),
        data: (rows) {
          final items = rows
              .where(
                (r) =>
                    '${r.title} ${r.body} ${r.strings('tags').join(' ')}'
                        .toLowerCase()
                        .contains(query) &&
                    (!favorites || r.flag('favorite')) &&
                    (format == '全部' || r.text('format') == format) &&
                    (after.isEmpty || r.text('modified').compareTo(after) >= 0),
              )
              .toList();
          return LTScrollPage(
            title: '视频素材库',
            description: 'Windows优先：只建立索引和缓存封面，不移动视频。播放使用系统默认播放器，暂停与跳转由播放器提供；本版没有嵌入式播放器或拖拽导入。',
            header: [
              LTToolbar(
                children: [
                  LTButton(
                    label: '添加视频文件',
                    onPressed: Platform.isWindows
                        ? () => importMedia(false)
                        : null,
                  ),
                  LTButton(
                    label: '索引视频文件夹',
                    onPressed: Platform.isWindows
                        ? () => importMedia(true)
                        : null,
                  ),
                  TextButton(
                    onPressed: () =>
                        context.go('/modules/converter?view=media'),
                    child: const Text('配置FFmpeg'),
                  ),
                ],
              ),
              LTTextField(
                label: '搜索名称、标签、备注',
                onChanged: (v) => setState(() => query = v.toLowerCase()),
              ),
              Wrap(
                spacing: 12,
                children: [
                  DropdownButton<String>(
                    value: format,
                    items: [
                      for (final value in ['全部', 'mp4', 'mkv', 'mov'])
                        DropdownMenuItem(value: value, child: Text(value)),
                    ],
                    onChanged: (v) => setState(() => format = v!),
                  ),
                  FilterChip(
                    label: const Text('仅喜爱'),
                    selected: favorites,
                    onSelected: (v) => setState(() => favorites = v),
                  ),
                  SizedBox(
                    width: 220,
                    child: TextField(
                      decoration: const InputDecoration(
                        labelText: '修改日期下限 YYYY-MM-DD',
                      ),
                      onChanged: (v) => setState(() => after = v.trim()),
                    ),
                  ),
                  TextButton(
                    onPressed: () => runUi(context, () async {
                      final service = ref.read(mediaLibraryProvider),
                          current = await ref
                              .read(mediaLibraryProvider)
                              .cacheLimit();
                      if (!context.mounted) return;
                      final v = await ltEditForm(
                        context,
                        title: '缩略图缓存限额',
                        fields: [
                          LTField(
                            'limit',
                            'MiB（16–512）',
                            initial: '$current',
                            required: true,
                          ),
                        ],
                      );
                      if (v == null) return;
                      await ref
                          .read(utilityJobsProvider)
                          .submit(
                            'media_library',
                            'cache_limit',
                            '调整缩略图缓存限额',
                            {'limit': v['limit']},
                            confirmed: true,
                            run: (job, _) async {
                              await service.setCacheLimit(
                                int.tryParse(v['limit']!) ?? 0,
                              );
                              await job.progress(1, 1, force: true);
                              return null;
                            },
                          );
                    }),
                    child: const Text('缓存大小设置'),
                  ),
                  TextButton(
                    onPressed: () => runUi(context, () async {
                      if (!await ltConfirm(
                        context,
                        title: '清理全部视频缩略图缓存？',
                        message: '保留原视频与索引；需要时可重新提取封面。',
                      )) {
                        return;
                      }
                      final service = ref.read(mediaLibraryProvider);
                      await ref
                          .read(utilityJobsProvider)
                          .submit(
                            'media_library',
                            'clear_cache',
                            '清理视频封面缓存',
                            {},
                            confirmed: true,
                            run: (job, _) async {
                              await service.clearCache(
                                confirmed: true,
                                job: job,
                              );
                              return null;
                            },
                          );
                    }),
                    child: const Text('清理缩略图'),
                  ),
                ],
              ),
              const UtilityJobHistory(moduleId: 'media_library'),
              Text('当前${items.length} / ${rows.length}素材'),
            ],
            itemCount: items.length,
            empty: const LTEmptyState(
              title: '加入自己的视频素材',
              message: '从授权文件或目录读取实际媒体信息，缓存封面后再分类。',
            ),
            itemBuilder: (context, i) {
              final row = items[i];
              return LTCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FutureBuilder<Uint8List?>(
                      future: ref.read(mediaLibraryProvider).thumbnail(row),
                      builder: (context, snapshot) => snapshot.data == null
                          ? const SizedBox(
                              height: 50,
                              child: Center(child: Text('封面未缓存，可手动提取')),
                            )
                          : Image.memory(
                              snapshot.data!,
                              height: 140,
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) =>
                                  const Text('封面缓存损坏，请重新提取'),
                            ),
                    ),
                    Text(
                      '${row.title}${row.flag('favorite') ? ' ★' : ''}',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${(row.data['duration'] as num).toStringAsFixed(2)}秒 · ${row.number('width')}×${row.number('height')} · ${row.text('frameRate')}fps · ${row.text('videoCodec')} · ${readableBytes(row.number('size'))}',
                    ),
                    SelectableText(row.text('path')),
                    Text(
                      '${row.strings('tags').join(' / ')} · 评分${row.number('rating')}/5',
                    ),
                    if (row.body.isNotEmpty) Text(row.body),
                    Text(
                      '上次检测${row.flag('lastExists') ? '存在' : '缺失'}${row.flag('changed') ? '，源文件已变化，请重新索引' : ''} · ${row.text('lastCheckedAt')}',
                    ),
                    if (row.text('thumbnailError').isNotEmpty)
                      Text(row.text('thumbnailError')),
                    Wrap(
                      children: [
                        TextButton(
                          onPressed: () => edit(row),
                          child: const Text('编辑分类与关联'),
                        ),
                        TextButton(
                          onPressed: Platform.isWindows
                              ? () => poster(row)
                              : null,
                          child: const Text('指定时间封面'),
                        ),
                        TextButton(
                          onPressed: () => runUi(
                            context,
                            () => ref.read(mediaLibraryProvider).check(row),
                          ),
                          child: const Text('重新检查文件'),
                        ),
                        if (Platform.isWindows)
                          TextButton(
                            onPressed: () => runUi(
                              context,
                              () => openTarget(
                                context,
                                ref,
                                TargetAction('file', row.text('path')),
                                title: row.title,
                              ),
                            ),
                            child: const Text('用系统播放器打开'),
                          ),
                        if (row.text('projectId').isNotEmpty)
                          TextButton(
                            onPressed: () => context.go(
                              '/modules/memory?id=${row.text('projectId')}',
                            ),
                            child: const Text('关联项目'),
                          ),
                        if (row.text('studioTaskId').isNotEmpty)
                          TextButton(
                            onPressed: () =>
                                context.go('/modules/studio?view=tasks'),
                            child: const Text('关联任务列表'),
                          ),
                        if (row.text('archiveId').isNotEmpty)
                          TextButton(
                            onPressed: () => context.go(
                              '/modules/archive?id=${row.text('archiveId')}',
                            ),
                            child: const Text('归档详情'),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
}
