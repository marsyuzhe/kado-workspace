import 'package:crypto/crypto.dart';

import '../../core/data/tool_record.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../app/data_providers.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/ui/lt_components.dart';
import '../../core/platform/system_actions.dart';
import '../../shared/record_ui.dart';
import 'utility_providers.dart';

class UtilityJobHistory extends ConsumerWidget {
  const UtilityJobHistory({
    super.key,
    this.moduleId,
    this.activeOnly = false,
    this.terminalOnly = false,
  });
  final bool activeOnly, terminalOnly;
  final String? moduleId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = ref.watch(utilityJobsReadyProvider);
    if (ready.isLoading) return const LTLoadingState();
    if (ready.hasError) return const LTErrorState(message: '工具任务恢复失败，原记录保留。');
    return ref
        .watch(recordsProvider('utility_job'))
        .when(
          loading: () => const LTLoadingState(),
          error: (_, _) => const LTErrorState(),
          data: (rows) {
            final jobs = rows
                .where(
                  (r) =>
                      (moduleId == null || r.text('moduleId') == moduleId) &&
                      (!activeOnly || !utilityJobStatus(r).terminal) &&
                      (!terminalOnly || utilityJobStatus(r).terminal),
                )
                .take(30)
                .toList();
            if (jobs.isEmpty) {
              if (activeOnly) return const SizedBox.shrink();
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Text('尚无工具任务。处理后才会显示真实进度和输出。'),
              );
            }
            return Column(
              children: [
                for (final row in jobs)
                  LTCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          row.title,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '${utilityJobStatus(row).label} · ${row.number('processedItems')}/${row.number('totalItems')} · 输出${row.strings('outputReferences').length}项',
                        ),
                        if (!utilityJobStatus(row).terminal)
                          LinearProgressIndicator(
                            value: row.data['progress'] is num
                                ? (row.data['progress'] as num).toDouble()
                                : null,
                          ),
                        if (row.text('currentFile').isNotEmpty)
                          Text(
                            row.text('currentFile'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (row.text('errorMessage').isNotEmpty)
                          Text(row.text('errorMessage')),
                        Text(
                          readableTime(row.updatedAt),
                          style: const TextStyle(fontSize: 11),
                        ),
                        if (row.strings('outputReferences').isNotEmpty)
                          ExpansionTile(
                            title: const Text('查看输出与处理记录'),
                            children: [
                              for (final id in row.strings('outputReferences'))
                                UtilityOutputReference(id: id),
                            ],
                          ),
                        if ({
                          UtilityJobStatus.failed,
                          UtilityJobStatus.cancelled,
                          UtilityJobStatus.interrupted,
                        }.contains(utilityJobStatus(row)))
                          TextButton(
                            onPressed: () =>
                                context.go('/modules/${row.text('moduleId')}'),
                            child: const Text('重新选择输入并预览新任务'),
                          ),
                        ref
                            .watch(recordsProvider('utility_log'))
                            .when(
                              loading: () => const SizedBox.shrink(),
                              error: (_, _) => const SizedBox.shrink(),
                              data: (logs) => Column(
                                children: [
                                  for (final log in logs.where(
                                    (r) => r.text('jobId') == row.id,
                                  ))
                                    ExpansionTile(
                                      title: Text(log.title),
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: SelectableText(log.body),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                        if (!utilityJobStatus(row).terminal)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () => runUi(
                                context,
                                () => ref
                                    .read(utilityJobsProvider)
                                    .cancel(row.id),
                              ),
                              child: const Text('取消任务'),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            );
          },
        );
  }
}

/// Active progress stays visible; completed history does not bury tool content.
class UtilityJobSummary extends StatelessWidget {
  const UtilityJobSummary({super.key, required this.moduleId});
  final String moduleId;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      UtilityJobHistory(moduleId: moduleId, activeOnly: true),
      ExpansionTile(
        title: const Text('已结束任务与输出记录'),
        children: [UtilityJobHistory(moduleId: moduleId, terminalOnly: true)],
      ),
    ],
  );
}

class UtilityOutputReference extends ConsumerWidget {
  const UtilityOutputReference({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(recordByIdProvider(id))
      .when(
        loading: () =>
            const Padding(padding: EdgeInsets.all(8), child: Text('读取输出…')),
        error: (_, _) => const Text('输出记录读取失败'),
        data: (row) {
          if (row == null) return const ListTile(title: Text('输出记录已不存在'));
          final external = row.text('outputPath').isNotEmpty
              ? row.text('outputPath')
              : row.text('installerPath').isNotEmpty
              ? row.text('installerPath')
              : row.text('path');
          return ListTile(
            title: Text(row.title),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (external.isNotEmpty) SelectableText(external),
                if (row.text('outputDirectory').isNotEmpty)
                  SelectableText(row.text('outputDirectory')),
                if (row.text('checksum').isNotEmpty)
                  SelectableText('SHA256 ${row.text('checksum')}'),
                if (row.text('status').isNotEmpty)
                  Text('状态：${row.text('status')}'),
                Wrap(
                  children: [
                    if (row.kind == 'web_export' &&
                        row.text('attachment').isNotEmpty)
                      TextButton(
                        onPressed: () => runUi(context, () async {
                          final owned = await ref.read(
                                ownedFilesProvider.future,
                              ),
                              file = owned.resolve(row.text('attachment'));
                          if (!await file.exists() ||
                              await file.length() != row.number('size')) {
                            throw const ToolFailure('网站导出文件缺失或大小已变化，请重新导出。');
                          }
                          final bytes = await file.readAsBytes();
                          if (sha256.convert(bytes).toString() !=
                              row.text('checksum')) {
                            throw const ToolFailure('网站导出文件校验失败，请重新导出。');
                          }
                          final format = row.text('format');
                          if (!{'json', 'html', 'csv'}.contains(format)) {
                            throw const ToolFailure('导出格式无效。');
                          }
                          final saved = await FilePicker.saveFile(
                            fileName: 'KADO-Desk-websites-${row.id}.$format',
                            bytes: bytes,
                            mimeType: format == 'json'
                                ? 'application/json'
                                : format == 'csv'
                                ? 'text/csv'
                                : 'text/html',
                          );
                          if (saved != null && context.mounted) {
                            ltMessage(context, '网站文件已保存。');
                          }
                        }),
                        child: const Text('保存网站导出文件'),
                      ),
                    if (Platform.isWindows &&
                        (external.isNotEmpty ||
                            row.text('outputDirectory').isNotEmpty ||
                            row.text('attachment').isNotEmpty))
                      TextButton(
                        onPressed: () => runUi(context, () async {
                          final path = external.isNotEmpty
                              ? external
                              : row.text('outputDirectory').isNotEmpty
                              ? row.text('outputDirectory')
                              : (await ref.read(ownedFilesProvider.future))
                                    .resolve(row.text('attachment'))
                                    .path;
                          final directory =
                              row.text('outputDirectory').isNotEmpty
                              ? row.text('outputDirectory')
                              : p.dirname(path);
                          if (!context.mounted ||
                              !await ltConfirm(
                                context,
                                title: '打开输出目录？',
                                message: directory,
                              )) {
                            return;
                          }
                          await ref
                              .read(nativePlatformProvider)
                              .launch(
                                TargetAction('folder', directory),
                                confirmed: true,
                              );
                        }),
                        child: const Text('打开输出目录'),
                      ),
                    if (row.kind == 'transcript')
                      TextButton(
                        onPressed: () =>
                            context.go('/modules/transcribe?id=${row.id}'),
                        child: const Text('编辑或导出字幕'),
                      ),
                    TextButton(
                      onPressed: () => runUi(context, () async {
                        await FilePicker.saveFile(
                          fileName: 'Links-output-${row.id}.json',
                          bytes: Uint8List.fromList(
                            utf8.encode(
                              const JsonEncoder.withIndent('  ').convert({
                                'id': row.id,
                                'kind': row.kind,
                                'title': row.title,
                                'data': row.data,
                              }),
                            ),
                          ),
                          mimeType: 'application/json',
                        );
                      }),
                      child: const Text('导出输出记录JSON'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
}

class UtilityJobsPage extends StatelessWidget {
  const UtilityJobsPage({super.key});
  @override
  Widget build(BuildContext context) => const SingleChildScrollView(
    padding: EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('工具任务', style: TextStyle(fontSize: 24)),
        SizedBox(height: 16),
        UtilityJobHistory(),
      ],
    ),
  );
}
