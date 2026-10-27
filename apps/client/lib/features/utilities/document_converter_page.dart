import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/record_ui.dart';
import 'document_converter.dart';
import 'utilities_page.dart';
import 'utility_providers.dart';
import 'job_widgets.dart';

class DocumentConverterPage extends ConsumerStatefulWidget {
  const DocumentConverterPage({super.key});
  @override
  ConsumerState<DocumentConverterPage> createState() =>
      _DocumentConverterPageState();
}

class _DocumentConverterPageState extends ConsumerState<DocumentConverterPage> {
  String name = '', sourceFormat = 'txt', format = 'pdf', source = '';
  Uint8List? bytes;
  bool busy = false;
  Future<void> pick() async => runUi(context, () async {
    final chosen = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['txt', 'md', 'markdown'],
    );
    if (chosen == null) return;
    final data = await readToolFile(chosen, 2 * 1024 * 1024);
    final text = readDocument(data);
    if (mounted) {
      setState(() {
        bytes = data;
        name = chosen.name;
        sourceFormat = p.extension(name).substring(1).toLowerCase();
        source = text;
        if (sourceFormat == 'txt') format = 'pdf';
      });
    }
  });
  Future<void> convert() async => runUi(context, () async {
    final data = bytes,
        title = name,
        inputFormat = sourceFormat,
        target = format;
    if (data == null) return;
    if (!await ltConfirm(
      context,
      title: '转换为${target.toUpperCase()}？',
      message:
          '$title\n原文${data.length} bytes。输出作为应用附件保存，可另存。支持基础标题、列表、段落、代码和表格文字；远端图片、脚本和自定义HTML不会加载。',
    )) {
      return;
    }
    if (!mounted) return;
    final service = ref.read(documentConverterProvider);
    await ref
        .read(utilityJobsProvider)
        .submit(
          'converter',
          'document_conversion',
          '文档转换$title',
          {'name': title, 'format': target},
          confirmed: true,
          retainedBytes: data.length,
          run: (job, _) async =>
              (await service.convert(title, data, inputFormat, target, job)).id,
        );
    if (mounted) {
      setState(() {
        bytes = null;
        source = '';
        name = '';
      });
    }
  });
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const Text('文本文档转换', style: TextStyle(fontSize: 24)),
      const Text(
        'UTF-8 TXT → PDF；Markdown → HTML/PDF。离线中文字体，最多2MB/80000字符。基础排版，未实现Word/Excel/PDF反向转换。',
      ),
      LTToolbar(
        children: [
          LTButton(label: '选择 TXT/Markdown', onPressed: busy ? null : pick),
          DropdownButton<String>(
            value: format,
            items: [
              const DropdownMenuItem(value: 'pdf', child: Text('PDF')),
              if (sourceFormat != 'txt')
                const DropdownMenuItem(value: 'html', child: Text('HTML')),
            ],
            onChanged: (v) => setState(() => format = v!),
          ),
          LTButton(
            label: '预览并转换文档',
            onPressed: bytes == null || busy ? null : convert,
          ),
        ],
      ),
      if (name.isNotEmpty) Text('$name · ${bytes!.length} bytes'),
      if (source.isNotEmpty)
        SizedBox(
          height: 240,
          child: SingleChildScrollView(child: SelectableText(source)),
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
                        .where((r) => r.text('source') == 'documentConverter')
                        .take(20))
                  LTCard(
                    child: ListTile(
                      title: Text(
                        '${row.title} → ${row.text('format').toUpperCase()}',
                      ),
                      subtitle: Text(
                        '${row.number('size')} bytes · ${readableTime(row.createdAt)}',
                      ),
                      trailing: TextButton(
                        child: const Text('另存输出'),
                        onPressed: () => runUi(context, () async {
                          final file = (await ref.read(
                            ownedFilesProvider.future,
                          )).resolve(row.text('attachment'));
                          if (!await file.exists()) {
                            throw const ToolFailure('输出附件已缺失。');
                          }
                          await FilePicker.saveFile(
                            fileName:
                                '${p.basenameWithoutExtension(row.title)}-${row.id.substring(0, 8)}.${row.text('format')}',
                            bytes: await file.readAsBytes(),
                            mimeType: row.text('format') == 'pdf'
                                ? 'application/pdf'
                                : 'text/html',
                          );
                        }),
                      ),
                    ),
                  ),
              ],
            ),
          ),
    ],
  );
}
