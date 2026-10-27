import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/platform/system_actions.dart';
import '../../core/ui/lt_components.dart';
import '../../core/ui/lt_scroll_page.dart';
import '../../shared/record_ui.dart';
import '../hub/hub_actions.dart';
import 'home_dashboard.dart';
import 'utility_providers.dart';
import 'job_widgets.dart';

class HomeDashboardPage extends ConsumerStatefulWidget {
  const HomeDashboardPage({super.key});
  @override
  ConsumerState<HomeDashboardPage> createState() => _HomeDashboardPageState();
}

class _HomeDashboardPageState extends ConsumerState<HomeDashboardPage> {
  String query = '', type = '全部';
  Future<void> edit([ToolRecord? row]) async {
    final values = await ltEditForm(
      context,
      title: row == null ? '添加家庭设备' : '编辑家庭设备',
      fields: [
        LTField('name', '名称', initial: row?.title ?? '', required: true),
        LTField(
          'type',
          '设备类型',
          initial: row?.text('type') ?? 'NAS',
          options: {for (final t in HomeDeviceInput.types) t: t},
        ),
        LTField(
          'host',
          'IP或DNS主机名',
          initial: row?.text('host') ?? '',
          required: true,
        ),
        LTField(
          'port',
          '端口',
          initial: '${row?.number('port') ?? 80}',
          required: true,
        ),
        LTField(
          'protocol',
          '协议',
          initial: row?.text('protocol') ?? 'http',
          options: const {'http': 'HTTP', 'https': 'HTTPS', 'tcp': '仅TCP'},
        ),
        LTField(
          'url',
          '管理网址（可空，禁止内嵌凭据）',
          initial: row?.text('managementUrl') ?? '',
        ),
        LTField(
          'tags',
          '标签（逗号分隔）',
          initial: row?.strings('tags').join(',') ?? '',
        ),
        LTField(
          'notes',
          '备注（此处不保存登录凭据）',
          initial: row?.body ?? '',
          multiline: true,
        ),
      ],
    );
    if (values == null || !mounted) return;
    await runUi(
      context,
      () => ref
          .read(homeDashboardProvider)
          .save(
            HomeDeviceInput(
              values['name']!,
              values['type']!,
              values['host']!,
              int.tryParse(values['port']!) ?? 0,
              values['protocol']!,
              managementUrl: values['url']!,
              tags: values['tags']!
                  .split(',')
                  .map((v) => v.trim())
                  .where((v) => v.isNotEmpty)
                  .toList(),
              notes: values['notes']!,
            ),
            existing: row,
          ),
    );
  }

  Future<void> check(
    ToolRecord row,
    String method,
  ) async => runUi(context, () async {
    if (!await ltConfirm(
      context,
      title: '检查此授权设备？',
      message:
          '${row.title}\n${row.text('host')}:${row.number('port')}\n方式：${method.toUpperCase()}。只检查此目标，不扫描网段或其他端口。HTTP只读取响应状态，不执行管理操作。',
    )) {
      return;
    }
    if (!mounted) return;
    final service = ref.read(homeDashboardProvider);
    await ref
        .read(utilityJobsProvider)
        .submit(
          'home_dashboard',
          'check',
          '检查${row.title}',
          {
            'deviceId': row.id,
            'method': method,
            'host': row.text('host'),
            'port': row.number('port'),
          },
          confirmed: true,
          run: (job, _) async => (await service.check(row, method, job)).id,
        );
  });
  @override
  Widget build(BuildContext context) => ref
      .watch(recordsProvider('home_device'))
      .when(
        loading: () => const LTLoadingState(),
        error: (_, _) => const LTErrorState(),
        data: (rows) {
          final items = rows
              .where(
                (r) =>
                    '${r.title} ${r.text('host')} ${r.body} ${r.strings('tags').join(' ')}'
                        .toLowerCase()
                        .contains(query) &&
                    (type == '全部' || r.text('type') == type),
              )
              .toList();
          return LTScrollPage(
            title: '家庭设备面板',
            description: '手动管理NAS、路由器、电脑、电视和服务器入口。按需检查授权的单一目标，默认不扫描、不轮询、不修改设备；电视管理能力取决于设备自身。',
            header: [
              LTToolbar(
                children: [
                  LTButton(label: '添加设备', onPressed: edit),
                  DropdownButton<String>(
                    value: type,
                    items: [
                      for (final t in ['全部', ...HomeDeviceInput.types])
                        DropdownMenuItem(value: t, child: Text(t)),
                    ],
                    onChanged: (v) => setState(() => type = v!),
                  ),
                ],
              ),
              LTTextField(
                label: '搜索设备、主机、标签或备注',
                onChanged: (v) => setState(() => query = v.toLowerCase()),
              ),
              const UtilityJobSummary(moduleId: 'home_dashboard'),
            ],
            itemCount: items.length,
            empty: const LTEmptyState(
              title: '添加已知的家庭设备',
              message: '填写自己的设备地址；没有默认的大范围发现或端口扫描。',
            ),
            itemBuilder: (context, i) {
              final row = items[i], last = row.data['lastCheck'] as Map?;
              return LTCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${row.title} · ${row.text('type')}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SelectableText(
                      '${row.text('protocol')}://${row.text('host')}:${row.number('port')}',
                    ),
                    if (last != null)
                      Text(
                        '上次${last['method']}：${last['message']} · ${last['elapsedMs']}ms\n${row.text('lastCheckedAt')}',
                      )
                    else
                      const Text('尚未检查，当前在线状态未知'),
                    if (row.body.isNotEmpty) Text(row.body),
                    Text(row.strings('tags').join(' / ')),
                    Wrap(
                      children: [
                        TextButton(
                          onPressed: () => edit(row),
                          child: const Text('编辑'),
                        ),
                        TextButton(
                          onPressed: () => check(row, 'tcp'),
                          child: const Text('TCP检查'),
                        ),
                        if ({'http', 'https'}.contains(row.text('protocol')))
                          TextButton(
                            onPressed: () => check(row, 'http'),
                            child: const Text('HTTP检查'),
                          ),
                        if (Platform.isWindows)
                          TextButton(
                            onPressed: () => check(row, 'ping'),
                            child: const Text('Ping检查'),
                          ),
                        if (row.text('managementUrl').isNotEmpty)
                          TextButton(
                            onPressed: () => runUi(
                              context,
                              () => openTarget(
                                context,
                                ref,
                                TargetAction('url', row.text('managementUrl')),
                              ),
                            ),
                            child: const Text('打开设备管理界面'),
                          ),
                        TextButton(
                          onPressed: () => runUi(context, () async {
                            if (!await ltConfirm(
                              context,
                              title: '删除设备与检查历史？',
                              message: row.title,
                            )) {
                              return;
                            }
                            await ref
                                .read(homeDashboardProvider)
                                .remove(row, confirmed: true);
                          }),
                          child: const Text('删除'),
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
