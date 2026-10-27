import '../../core/platform/system_actions.dart';

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/ui/lt_components.dart';
import '../../shared/page_frame.dart';
import '../../shared/record_ui.dart';
import 'dev_tool_widgets.dart';
import 'hash_service.dart';

class HashInspectorPage extends ConsumerStatefulWidget {
  const HashInspectorPage({super.key});
  @override
  ConsumerState<HashInspectorPage> createState() => _HashInspectorPageState();
}

class _HashInspectorPageState extends ConsumerState<HashInspectorPage> {
  final expected = TextEditingController();
  final results = <FileHashes>[];
  DevCancellation? task;
  int done = 0, total = 0;
  String current = '';
  StreamSubscription<List<String>>? drops;
  NativePlatformAdapter? dropAdapter;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final native = ref.read(nativePlatformProvider);
      dropAdapter = native;
      drops = native.fileDrops.listen((paths) {
        if (mounted && task == null) {
          unawaited(runUi(context, () => process(paths)));
        }
      });
      unawaited(runUi(context, () => native.listenFileDrops(true)));
    });
  }

  @override
  void dispose() {
    unawaited(drops?.cancel());
    unawaited(dropAdapter?.listenFileDrops(false));
    task?.cancel();
    expected.dispose();
    super.dispose();
  }

  Future<void> select() async {
    final files = await FilePicker.pickFiles(dialogTitle: '选择校验文件（最多100个）');
    if (files.isEmpty) return;
    if (files.length > 100) throw const FormatException('每批最多100个文件。');
    final paths = <String>[];
    for (final f in files) {
      if (f.path == null) throw const FormatException('当前平台未提供文件路径。');
      paths.add(f.path!);
    }
    await process(paths);
  }

  Future<void> process(List<String> paths) async {
    if (paths.isEmpty) return;
    if (paths.length > 100) throw const FormatException('每批最多100个文件。');
    final cancel = DevCancellation();
    setState(() {
      task = cancel;
      results.clear();
    });
    try {
      for (final path in paths) {
        cancel.check();
        if (mounted) setState(() => current = p.basename(path));
        final result = await hashFile(
          File(path),
          cancel,
          progress: (d, t) {
            if (mounted) {
              setState(() {
                done = d;
                total = t;
              });
            }
          },
        );
        if (mounted) setState(() => results.add(result));
      }
    } finally {
      if (mounted) setState(() => task = null);
    }
  }

  String manifest(bool sha512) => results
      .map(
        (r) =>
            '${sha512 ? r.sha512 : r.sha256}  ${p.basename(r.path).replaceAll('\n', '_').replaceAll('\r', '_')}',
      )
      .join('\n');
  @override
  Widget build(BuildContext context) => PageFrame(
    eyebrow: 'DEVELOPER TOOLS',
    title: 'Hash Inspector',
    description: '选择文件或从Windows拖入文件，分块计算SHA-256 / SHA-512。仅在本页接受文件拖入，最多100个。',
    children: [
      LTToolbar(
        children: [
          LTButton(
            label: '选择文件 / 批量校验',
            icon: Icons.file_open_outlined,
            onPressed: task != null ? null : () => runUi(context, select),
          ),
          if (task != null)
            TextButton(onPressed: task!.cancel, child: const Text('取消')),
          for (final sha512 in [false, true])
            TextButton(
              onPressed: results.isEmpty
                  ? null
                  : () => runUi(
                      context,
                      () => saveDevText(
                        sha512 ? 'SHA512SUMS.txt' : 'SHA256SUMS.txt',
                        manifest(sha512),
                      ),
                    ),
              child: Text(sha512 ? '导出SHA512清单' : '导出SHA256清单'),
            ),
        ],
      ),
      DevTextEditor(
        controller: expected,
        label: '预期哈希（仅比较当前输入，空白不比较）',
        lines: 2,
      ),
      TextButton(onPressed: () => setState(() {}), child: const Text('比较')),
      if (task != null) ...[
        Text('$current · $done / $total bytes'),
        LinearProgressIndicator(value: total > 0 ? done / total : null),
      ],
      for (final r in results)
        LTCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${p.basename(r.path)} · ${r.size} bytes'),
              SelectableText('SHA256  ${r.sha256}\nSHA512  ${r.sha512}'),
              if (expected.text.trim().isNotEmpty)
                Text(r.matches(expected.text) ? '一致' : '不一致'),
              Wrap(
                children: [
                  TextButton(
                    onPressed: () => copyDevText(r.sha256),
                    child: const Text('复制SHA256'),
                  ),
                  TextButton(
                    onPressed: () => copyDevText(r.sha512),
                    child: const Text('复制SHA512'),
                  ),
                ],
              ),
            ],
          ),
        ),
    ],
  );
}
