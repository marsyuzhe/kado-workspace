import '../../app/brand_config.dart';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:markdown/markdown.dart' as md;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:crypto/crypto.dart';

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/storage/owned_file_store.dart';

String readDocument(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) {
    throw const ToolFailure('文本文档不能为空，最多2MB。');
  }
  try {
    final source = utf8.decode(bytes).replaceFirst('\ufeff', '');
    if (source.trim().isEmpty ||
        source.runes.any((c) => c < 32 && !{9, 10, 13}.contains(c))) {
      throw const FormatException();
    }
    if (source.length > 80000) {
      throw const ToolFailure('首版文档转换最多80000字符，请拆分长文。');
    }
    return source;
  } on ToolFailure {
    rethrow;
  } catch (_) {
    throw const ToolFailure('仅支持有效UTF-8文本，不支持二进制或其他编码。');
  }
}

String safeMarkdownHtml(String source) {
  final fragment = html.parseFragment(
    md.markdownToHtml(source, extensionSet: md.ExtensionSet.gitHubWeb),
  );
  const allowed = {
    'p',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'pre',
    'code',
    'em',
    'strong',
    'a',
    'ul',
    'ol',
    'li',
    'blockquote',
    'hr',
    'br',
    'table',
    'thead',
    'tbody',
    'tr',
    'th',
    'td',
    'del',
  };
  dom.Node? clean(dom.Node node) {
    if (node is dom.Text) return dom.Text(node.data);
    if (node is! dom.Element || !allowed.contains(node.localName)) return null;
    final result = dom.Element.tag(node.localName!);
    if (node.localName == 'a') {
      final uri = Uri.tryParse(node.attributes['href'] ?? '');
      if (uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty) {
        result.attributes['href'] = uri.toString();
      }
      result.attributes['rel'] = 'noreferrer noopener';
    }
    for (final child in node.nodes) {
      final safe = clean(child);
      if (safe != null) result.append(safe);
    }
    return result;
  }

  final result = dom.DocumentFragment();
  for (final node in fragment.nodes) {
    final safe = clean(node);
    if (safe != null) result.append(safe);
  }
  return result.outerHtml;
}

Future<Uint8List> documentBytes(
  Uint8List bytes,
  String sourceFormat,
  String outputFormat,
  Uint8List fontBytes,
) => Isolate.run(() async {
  final source = readDocument(bytes);
  if (!{'txt', 'md', 'markdown'}.contains(sourceFormat) ||
      !{'pdf', 'html'}.contains(outputFormat) ||
      sourceFormat == 'txt' && outputFormat == 'html') {
    throw const ToolFailure('已支持UTF-8 TXT→PDF、Markdown→HTML/PDF。');
  }
  final markdown = sourceFormat != 'txt';
  final safe = markdown ? safeMarkdownHtml(source) : '';
  if (outputFormat == 'html') {
    return Uint8List.fromList(
      utf8.encode(
        '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'"><title>Links Document</title><style>body{max-width:800px;margin:48px auto;padding:0 24px;font:16px/1.7 sans-serif;color:#222}pre{white-space:pre-wrap;background:#f3f3f3;padding:16px}table{border-collapse:collapse}td,th{border:1px solid #ddd;padding:8px}a{color:#1565c0}</style></head><body>$safe</body></html>',
      ),
    );
  }
  final font = pw.Font.ttf(ByteData.sublistView(fontBytes));
  final document = pw.Document(
    title: 'Links Document',
    creator: AppBrandConfig.displayName,
    compress: true,
  );
  final widgets = <pw.Widget>[];
  void text(String value, {double size = 11, bool heading = false}) {
    // Bounded blocks remain splittable across pages, including long plain lines.
    final lines = value.split('\n');
    for (final line in lines) {
      if (line.isEmpty) {
        widgets.add(pw.SizedBox(height: 6));
        continue;
      }
      for (var i = 0; i < line.length; i += 300) {
        widgets.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 5),
            child: pw.Text(
              line.substring(i, (i + 300).clamp(0, line.length)),
              style: pw.TextStyle(font: font, fontSize: size, lineSpacing: 3),
            ),
          ),
        );
      }
    }
  }

  if (!markdown) {
    text(source);
  } else {
    final doc = html.parseFragment(safe);
    void block(dom.Node node) {
      if (node is dom.Text) {
        if (node.text.trim().isNotEmpty) text(node.text);
        return;
      }
      if (node is! dom.Element) return;
      final tag = node.localName ?? '';
      if (RegExp(r'^h[1-6]$').hasMatch(tag)) {
        text(
          node.text,
          size: 22 - int.parse(tag.substring(1)) * 2.0,
          heading: true,
        );
      } else if (tag == 'li') {
        text('• ${node.text}');
      } else if ({'ul', 'ol', 'table', 'thead', 'tbody'}.contains(tag)) {
        for (final child in node.nodes) {
          block(child);
        }
      } else if (tag == 'tr') {
        text(node.children.map((c) => c.text).join('  |  '), size: 10);
      } else if (tag == 'hr') {
        widgets.add(pw.Divider());
      } else {
        text(node.text, size: tag == 'pre' ? 9 : 11);
      }
    }

    for (final node in doc.nodes) {
      block(node);
    }
  }
  if (widgets.isEmpty) {
    throw const ToolFailure('文档没有可输出的文字。远端图片、脚本、嵌入网页与自定义HTML已移除。');
  }
  document.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(42),
      maxPages: 100,
      theme: pw.ThemeData.withFont(
        base: font,
        bold: font,
        italic: font,
        boldItalic: font,
      ),
      footer: (context) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          '${context.pageNumber} / ${context.pagesCount}',
          style: pw.TextStyle(font: font, fontSize: 9),
        ),
      ),
      build: (_) => widgets,
    ),
  );
  return document.save();
});

class DocumentConverterService {
  DocumentConverterService(this.store, this.files, this.font);
  final RecordStore store;
  final Future<OwnedFileStore> Function() files;
  final Future<Uint8List> Function() font;
  Future<ToolRecord> convert(
    String name,
    Uint8List bytes,
    String sourceFormat,
    String outputFormat,
    UtilityJobContext job,
  ) async {
    job.check();
    await job.progress(0, 1, currentFile: name, force: true);
    final output = await documentBytes(
      bytes,
      sourceFormat,
      outputFormat,
      outputFormat == 'pdf' ? await font() : Uint8List(0),
    );
    job.check();
    final owned = await files(),
        ref = await (await files()).write(
          'utilities',
          output,
          extension: outputFormat,
        );
    late ToolRecord row;
    try {
      row = await store.create(
        'utility_output',
        name,
        data: {
          'payloadVersion': 1,
          'source': 'documentConverter',
          'jobId': job.id,
          'attachment': ref,
          'format': outputFormat,
          'size': output.length,
          'checksum': sha256.convert(output).toString(),
          'syncAllowed': false,
          'isSensitive': true,
        },
      );
    } catch (_) {
      await owned.remove(ref);
      rethrow;
    }
    await job.output(row.id);
    await job.progress(1, 1, currentFile: name, force: true);
    return row;
  }
}
