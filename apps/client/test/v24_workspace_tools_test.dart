import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/features/dev_tools/controlled_worker.dart';
import 'package:links_toolbox/features/dev_tools/snippet_repository.dart';
import 'package:links_toolbox/features/dev_tools/network_inspector_service.dart';
import 'package:links_toolbox/features/dev_tools/log_service.dart';

void main() {
  test('snippets real SQLite search tags edit favorites import export rollback and restart', () async {
    final temp = await Directory.systemTemp.createTemp('v24-snippets-'),
        file = File('${temp.path}/db.sqlite');
    var db = AppDatabase.file(file);
    await db.initialize();
    var repo = SnippetRepository(RecordStore(db));
    final row = await repo.save(
      '脚本仅保存',
      r'Write-Output "$(not executed)"',
      language: 'PowerShell',
      category: '服务器',
      tags: ['部署'],
      favorite: true,
    );
    expect((await repo.search('部署')).single.id, row.id);
    expect(
      (await repo.search('PowerShell', favorites: true)).single.id,
      row.id,
    );
    final edited = await repo.save(
      '修改后的片段',
      'print("你好")',
      language: 'Python',
      existing: row,
      favorite: true,
    );
    final export = repo.exportJson([edited]);
    await db.close();
    db = AppDatabase.file(file);
    repo = SnippetRepository(RecordStore(db));
    expect((await repo.search('你好')).single.id, row.id);
    expect(await repo.importJson(export), 1);
    expect((await repo.search('你好')).length, 2);
    final invalid = jsonEncode({
      'format': 'kado-snippets',
      'version': 1,
      'items': [
        {'name': '合法', 'code': 'hello'},
        {'name': '', 'code': 'invalid'},
      ],
    });
    await expectLater(repo.importJson(invalid), throwsException);
    expect(await repo.search('合法'), isEmpty);
    expect(jsonDecode(await repo.exportAll()), isA<Map>());
    for (var i = 0; i < 12; i++) {
      await repo.save('bounded-$i', 'x' * 200000);
    }
    await expectLater(repo.exportAll(), throwsException);
    expect(jsonDecode(repo.exportJson([edited])), isA<Map>());
    await db.close();
    await temp.delete(recursive: true);
  });
  test('network real open closed DNS HTTP TLS untrusted certificate and handshake timeout', () async {
    final service = NetworkInspectorService(), sockets = <Socket>[];
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(sockets.add);
    final result = await service.check('127.0.0.1', server.port, 'tcp');
    expect(result['connected'], true);
    final dns = await service.check('localhost', server.port, 'dns');
    expect(dns['addresses'], isNotEmpty);
    await expectLater(
      service.check(
        '127.0.0.1',
        server.port,
        'https',
        timeout: const Duration(milliseconds: 150),
      ),
      throwsException,
    );
    final port = server.port;
    await server.close();
    for (final socket in sockets) {
      socket.destroy();
    }
    await expectLater(
      service.check('127.0.0.1', port, 'tcp'),
      throwsA(isA<SocketException>()),
    );
    await expectLater(
      service.check(
        'kado-owned-test.invalid',
        443,
        'dns',
        timeout: const Duration(seconds: 2),
      ),
      throwsException,
    );
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((r) {
      r.response.statusCode = 503;
      r.response.close();
    });
    expect(
      (await service.check('127.0.0.1', http.port, 'http'))['status'],
      503,
    );
    await http.close(force: true);
    final context = SecurityContext()
      ..useCertificateChain('../../artifacts/qa/v24-tls/cert.pem')
      ..usePrivateKey('../../artifacts/qa/v24-tls/key.pem');
    final tls = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    tls.listen((s) => s.destroy(), onError: (Object _) {});
    final certificate =
        (await service.check('127.0.0.1', tls.port, 'https'))['certificate']
            as Map;
    expect(certificate['subject'], contains('localhost'));
    expect(certificate['trusted'], false);
    expect(certificate['sha256'], hasLength(64));
    await tls.close();
    expect(await service.interfaces(), isNotEmpty);
  });
  test(
    'large real log bounded pages byte cursors JSONL time filters export and redaction',
    () async {
      const path = '../../artifacts/qa/v24-logs/large.log';
      final stat = await File(path).stat();
      expect(stat.size, greaterThan(150 * 1024 * 1024));
      Future<Map> scan(Map<String, dynamic> filters) async =>
          await ControlledWorker(scanLog, {
                'path': path,
                ...filters,
              }, timeout: const Duration(seconds: 30)).result
              as Map;
      final first = await scan({'level': 'ERROR'});
      expect((first['items'] as List).length, 200);
      expect(first['more'], true);
      final next = await scan({
        'level': 'ERROR',
        'offset': first['nextOffset'],
        'line': first['line'],
        'size': first['size'],
        'modified': first['modified'],
      });
      expect(
        (next['items'] as List).first['line'],
        greaterThan((first['items'] as List).last['line'] as int),
      );
      final last = await scan({'query': 'row=1799999'});
      expect((last['items'] as List).single['line'], 1800000);
      final temp = await Directory.systemTemp.createTemp('v24-log-export-'),
          output = File('${temp.path}/result.log');
      await output.create(exclusive: true);
      final exported = await scan({'level': 'ERROR', 'output': output.path});
      expect(exported['matched'], 1800);
      expect((await output.readAsLines()).length, 1800);
      final tiny = File('${temp.path}/structured.jsonl');
      await tiny.writeAsString(
        '${jsonEncode({'time': '2026-10-26T12:00:00Z', 'level': 'WARN', 'token': 'SECRET', 'message': 'needle'})}\n2026-10-25T12:00:00Z INFO before\n${'x' * 100000}\n',
      );
      final parsed =
          await ControlledWorker(scanLog, {
                'path': tiny.path,
                'from': '2026-10-26T00:00:00Z',
              }).result
              as Map;
      expect((parsed['items'] as List).length, 1);
      final long =
          await ControlledWorker(scanLog, {'path': tiny.path}).result as Map;
      expect((long['items'] as List).last['truncated'], true);
      expect(((long['items'] as List).last['text'] as String).length, 16384);
      final redacted = redactLog(
        'Authorization: Bearer SECRET\nCookie: session=SECRET\n{"token":"SECRET"}\npassword=SECRET&ok=yes',
      );
      expect(redacted, isNot(contains('SECRET')));
      expect(redacted, contains('[REDACTED]'));
      await temp.delete(recursive: true);
    },
    // This compound test performs several independent scans/exports of a
    // 241 MB fixture. Keep every worker's 30-second bound; allow their aggregate
    // filesystem work a separate budget on slower development machines.
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
