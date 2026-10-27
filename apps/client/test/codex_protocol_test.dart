import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/features/studio/codex_diagnostics.dart';
import 'package:links_toolbox/features/studio/codex_protocol.dart';

void main() {
  test('JSONL handles split UTF8, CRLF and multiple structured events', () {
    final decoder = CodexJsonLines(),
        bytes = utf8.encode(
          '{"method":"item/agentMessage/delta","params":{"delta":"中文"}}\r\n{"method":"turn/completed","params":{"turn":{"status":"failed"}}}\n',
        );
    final events = <Map<String, dynamic>>[];
    for (final byte in bytes) {
      events.addAll(decoder.add([byte]));
    }
    expect((events.first['params'] as Map)['delta'], '中文');
    expect(((events.last['params'] as Map)['turn'] as Map)['status'], 'failed');
    decoder.finish();
  });
  test('malformed, oversized and truncated process output is rejected', () {
    expect(
      () => CodexJsonLines().add(utf8.encode('not-json\n')),
      throwsA(isA<ToolFailure>()),
    );
    expect(
      () => CodexJsonLines().add(
        List.filled(CodexJsonLines.maxLineBytes + 1, 65),
      ),
      throwsA(isA<ToolFailure>()),
    );
    final partial = CodexJsonLines()..add(utf8.encode('{"partial":'));
    expect(partial.finish, throwsA(isA<ToolFailure>()));
  });
  test('protocol handshake correlates replies and denies all unapproved requests', () async {
    final stdout = StreamController<List<int>>(),
        sent = <Map<String, dynamic>>[];
    var closed = 0;
    final client = CodexRpcClient(
      stdout: stdout.stream,
      send: (line) {
        final message = jsonDecode(line) as Map<String, dynamic>;
        sent.add(message);
        expect(message, isNot(contains('jsonrpc')));
        if (message['method'] == 'initialize') {
          stdout.add(
            utf8.encode(
              '${jsonEncode({
                'id': message['id'],
                'result': {'userAgent': 'fixture'},
              })}\n',
            ),
          );
        }
      },
      closeOwnedProcess: () async {
        closed++;
      },
    );
    final events = <Map<String, dynamic>>[];
    final subscription = client.events.listen(events.add);
    expect((await client.initialize())['userAgent'], 'fixture');
    expect(sent[1]['method'], 'initialized');
    stdout.add(
      utf8.encode(
        '${jsonEncode({
          'id': 'approval_1',
          'method': 'item/fileChange/requestApproval',
          'params': {'threadId': 't', 'turnId': 'u', 'itemId': 'i', 'access_token': 'private'},
        })}\n',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(sent.last['id'], 'approval_1');
    expect((sent.last['error'] as Map)['code'], -32601);
    expect(sent.any((m) => '${m['result']}'.contains('accept')), isFalse);
    expect((events.single['params'] as Map)['access_token'], '[REDACTED]');
    await client.dispose();
    await client.dispose();
    expect(closed, 1);
    await subscription.cancel();
    await stdout.close();
  });
  test(
    'process exit interrupts pending requests and never becomes completion',
    () async {
      final stdout = StreamController<List<int>>();
      final client = CodexRpcClient(
        stdout: stdout.stream,
        send: (_) {},
        closeOwnedProcess: () async {},
      );
      final request = client.request('account/read', {'refreshToken': false});
      final assertion = expectLater(request, throwsA(isA<ToolFailure>()));
      await stdout.close();
      await assertion;
      await client.dispose();
    },
  );
  test('protocol deadline rejects an unresponsive process', () async {
    final stdout = StreamController<List<int>>();
    final client = CodexRpcClient(
      stdout: stdout.stream,
      send: (_) {},
      closeOwnedProcess: () async {},
      requestTimeout: const Duration(milliseconds: 10),
    );
    await expectLater(
      client.request('account/read', {'refreshToken': false}),
      throwsA(isA<ToolFailure>()),
    );
    await client.dispose();
    await stdout.close();
  });
  test(
    'log redaction removes credentials, nested secrets and private keys',
    () {
      final result = jsonEncode(
        redactCodexValue({
          'Authorization': 'Bearer abc',
          'text': 'Bearer abc123 sk-fixturecredential123 password=hidden',
          'nested': {'refresh_token': 'hidden'},
          'keyFile':
              '-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----',
        }),
      );
      expect(result, isNot(contains('hidden')));
      expect(result, isNot(contains('abc123')));
      expect(result, isNot(contains('fixturecredential')));
      expect(result, isNot(contains('BEGIN PRIVATE')));
    },
  );
  test('actual installed CLI schema lacks directory read isolation and stays disabled', () async {
    final schema = jsonDecode(
      await File('test/fixtures/codex_0163_capabilities.json').readAsString(),
    ) as Map<String, dynamic>;
    expect(schemaSupportsRestrictedRead(schema), isFalse);
    const probe = CodexDiagnostic(
      version: '0.163.0-alpha.11.2',
      restrictedReadSupported: false,
      schemaChecksum: 'fixture',
    );
    expect(probe.taskExecutionEnabled, isFalse);
    expect(probe.explanation, contains('BLOCKED'));
    // Even a later schema passing this one capability gate is not equivalent
    // to a finished, authorized or externally verified task adapter.
    expect(
      const CodexDiagnostic(
        version: 'future',
        restrictedReadSupported: true,
        schemaChecksum: 'fixture',
      ).taskExecutionEnabled,
      isFalse,
    );
  });
  test(
    'missing executable and shell strings cannot become metadata commands',
    () async {
      await expectLater(
        CodexDiagnostics().inspect('codex.exe & echo unsafe'),
        throwsA(isA<ToolFailure>()),
      );
      await expectLater(
        CodexDiagnostics().inspect(r'C:\missing\codex.exe'),
        throwsA(isA<ToolFailure>()),
      );
    },
  );
  test('restricted read schema capability is detected without enabling task execution', () {
    final supported = <String, dynamic>{
      'definitions': {
        'SandboxPolicy': {
          'oneOf': [
            {
              'properties': {
                'type': {
                  'enum': ['readOnly'],
                },
                'access': {r'$ref': '#/definitions/ReadOnlyAccess'},
              },
            },
          ],
        },
        'ReadOnlyAccess': {
          'oneOf': [
            {
              'properties': {
                'type': {
                  'enum': ['restricted'],
                },
                'readableRoots': {'type': 'array'},
                'includePlatformDefaults': {'type': 'boolean'},
              },
            },
          ],
        },
      },
    };
    expect(schemaSupportsRestrictedRead(supported), isTrue);
  });
}
