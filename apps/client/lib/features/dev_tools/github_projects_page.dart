import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/platform/system_actions.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/page_frame.dart';
import '../../shared/record_ui.dart';
import '../hub/hub_actions.dart';
import 'api_studio_page.dart';
import 'github_projects.dart';
import 'dev_tool_widgets.dart';

final githubProjectsProvider = Provider(
  (ref) => GitHubProjectService(
    ref.watch(recordStoreProvider),
    ref.watch(apiStudioProvider),
  ),
);

class GitHubProjectsPage extends ConsumerStatefulWidget {
  const GitHubProjectsPage({super.key});
  @override
  ConsumerState<GitHubProjectsPage> createState() => _GitHubProjectsPageState();
}

class _GitHubProjectsPageState extends ConsumerState<GitHubProjectsPage> {
  final input = TextEditingController();
  bool busy = false;
  Map<String, dynamic>? preview;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> fetch() async {
    setState(() => busy = true);
    try {
      final result = await ref.read(githubProjectsProvider).fetch(input.text);
      if (mounted) setState(() => preview = result);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> open(ToolRecord row, String suffix) async {
    await openTarget(
      context,
      ref,
      TargetAction(
        'url',
        'https://github.com/${normalizeRepository(row.text('repository'))}$suffix',
      ),
    );
    final latest = await ref.read(recordStoreProvider).get(row.id);
    if (latest != null) {
      await ref
          .read(recordStoreProvider)
          .save(
            latest.copyWith(
              data: {
                ...latest.data,
                'lastOpened': DateTime.now().toUtc().toIso8601String(),
              },
            ),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = [
      ...ref.watch(recordsProvider('github_project')).asData?.value ??
          <ToolRecord>[],
    ]..sort((a, b) => b.text('lastOpened').compareTo(a.text('lastOpened')));
    return PageFrame(
      eyebrow: 'PROJECT TOOLS',
      title: 'GitHub Projects',
      description: '保存公开仓库、Issue入口、Release记录与本地项目关联；只在点击时读取公开API，不要求Token。',
      children: [
        LTTextField(controller: input, label: 'owner/repo 或仓库根地址'),
        LTToolbar(
          children: [
            LTButton(
              label: '读取公开仓库',
              onPressed: busy ? null : () => runUi(context, fetch),
            ),
            TextButton(
              onPressed: () => runUi(context, () async {
                await ref
                    .read(githubProjectsProvider)
                    .save(
                      input.text,
                      snapshot:
                          preview?['repository'] ==
                              normalizeRepository(input.text)
                          ? preview
                          : null,
                    );
              }),
              child: const Text('收藏仓库'),
            ),
          ],
        ),
        if (busy) const LinearProgressIndicator(),
        if (preview != null) JsonTree(value: preview),
        const SizedBox(height: 16),
        const LTSectionHeader('已收藏 / 最近打开'),
        for (final row in rows)
          LTCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(row.title, style: Theme.of(context).textTheme.titleMedium),
                if (row.data['snapshot'] is Map)
                  Text('${(row.data['snapshot'] as Map)['description']}'),
                Text(
                  row.text('lastOpened').isEmpty
                      ? '尚未打开'
                      : '最近打开 ${row.text('lastOpened')}',
                ),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: () => runUi(context, () => open(row, '')),
                      child: const Text('仓库'),
                    ),
                    TextButton(
                      onPressed: () =>
                          runUi(context, () => open(row, '/issues')),
                      child: const Text('Issues'),
                    ),
                    TextButton(
                      onPressed: () =>
                          runUi(context, () => open(row, '/releases')),
                      child: const Text('Releases'),
                    ),
                    TextButton(
                      onPressed: () => runUi(context, () async {
                        input.text = row.text('repository');
                        await fetch();
                        await ref
                            .read(githubProjectsProvider)
                            .save(
                              row.text('repository'),
                              existing: row,
                              localPath: row.text('localPath'),
                              snapshot: preview,
                            );
                      }),
                      child: const Text('刷新记录'),
                    ),
                    TextButton(
                      onPressed: () => runUi(context, () async {
                        final path = await FilePicker.getDirectoryPath(
                          dialogTitle: '关联本地项目目录',
                        );
                        if (path != null) {
                          await ref
                              .read(githubProjectsProvider)
                              .save(
                                row.text('repository'),
                                existing: row,
                                localPath: path,
                              );
                        }
                      }),
                      child: const Text('关联本地项目'),
                    ),
                    if (row.text('localPath').isNotEmpty)
                      TextButton(
                        onPressed: () => runUi(
                          context,
                          () => openTarget(
                            context,
                            ref,
                            TargetAction('folder', row.text('localPath')),
                          ),
                        ),
                        child: const Text('打开本地目录'),
                      ),
                    TextButton(
                      onPressed: () => runUi(context, () async {
                        if (await ltConfirm(
                          context,
                          title: '移除仓库记录？',
                          message: '只移除本机收藏，不修改远端或本地代码。',
                        )) {
                          await ref.read(recordStoreProvider).delete(row);
                        }
                      }),
                      child: const Text('移除'),
                    ),
                  ],
                ),
                if (row.data['snapshot'] is Map)
                  JsonTree(value: row.data['snapshot'], label: '上次公开读取记录'),
              ],
            ),
          ),
      ],
    );
  }
}
