import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/platform/system_actions.dart';
import '../../core/ui/lt_components.dart';
import '../../core/ui/lt_scroll_page.dart';
import '../../shared/record_ui.dart';
import '../hub/hub_actions.dart';
import 'job_widgets.dart';
import 'utility_providers.dart';

class LanTransferPage extends ConsumerStatefulWidget {
  const LanTransferPage({super.key});
  @override
  ConsumerState<LanTransferPage> createState() => _LanTransferPageState();
}

class _LanTransferPageState extends ConsumerState<LanTransferPage> {
  Future<void> configure() async => runUi(context, () async {
    final picked = await FilePicker.pickFile(
      dialogTitle: '选择官方LocalSend图形应用EXE',
    );
    if (picked?.path == null || !mounted) return;
    final service = ref.read(lanTransferProvider);
    await ref
        .read(utilityJobsProvider)
        .submit(
          'lan_transfer',
          'configure',
          '核对LocalSend外部应用',
          {'path': picked!.path},
          confirmed: true,
          run: (job, _) async =>
              (await service.configure(picked.path!, job)).id,
        );
  });
  Future<void> prepare(bool folder) async => runUi(context, () async {
    String? directory;
    final paths = <String>[];
    if (folder) {
      directory = await FilePicker.getDirectoryPath(
        dialogTitle: '选择生成校验清单的文件夹',
      );
      if (directory == null) return;
    } else {
      paths.addAll(
        (await FilePicker.pickFiles()).map((f) {
          if (f.path == null) {
            throw const ToolFailure('文件没有本地路径。');
          }
          return f.path!;
        }),
      );
      if (paths.isEmpty) return;
    }
    if (!mounted) return;
    final service = ref.read(lanTransferProvider);
    await ref
        .read(utilityJobsProvider)
        .submit(
          'lan_transfer',
          'prepare',
          '准备发送校验清单',
          {'paths': paths, 'directory': directory},
          confirmed: true,
          run: (job, _) async =>
              (await service.prepare(paths, job, directory: directory)).id,
        );
  });
  Future<void> verify() async => runUi(context, () async {
    final json = await FilePicker.pickFile(dialogTitle: '选择通过可信渠道取得的发送清单JSON');
    if (json?.path == null || !mounted) return;
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择接收目录；文件相对路径需与清单一致',
    );
    if (directory == null || !mounted) return;
    final service = ref.read(lanTransferProvider);
    await ref
        .read(utilityJobsProvider)
        .submit(
          'lan_transfer',
          'verify',
          '核验所选接收目录',
          {'manifest': json!.path, 'directory': directory},
          confirmed: true,
          run: (job, _) async =>
              (await service.verifyReceived(json.path!, directory, job)).id,
        );
  });
  Future<void> export(ToolRecord row) async => runUi(context, () async {
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择清单输出目录（不会覆盖同名文件）',
    );
    if (directory == null || !mounted) return;
    final service = ref.read(lanTransferProvider);
    await ref
        .read(utilityJobsProvider)
        .submit(
          'lan_transfer',
          'export',
          '导出不含源绝对路径的校验清单',
          {'manifestId': row.id, 'directory': directory},
          confirmed: true,
          run: (job, _) async => (await service.export(row, directory, job)).id,
        );
  });
  Future<void> handoff(
    ToolRecord row,
    ToolRecord runtime,
  ) async => runUi(context, () async {
    if (!await ltConfirm(
      context,
      title: '核对文件后启动外部LocalSend？',
      message:
          '应用：${runtime.text('path')}\n版本：${runtime.text('version')} · 签名状态：${runtime.text('signatureStatus')}\n启动后LocalSend会按自身设置开启局域网发现与接收服务。设备选择、接收确认、速度、进度和取消均在其窗口中操作。请核对设备身份，关闭无需的接收服务。\n${row.text('directory').isEmpty ? '将所选文件作为参数传给LocalSend。' : '文件夹请在LocalSend中重新选择原文件夹以保留目录结构。'}\n此步骤不代表发送成功。',
    )) {
      return;
    }
    if (!mounted) return;
    final service = ref.read(lanTransferProvider),
        engine = ref.read(utilityJobsProvider),
        native = ref.read(nativePlatformProvider);
    TargetAction? action;
    final submitted = await engine.submit(
      'lan_transfer',
      'preflight',
      '重新核验外部调用输入',
      {'manifestId': row.id, 'runtimeId': runtime.id},
      confirmed: true,
      run: (job, _) async {
        action = await service.handoff(runtime, row, job);
        return row.id;
      },
    );
    final done = await engine.waitFor(submitted.id);
    if (utilityJobStatus(done) != UtilityJobStatus.succeeded) {
      throw ToolFailure(done.text('errorMessage'));
    }
    if (!mounted || action == null) return;
    await native.launch(action!, confirmed: true);
    await service.recordHandoff(row);
  });
  @override
  Widget build(BuildContext context) {
    final manifests = ref.watch(recordsProvider('transfer_manifest')),
        runtimes =
            ref.watch(recordsProvider('transfer_runtime')).asData?.value ?? [],
        checks =
            ref.watch(recordsProvider('transfer_verification')).asData?.value ??
            [];
    return manifests.when(
      loading: () => const LTLoadingState(),
      error: (_, _) => const LTErrorState(),
      data: (rows) => LTScrollPage(
        title: '局域网互传 · LocalSend外部调用',
        description: '工具箱生成和核验真实文件清单。传输由独立安装的LocalSend处理，不经过云服务器。两台真机互传尚未验证；此页不显示未经确认的网络进度或送达状态。',
        header: [
          LTCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '操作顺序：准备文件和校验清单 → 启动LocalSend → 选择目标设备并由接收端确认 → 接收端使用清单核验。文件夹的清单路径以所选文件夹内部为根。清单不含源绝对路径，需通过可信渠道传递。',
                ),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: () => runUi(
                        context,
                        () => openTarget(
                          context,
                          ref,
                          const TargetAction(
                            'url',
                            'https://localsend.org/download',
                          ),
                        ),
                      ),
                      child: const Text('官方安装与移动端下载'),
                    ),
                    if (Platform.isWindows)
                      TextButton(
                        onPressed: configure,
                        child: const Text('配置已安装LocalSend'),
                      ),
                  ],
                ),
                Text(
                  runtimes.isEmpty
                      ? '尚未配置外部应用；可以先准备清单。'
                      : '外部版本：${runtimes.first.text('version')} · ${runtimes.first.text('signatureStatus')}',
                ),
              ],
            ),
          ),
          if (Platform.isWindows)
            LTToolbar(
              children: [
                LTButton(label: '选择文件并准备清单', onPressed: () => prepare(false)),
                TextButton(
                  onPressed: () => prepare(true),
                  child: const Text('文件夹校验清单'),
                ),
                TextButton(onPressed: verify, child: const Text('核验接收目录')),
              ],
            )
          else
            const Text('移动端请使用LocalSend独立应用传输；本页暂浏览历史，不宣称内嵌移动传输。'),
          const UtilityJobSummary(moduleId: 'lan_transfer'),
          if (checks.isNotEmpty)
            LTCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('接收核验记录'),
                  for (final row in checks.take(20))
                    ExpansionTile(
                      title: Text(
                        '${row.createdAt.toLocal()} · ${row.text('status')} · ${row.number('matched')}/${row.number('fileCount')}一致',
                      ),
                      children: [
                        Text(row.text('message')),
                        for (final item in (row.data['results'] as List).take(
                          100,
                        ))
                          ListTile(
                            title: Text('${(item as Map)['name']}'),
                            subtitle: Text('${item['status']}'),
                          ),
                        if ((row.data['results'] as List).length > 100)
                          const Text('其余结果可在任务输出记录JSON中导出。'),
                      ],
                    ),
                ],
              ),
            ),
        ],
        itemCount: rows.length,
        empty: const LTEmptyState(
          title: '选择真实文件生成校验清单',
          message: '未启动外部应用时，工具箱不会监听端口或发现局域网设备。',
        ),
        itemBuilder: (context, i) {
          final row = rows[i];
          return LTCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${row.title} · ${row.number('fileCount')}文件 / ${row.number('totalBytes')}字节',
                ),
                Text(
                  '${row.createdAt.toLocal()} · ${row.text('status') == 'external-opened' ? '已打开外部应用，送达状态未知' : '清单已准备，尚未确认送达'}',
                ),
                if (row.text('directory').isNotEmpty)
                  SelectableText(row.text('directory')),
                ExpansionTile(
                  title: const Text('文件与SHA256'),
                  children: [
                    for (final raw in (row.data['files'] as List).take(30))
                      ListTile(
                        title: Text('${(raw as Map)['name']}'),
                        subtitle: SelectableText(
                          '${raw['size']}字节\n${raw['sha256']}',
                        ),
                      ),
                  ],
                ),
                if (Platform.isWindows)
                  Wrap(
                    children: [
                      TextButton(
                        onPressed: () => export(row),
                        child: const Text('导出清单JSON'),
                      ),
                      TextButton(
                        onPressed: runtimes.isEmpty
                            ? null
                            : () => handoff(row, runtimes.first),
                        child: const Text('核验并打开LocalSend'),
                      ),
                    ],
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
