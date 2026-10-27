import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/storage/selected_input.dart';
import '../../core/ui/lt_components.dart';

Future<String?> pickDevText({int limit = 2 * 1024 * 1024}) async {
  final file = await FilePicker.pickFile(dialogTitle: '选择文本文件');
  return file == null ? null : utf8.decode(await readToolFile(file, limit));
}

Future<bool> saveDevText(String name, String text) async =>
    await FilePicker.saveFile(
      fileName: name,
      bytes: Uint8List.fromList(utf8.encode(text)),
      mimeType: 'text/plain',
    ) !=
    null;
Future<void> copyDevText(String text) =>
    Clipboard.setData(ClipboardData(text: text));

class DevTextEditor extends StatelessWidget {
  const DevTextEditor({
    super.key,
    required this.controller,
    required this.label,
    this.lines = 8,
  });
  final TextEditingController controller;
  final String label;
  final int lines;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: TextField(
      controller: controller,
      maxLines: lines,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      decoration: InputDecoration(labelText: label, alignLabelWithHint: true),
    ),
  );
}

/// Lazy, bounded branches avoid building a widget for every node of a large API
/// response. Users may still copy/export the complete bounded response.
class JsonTree extends StatefulWidget {
  const JsonTree({
    super.key,
    required this.value,
    this.label = 'root',
    this.depth = 0,
  });
  final Object? value;
  final String label;
  final int depth;
  @override
  State<JsonTree> createState() => _JsonTreeState();
}

class _JsonTreeState extends State<JsonTree> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    if (v is! Map && v is! List || widget.depth >= 16) {
      final text = jsonEncode(v);
      return ListTile(
        dense: true,
        title: Text(
          '${widget.label}: ${text.length > 300 ? '${text.substring(0, 300)}…' : text}',
        ),
      );
    }
    final entries = v is Map
        ? v.entries.map((e) => MapEntry(e.key.toString(), e.value)).toList()
        : (v as List)
              .asMap()
              .entries
              .map((e) => MapEntry(e.key.toString(), e.value))
              .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          dense: true,
          leading: Icon(expanded ? Icons.expand_less : Icons.expand_more),
          title: Text('${widget.label} · ${entries.length}项'),
          onTap: () => setState(() => expanded = !expanded),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Column(
              children: [
                for (final e in entries.take(200))
                  JsonTree(
                    value: e.value,
                    label: e.key,
                    depth: widget.depth + 1,
                  ),
                if (entries.length > 200) const Text('此分支仅显示前200项；完整数据可复制或导出。'),
              ],
            ),
          ),
      ],
    );
  }
}

class DevOutput extends StatelessWidget {
  const DevOutput({super.key, required this.text, this.limit = 100000});
  final String text;
  final int limit;
  @override
  Widget build(BuildContext context) => LTCard(
    child: SelectableText(
      text.length > limit
          ? '${text.substring(0, limit)}\n…仅预览前$limit字符，导出保留完整结果。'
          : text,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
    ),
  );
}
