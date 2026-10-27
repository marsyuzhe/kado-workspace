import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/data/tool_record.dart';
import '../core/platform/system_actions.dart';
import 'record_ui.dart';

class LocalMarkdown extends StatelessWidget {
  const LocalMarkdown({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => MarkdownBody(
    data: text,
    selectable: true,
    imageBuilder: (uri, title, alt) =>
        Text('[图片：${alt ?? title ?? uri.path}，外部图片未加载]'),
    onTapLink: (label, href, title) {
      if (href == null) return;
      runUi(context, () async {
        TargetAction('url', href).validate();
        if (!await launchUrl(
          Uri.parse(href),
          mode: LaunchMode.externalApplication,
        )) {
          throw const ToolFailure('系统没有成功打开链接。');
        }
      });
    },
  );
}
