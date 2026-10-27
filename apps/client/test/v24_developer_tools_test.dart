import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/security/credential_store.dart';
import 'package:links_toolbox/features/dev_tools/api_studio_service.dart';
import 'package:links_toolbox/features/dev_tools/controlled_worker.dart';
import 'package:links_toolbox/features/dev_tools/data_formatter_service.dart';
import 'package:links_toolbox/features/dev_tools/regex_service.dart';
import 'package:links_toolbox/features/dev_tools/hash_service.dart';

class _Credentials implements CredentialStore {
  final values = <String, String>{};
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  test(
    'object additions respect the diff resource limit just like arrays',
    () async {
      final after = {for (var i = 0; i < 1500; i++) 'key-$i': i};
      final result =
          await ControlledWorker(formatData, {
                'mode': 'diff',
                'text': '{}',
                'other': jsonEncode(after),
              }).result
              as Map;
      expect((result['value'] as List).length, 1000);
      expect(result['note'], contains('1000'));
    },
  );
  test('API real localhost GET POST PUT PATCH DELETE HEAD errors headers cancellation timeout and save', () async {
    final temp = await Directory.systemTemp.createTemp('v24-api-'),
        db = AppDatabase.file(File('${temp.path}/db.sqlite'));
    await db.initialize();
    final store = RecordStore(db),
        keys = _Credentials(),
        service = ApiStudioService(store, keys);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String>[];
    server.listen((request) async {
      requests.add(request.method);
      if (request.uri.path == '/slow') {
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      try {
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('x-kado', 'real-loopback');
        if (request.uri.path == '/error') request.response.statusCode = 422;
        final body = await utf8.decoder.bind(request).join();
        request.response.write(
          jsonEncode({
            'method': request.method,
            'query': request.uri.queryParameters,
            'header': request.headers.value('x-test'),
            'body': body,
          }),
        );
        await request.response.close();
      } on HttpException {
        /* Cancellation can disconnect the owned fixture. */
      }
    });
    addTearDown(() async {
      await server.close(force: true);
      await db.close();
      await temp.delete(recursive: true);
    });
    final base = 'http://127.0.0.1:${server.port}';
    for (final method in apiMethods) {
      final result = await service.send(
        ApiRequestSpec(
          url: '$base/echo',
          method: method,
          headers: {'x-test': 'safe-header'},
          query: {'q': 'hello world'},
          body: method == 'HEAD' || method == 'GET' ? '' : '{"text":"你好"}',
          bodyType: 'json',
        ),
      );
      expect(result.status, 200);
      expect(result.headers['x-kado'], ['real-loopback']);
      if (method != 'HEAD') {
        final parsed = jsonDecode(result.body) as Map;
        expect(parsed['method'], method);
        expect((parsed['query'] as Map)['q'], 'hello world');
        expect(result.size, utf8.encode(result.body).length);
        expect(result.size, greaterThan(0));
      }
    }
    expect(
      (await service.send(ApiRequestSpec(url: '$base/error'))).status,
      422,
    );
    final cancel = CancelToken();
    final pending = service.send(
      ApiRequestSpec(url: '$base/slow'),
      cancelToken: cancel,
    );
    final cancelled = expectLater(pending, throwsA(isA<ToolFailure>()));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    cancel.cancel();
    await cancelled;
    await expectLater(
      service.send(ApiRequestSpec(url: '$base/slow', timeoutSeconds: 1)),
      throwsA(isA<ToolFailure>()),
    );
    final row = await service.save(
      'Protected request',
      ApiRequestSpec(
        url: '$base/echo?api_key=URLSECRET&escaped=%3A',
        headers: {'Authorization': 'Bearer HEADERSECRET'},
        body: '{"password":"BODYSECRET"}',
        bodyType: 'json',
      ),
    );
    final persisted = jsonEncode((await store.get(row.id))!.data);
    for (final secret in ['URLSECRET', 'HEADERSECRET', 'BODYSECRET']) {
      expect(persisted, isNot(contains(secret)));
    }
    expect(keys.values.length, 3);
    final exported = jsonEncode(ApiRequestSpec.fromJson(row.data).toJson());
    expect(exported, isNot(contains('HEADERSECRET')));
    final resolved = await service.resolve('{{TOKEN}}', {
      'TOKEN': '{{secret:${keys.values.keys.first.substring(8)}}}',
    });
    expect(resolved, keys.values.values.first);
    expect(requests.toSet(), containsAll(apiMethods));
  });
  test('formatter real JSON YAML valid invalid unicode numeric arrays diff and complexity limits', () async {
    for (final mode in ['format', 'minify', 'json-yaml']) {
      final result =
          await ControlledWorker(formatData, {
                'mode': mode,
                'text': '{"中文":[1,2.5,true,null,{"x":"😀"}]}',
              }).result
              as Map;
      expect(jsonDecode(result['text'] as String), {
        '中文': [
          1,
          2.5,
          true,
          null,
          {'x': '😀'},
        ],
      });
    }
    final yaml =
        await ControlledWorker(formatData, {
              'mode': 'yaml-json',
              'text': 'name: 中文\nlist:\n  - 1\n  - true\n',
            }).result
            as Map;
    expect((yaml['value'] as Map)['list'], [1, true]);
    for (final (mode, text) in [
      ('format', '{"x":\n invalid}'),
      ('yaml-json', 'x: [1,'),
      ('format', ''),
    ]) {
      await expectLater(
        ControlledWorker(formatData, {'mode': mode, 'text': text}).result,
        throwsA(isA<ToolFailure>()),
      );
    }
    final diff =
        await ControlledWorker(formatData, {
              'mode': 'diff',
              'text': '{"a/b":1}',
              'other': '{"a/b":2}',
            }).result
            as Map;
    expect((diff['value'] as List).first['path'], '/a~1b');
    await expectLater(
      ControlledWorker(formatData, {
        'mode': 'yaml-json',
        'text': '? [a,b]\n: value',
      }).result,
      throwsA(isA<ToolFailure>()),
    );
  });
  test('regex captures names replacements invalid empty matches and real expensive expression is terminated', () async {
    final result =
        await ControlledWorker(evaluateRegex, {
              'pattern': r'(?<word>[a-z]+)(\d+)',
              'text': 'abc12 def34',
              'replacement': r'${word}-$2',
            }).result
            as Map;
    expect((result['matches'] as List).length, 2);
    expect(result['replacement'], 'abc-12 def-34');
    final empty =
        await ControlledWorker(evaluateRegex, {
              'pattern': '',
              'text': 'abc',
              'replacement': 'x',
            }).result
            as Map;
    expect((empty['matches'] as List).length, 4);
    await expectLater(
      ControlledWorker(evaluateRegex, {'pattern': '[', 'text': 'abc'}).result,
      throwsA(isA<ToolFailure>()),
    );
    final clock = Stopwatch()..start();
    await expectLater(
      ControlledWorker(evaluateRegex, {
        'pattern': r'(a+)+$',
        'text': '${'a' * 50000}!',
      }, timeout: const Duration(milliseconds: 150)).result,
      throwsA(isA<ToolFailure>()),
    );
    expect(clock.elapsedMilliseconds, lessThan(3000));
    // A second worker still succeeds after the costly worker has been killed.
    expect(
      (await ControlledWorker(evaluateRegex, {
            'pattern': 'a',
            'text': 'a',
          }).result
          as Map)['matches'],
      isNotEmpty,
    );
    final cancel = ControlledWorker(evaluateRegex, {
      'pattern': r'(a+)+$',
      'text': '${'a' * 50000}!',
    });
    final cancelled = expectLater(cancel.result, throwsA(isA<ToolFailure>()));
    cancel.cancel();
    await cancelled;
  });
  test('streamed real file hashes match independent Python hashlib and detect a one-byte change', () async {
    final fixture = File('../../artifacts/qa/v24-hash/expected.json');
    final expected = jsonDecode(await fixture.readAsString()) as List;
    for (final item in expected) {
      var updates = 0;
      final result = await hashFile(
        File(item['path'] as String),
        DevCancellation(),
        progress: (_, _) => updates++,
      );
      expect(result.sha256, item['sha256']);
      expect(result.sha512, item['sha512']);
      expect(result.size, item['size']);
      expect(updates, greaterThan(0));
      expect(result.matches(item['sha256'] as String), true);
    }
    expect(expected[0]['sha256'], isNot(expected[1]['sha256']));
    final cancel = DevCancellation()..cancel();
    await expectLater(
      hashFile(File(expected[0]['path'] as String), cancel),
      throwsA(isA<ToolFailure>()),
    );
  });
}
