import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/ui/lt_components.dart';

/// Display only persisted work. No counters or fabricated progress on an empty DB.
class WorkspaceActivity extends ConsumerWidget {
  const WorkspaceActivity({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks =
        ref.watch(recordsProvider('studio_task')).asData?.value ??
        <ToolRecord>[];
    final jobs =
        ref.watch(recordsProvider('utility_job')).asData?.value ??
        <ToolRecord>[];
    final pending = [...tasks, ...jobs]
        .where(
          (r) => !{
            'completed',
            'succeeded',
            'failed',
            'cancelled',
            'interrupted',
            'rejected',
          }.contains(r.text('status')),
        )
        .take(5)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LTSectionHeader(
          '当前任务',
          action: TextButton(
            onPressed: () => context.go('/modules/studio?view=tasks'),
            child: const Text('任务中心'),
          ),
        ),
        if (pending.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('没有正在执行的任务。'),
          ),
        for (final task in pending)
          ListTile(
            leading: const Icon(Icons.pending_actions),
            title: Text(
              task.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              task.text('status') == 'waitingApproval'
                  ? '等待审批'
                  : task.text('status'),
            ),
            onTap: () => context.go(
              task.kind == 'studio_task'
                  ? '/modules/studio?view=tasks'
                  : '/modules/utility_jobs',
            ),
          ),
        const SizedBox(height: 16),
      ],
    );
  }
}
