import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/features/utilities/document_converter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppDatabase db;
  late RecordStore store;
  late OwnedFileStore owned;
  late UtilityJobEngine jobs;
  late DocumentConverterService service;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-document-test-');
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    owned = OwnedFileStore(temp);
    jobs = UtilityJobEngine(JobQueueRepository(store));
    service = DocumentConverterService(
      store,
      () async => owned,
      () => File('assets/fonts/NotoSansSC.ttf').readAsBytes(),
    );
  });
  tearDown(() async {
    await jobs.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));
  test(
    'Markdown HTML removes executable, remote and local embedded content',
    () async {
      final result = utf8.decode(
        await documentBytes(
          bytes(
            '# 中文文档\n\n段落 **加粗**\n\n<script>alert(1)</script>\n\n![远端图](https://example.invalid/x.png)\n\n[恶意](javascript:alert(1))\n\n[资料](https://example.invalid)',
          ),
          'md',
          'html',
          Uint8List(0),
        ),
      );
      expect(result, contains('<h1>中文文档</h1>'));
      expect(result, contains('<strong>加粗</strong>'));
      for (final bad in [
        '<script',
        'javascript:',
        '<img',
        'onerror',
        '<iframe',
      ]) {
        expect(result, isNot(contains(bad)));
      }
      expect(result, contains('Content-Security-Policy'));
      expect(result, contains('href="https://example.invalid"'));
    },
  );
  test('real Chinese TXT and Markdown PDFs persist with valid header and reopen records', () async {
    for (final format in ['txt', 'md']) {
      final source = format == 'txt'
          ? 'Links Toolbox 中文转换测试\n作者：Links Tam\n\n${List.generate(90, (i) => '第${i + 1}行：离线文档转换保留中文内容，验证分页、字体和段落。').join('\n')}'
          : '# 中文 Markdown 文档\n\n## 基础格式\n\n这是离线转换的实际输出。\n\n- 任务队列\n- 本地附件\n\n```dart\nprint("Hello Links");\n```\n\n| 名称 | 状态 |\n| --- | --- |\n| 中文PDF | 已生成 |';
      final job = await jobs.submit(
        'converter',
        'document',
        '中文文档',
        {},
        confirmed: true,
        run: (ctx, _) async => (await service.convert(
          'sample.$format',
          bytes(source),
          format,
          'pdf',
          ctx,
        )).id,
      );
      await jobs.waitIdle();
      final done = await jobs.repository.require(job.id);
      expect(
        utilityJobStatus(done),
        UtilityJobStatus.succeeded,
        reason: done.text('errorMessage'),
      );
      final output = (await store.get(done.text('resultReference')))!;
      final pdf = await owned.resolve(output.text('attachment')).readAsBytes();
      expect(ascii.decode(pdf.sublist(0, 5)), '%PDF-');
      expect(pdf.length, greaterThan(1000));
      final artifacts = Platform.environment['LINKS_UTILITIES_ARTIFACT_ROOT'];
      if (artifacts != null) {
        final dir = await Directory(artifacts).create(recursive: true);
        await File('${dir.path}/sample-$format.pdf').writeAsBytes(pdf);
      }
    }
    await db.close();
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    expect((await store.list('utility_output')).length, 2);
  });
  test('empty corrupt unsupported encoding and oversized document fail without output', () async {
    for (final input in [
      Uint8List(0),
      Uint8List.fromList([0xff, 0xff]),
      bytes('a\u0000b'),
      bytes(' '),
    ]) {
      expect(() => readDocument(input), throwsA(isA<ToolFailure>()));
    }
    await expectLater(
      documentBytes(bytes('text'), 'docx', 'pdf', Uint8List(0)),
      throwsA(isA<ToolFailure>()),
    );
    expect(() => readDocument(bytes('a' * 80001)), throwsA(isA<ToolFailure>()));
    final job = await jobs.submit(
      'converter',
      'document',
      '损坏输入',
      {},
      confirmed: true,
      run: (ctx, _) async => (await service.convert(
        'bad.txt',
        Uint8List.fromList([0xff]),
        'txt',
        'pdf',
        ctx,
      )).id,
    );
    await jobs.waitIdle();
    expect(
      utilityJobStatus(await jobs.repository.require(job.id)),
      UtilityJobStatus.failed,
    );
    expect(await store.list('utility_output'), isEmpty);
  });
}
