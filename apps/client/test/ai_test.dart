import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/security/credential_store.dart';
import 'package:links_toolbox/features/ai_desk/ai_service.dart';

class TestCredentials implements CredentialStore {
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
  late AppDatabase db;
  late AiRepository repo;
  late AiApi api;
  late HttpServer server;
  late TestCredentials keys;
  late AiConfig config;
  String mode = 'ok';
  final requests = <Map<String, dynamic>>[];
  final serverTasks = <Future<void>>[];
  setUp(() async {
    requests.clear();
    serverTasks.clear();
    mode = 'ok';
    db = AppDatabase(NativeDatabase.memory());
    await db.initialize();
    keys = TestCredentials();
    repo = AiRepository(RecordStore(db), keys);
    api = AiApi();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    config = AiConfig(
      name: '本机协议测试',
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      model: 'test-only',
      inputPrice: 1,
      outputPrice: 2,
    );
    server.listen((req) {
      serverTasks.add(() async {
        try {
          expect(
            req.headers.value('authorization'),
            'Bearer test-secret-not-real',
          );
          if (req.uri.path == '/v1/models') {
            req.response.headers.contentType = ContentType.json;
            req.response.write(
              jsonEncode({
                'data': [
                  {'id': 'test-only'},
                ],
              }),
            );
            await req.response.close();
            return;
          }
          final body = jsonDecode(
            await utf8.decoder.bind(req).join(),
          ) as Map<String, dynamic>;
          requests.add(body);
          if (mode == 'quota') {
            req.response.statusCode = 429;
            req.response.headers.contentType = ContentType.json;
            req.response.write(
              jsonEncode({
                'error': {
                  'code': 'insufficient_quota',
                  'message': 'test-secret-not-real',
                },
              }),
            );
            await req.response.close();
            return;
          }
          req.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          final raw = utf8.encode(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': '第一段中文'},
                },
              ],
            })}\n\n',
          );
          // Fragment inside UTF8 and across SSE lines: the parser must reassemble both.
          for (var i = 0; i < raw.length; i += 7) {
            req.response.add(raw.sublist(i, (i + 7).clamp(0, raw.length)));
            await req.response.flush();
          }
          if (mode == 'slow') {
            await Future<void>.delayed(const Duration(milliseconds: 350));
          }
          req.response.write(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': '结束'},
                },
              ],
            })}\n\n',
          );
          if (mode != 'noUsage') {
            req.response.write(
              'data: ${jsonEncode({
                'choices': [],
                'usage': {'prompt_tokens': 12, 'completion_tokens': 4, 'total_tokens': 16},
              })}\n\n',
            );
          }
          req.response.write('data: [DONE]\n\n');
          await req.response.close();
        } catch (_) {
          try {
            await req.response.close();
          } catch (_) {}
        }
      }());
    });
  });
  tearDown(() async {
    api.dispose();
    await server.close(force: true);
    await Future.wait(serverTasks);
    await db.close();
  });
  test(
    'real local HTTP model listing and fragmented SSE persist actual usage',
    () async {
      final provider = await repo.configure(
        config,
        key: 'test-secret-not-real',
      );
      expect(
        jsonEncode(provider.data),
        isNot(contains('test-secret-not-real')),
      );
      expect(await api.models(config, await repo.key(provider)), ['test-only']);
      final chat = await repo.newConversation(provider);
      final runner = AiChatRunner(repo, api);
      await runner.send(chat, provider, '用户问题');
      final rows = await repo.messages(chat.id);
      expect(rows.length, 2);
      expect(rows.last.body, '第一段中文结束');
      expect(rows.last.text('usageSource'), 'server');
      expect(rows.last.data['cost'], 0.000020);
      expect(requests.single['stream'], true);
      expect(requests.single['messages'].single['content'], '用户问题');
    },
  );
  test(
    'cancel stops late chunks and persists only already received partial text',
    () async {
      mode = 'slow';
      final provider = await repo.configure(
        config,
        key: 'test-secret-not-real',
      );
      final chat = await repo.newConversation(provider);
      final first = Completer<void>();
      final runner = AiChatRunner(
        repo,
        api,
        onUpdate: (text, busy, error) {
          if (text.isNotEmpty && !first.isCompleted) first.complete();
        },
      );
      final work = runner.send(chat, provider, '取消测试');
      await first.future;
      await runner.stop();
      await work;
      final before = (await repo.messages(chat.id)).last;
      expect(before.body, '第一段中文');
      expect(before.text('status'), 'cancelled');
      await Future<void>.delayed(const Duration(milliseconds: 450));
      final after = (await repo.messages(chat.id)).last;
      expect(after.body, before.body);
      expect(after.revision, before.revision);
    },
  );
  test(
    'quota error is classified and never echoes server message or credentials',
    () async {
      mode = 'quota';
      final provider = await repo.configure(
        config,
        key: 'test-secret-not-real',
      );
      final chat = await repo.newConversation(provider);
      String? error;
      await AiChatRunner(
        repo,
        api,
        onUpdate: (_, busy, e) {
          if (!busy) error = e;
        },
      ).send(chat, provider, '配额测试');
      expect(error, contains('配额'));
      expect(error, isNot(contains('test-secret-not-real')));
      expect((await repo.messages(chat.id)).last.text('status'), 'failed');
    },
  );
  test('missing usage is explicitly estimated and retry does not duplicate user turn', () async {
    mode = 'noUsage';
    final provider = await repo.configure(config, key: 'test-secret-not-real');
    final chat = await repo.newConversation(provider);
    final runner = AiChatRunner(repo, api);
    await runner.send(chat, provider, '估算测试');
    expect(
      (await repo.messages(chat.id)).last.text('usageSource'),
      'estimated',
    );
    await runner.send(chat, provider, '', retry: true);
    expect(
      (await repo.messages(chat.id))
          .where((r) => r.text('role') == 'user')
          .length,
      1,
    );
  });
  test(
    'non-loopback HTTP, embedded key and invalid pricing are rejected',
    () async {
      await expectLater(
        repo.configure(
          const AiConfig(
            name: 'unsafe',
            baseUrl: 'http://example.com/v1',
            model: 'm',
          ),
          key: 'x',
        ),
        throwsA(isA<ToolFailure>()),
      );
      await expectLater(
        repo.configure(
          const AiConfig(
            name: 'unsafe',
            baseUrl: 'https://user:secret@example.com/v1',
            model: 'm',
          ),
          key: 'x',
        ),
        throwsA(isA<ToolFailure>()),
      );
      final provider = await repo.configure(
        config,
        key: 'test-secret-not-real',
      );
      await expectLater(
        repo.configure(
          const AiConfig(
            name: 'new',
            baseUrl: 'https://example.com/v1',
            model: 'm',
          ),
          existing: provider,
        ),
        throwsA(isA<ToolFailure>()),
      );
      expect(keys.values.length, 1);
      await repo.removeProvider(provider);
      expect(keys.values, isEmpty);
    },
  );
}
