import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/platform/system_actions.dart';
import '../../core/ui/lt_components.dart';
import '../../core/ui/lt_scroll_page.dart';
import '../../shared/record_ui.dart';
import '../hub/hub_actions.dart';
import 'software_library.dart';
import 'utility_providers.dart';
import 'job_widgets.dart';

class SoftwareLibraryPage extends ConsumerStatefulWidget {
  const SoftwareLibraryPage({super.key});
  @override
  ConsumerState<SoftwareLibraryPage> createState() =>
      _SoftwareLibraryPageState();
}

class _SoftwareLibraryPageState extends ConsumerState<SoftwareLibraryPage> {
  String query = '', category = '';
  bool favorites = false;
  Future<void> add() async => runUi(context, () async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: SoftwareLibraryService.extensions.toList(),
    );
    final paths = files.map((f) => f.path).whereType<String>().toList();
    if (paths.isEmpty) return;
    if (!mounted ||
        !await ltConfirm(
          context,
          title: '登记${paths.length}个安装包？',
          message:
              '仅流式读取SHA256和文件属性，不移动、不执行安装程序。版本与发布者优先读取Windows资源，缺失时留空，可手动编辑。',
        )) {
      return;
    }
    if (!mounted) return;
    final service = ref.read(softwareLibraryProvider);
    await ref
        .read(utilityJobsProvider)
        .submit(
          'software_library',
          'import',
          '登记安装包',
          {'paths': paths},
          confirmed: true,
          run: (job, _) async {
            final rows = await service.importPaths(paths, job);
            return rows.isEmpty ? null : rows.first.id;
          },
        );
  });
  Future<void> edit(ToolRecord row) async {
    final values = await ltEditForm(
      context,
      title: '软件安装包信息',
      fields: [
        LTField('name', '软件名称（同名展示版本记录）', initial: row.title, required: true),
        LTField('version', '版本（可手动填写）', initial: row.text('version')),
        LTField('publisher', '发布者（资源信息或手动填写）', initial: row.text('publisher')),
        LTField('category', '分类', initial: row.text('category')),
        LTField('url', '官方下载地址（可空）', initial: row.text('officialUrl')),
        LTField(
          'favorite',
          '喜爱',
          initial: row.flag('favorite') ? 'true' : 'false',
          options: const {'true': '是', 'false': '否'},
        ),
        LTField('notes', '备注', initial: row.body, multiline: true),
      ],
    );
    if (values == null || !mounted) return;
    await runUi(
      context,
      () => ref
          .read(softwareLibraryProvider)
          .edit(
            row,
            name: values['name']!,
            version: values['version']!,
            publisher: values['publisher']!,
            category: values['category']!,
            officialUrl: values['url']!,
            notes: values['notes']!,
            favorite: values['favorite'] == 'true',
          ),
    );
  }

  Future<void> verify(
    ToolRecord row, {
    bool launch = false,
  }) async => runUi(context, () async {
    if (launch &&
        !await ltConfirm(
          context,
          title: '核验后打开此安装包？',
          message:
              '${row.text('installerPath')}\n登记SHA256：${row.text('sha256')}\n将重新核对文件。数字签名或哈希匹配不代表绝对安全；不会静默安装或主动请求管理员权限。',
        )) {
      return;
    }
    if (!mounted) return;
    final service = ref.read(softwareLibraryProvider),
        engine = ref.read(utilityJobsProvider);
    final job = await engine.submit(
      'software_library',
      'verify',
      '校验 ${row.title}',
      {'recordId': row.id},
      confirmed: true,
      run: (ctx, _) async => (await service.verify(row.id, ctx)).id,
    );
    if (launch) {
      final done = await engine.waitFor(job.id);
      if (!mounted || utilityJobStatus(done) != UtilityJobStatus.succeeded) {
        return;
      }
      final updated = await ref.read(recordStoreProvider).get(row.id);
      if (updated == null || !updated.flag('checksumMatches')) return;
      await ref
          .read(nativePlatformProvider)
          .launch(
            TargetAction('file', updated.text('installerPath')),
            confirmed: true,
          );
    }
  });
  @override
  Widget build(BuildContext context) => ref
      .watch(recordsProvider('software_package'))
      .when(
        loading: () => const LTLoadingState(),
        error: (_, _) => const LTErrorState(),
        data: (rows) {
          final items = rows
              .where(
                (r) =>
                    '${r.title} ${r.body} ${r.text('version')} ${r.text('publisher')}'
                        .toLowerCase()
                        .contains(query) &&
                    (!favorites || r.flag('favorite')) &&
                    (category.isEmpty || r.text('category') == category),
              )
              .toList();
          return LTScrollPage(
            title: '软件安装包管家',
            description: '本地登记与版本记录。SHA256用于核对内容，Windows签名状态是离线检查；不保证软件安全。原安装包不随应用备份携带，位置变化后请重新登记。',
            header: [
              LTToolbar(
                children: [
                  LTButton(
                    label: '添加安装包',
                    onPressed: Platform.isWindows ? add : null,
                  ),
                  FilterChip(
                    label: const Text('仅喜爱'),
                    selected: favorites,
                    onSelected: (v) => setState(() => favorites = v),
                  ),
                ],
              ),
              LTTextField(
                label: '搜索名称、版本、发布者或备注',
                onChanged: (v) => setState(() => query = v.toLowerCase()),
              ),
              LTTextField(
                label: '分类（空=全部）',
                onChanged: (v) => setState(() => category = v.trim()),
              ),
              const UtilityJobHistory(moduleId: 'software_library'),
              Text('当前${items.length} / ${rows.length}个安装包'),
            ],
            itemCount: items.length,
            empty: const LTEmptyState(
              title: '保留能找回的安装包信息',
              message: '导入你选择的本地EXE、MSI、ZIP等文件，实际计算校验值。',
            ),
            itemBuilder: (context, i) {
              final row = items[i],
                  versions = rows
                      .where(
                        (r) => r.title.toLowerCase() == row.title.toLowerCase(),
                      )
                      .toList();
              return LTCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${row.title}${row.flag('favorite') ? ' ★' : ''}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '版本：${row.text('version').isEmpty ? '未识别' : row.text('version')} · ${row.text('installerType').toUpperCase()} · ${readableBytes(row.number('fileSize'))}',
                    ),
                    Text(
                      '发布者资料：${row.text('publisher').isEmpty ? '未识别' : row.text('publisher')}',
                    ),
                    SelectableText(row.text('installerPath')),
                    SelectableText('SHA256 ${row.text('sha256')}'),
                    Text(
                      '签名：${const {'valid_offline': '本机离线校验通过（未在线查吊销）', 'unsigned': '未签名', 'invalid_digest': '签名摘要不一致', 'not_supported': '此包类型未检查签名', 'not_available': '当前环境无原生签名通道', 'unverified': '未通过或无法完成离线检查'}[row.text('signatureStatus')] ?? '未知'}',
                    ),
                    Text(
                      '上次核对：${row.flag('lastExists') ? '存在' : '缺失'} · ${row.flag('checksumMatches') ? '登记哈希匹配' : '未匹配'} · ${row.text('lastVerifiedAt')}',
                    ),
                    if (row.text('verificationError').isNotEmpty)
                      Text(row.text('verificationError')),
                    if (row.body.isNotEmpty) Text(row.body),
                    if (versions.length > 1)
                      Text(
                        '同名版本记录：${versions.map((r) => r.text('version').isEmpty ? '未识别版本' : r.text('version')).join(' / ')}',
                      ),
                    Wrap(
                      children: [
                        TextButton(
                          onPressed: () => edit(row),
                          child: const Text('编辑信息'),
                        ),
                        TextButton(
                          onPressed: () => verify(row),
                          child: const Text('重新核验SHA256'),
                        ),
                        if (Platform.isWindows) ...[
                          TextButton(
                            onPressed: () => runUi(
                              context,
                              () => openTarget(
                                context,
                                ref,
                                TargetAction(
                                  'folder',
                                  p.dirname(row.text('installerPath')),
                                ),
                              ),
                            ),
                            child: const Text('打开文件位置'),
                          ),
                          TextButton(
                            onPressed: () => runUi(
                              context,
                              () => ref
                                  .read(nativePlatformProvider)
                                  .showFileProperties(
                                    row.text('installerPath'),
                                  ),
                            ),
                            child: const Text('查看属性'),
                          ),
                          TextButton(
                            onPressed: () => verify(row, launch: true),
                            child: const Text('核验后打开安装包'),
                          ),
                        ],
                        if (row.text('officialUrl').isNotEmpty)
                          TextButton(
                            onPressed: () => runUi(
                              context,
                              () => openTarget(
                                context,
                                ref,
                                TargetAction('url', row.text('officialUrl')),
                              ),
                            ),
                            child: const Text('官方下载地址'),
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
