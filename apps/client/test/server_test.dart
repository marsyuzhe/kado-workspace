import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/features/server/server_service.dart';

import 'ai_test.dart' show TestCredentials;

class MockConnection implements ServerConnection {
  int samples = 0;
  bool open = true;
  @override
  bool get connected => open;
  @override
  Future<void> close() async {
    open = false;
  }

  @override
  Future<CommandResult> run(String command) async {
    if (command == serverCommands['cpu']) {
      return CommandResult(
        samples++ == 0
            ? 'cpu 100 0 100 800 0 0 0 0 0 0'
            : 'cpu 150 0 150 900 0 0 0 0 0 0',
        '',
        0,
      );
    }
    if (command == serverCommands['memory']) {
      return const CommandResult(
        'MemTotal: 8000 kB\nMemAvailable: 3000 kB\n',
        '',
        0,
      );
    }
    if (command == serverCommands['disk']) {
      return const CommandResult(
        'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 10000 4000 6000 40% /\n',
        '',
        0,
      );
    }
    if (command == serverCommands['uptime']) {
      return const CommandResult('12345.50 9.0', '', 0);
    }
    if (command == serverCommands['distro']) {
      return const CommandResult(
        'NAME="Linux"\nPRETTY_NAME="Test Linux 1"\n',
        '',
        0,
      );
    }
    if (command == serverCommands['docker']) {
      return const CommandResult(
        '{"Names":"test-web","Image":"nginx","State":"running","Status":"Up 1 hour"}\n',
        '',
        0,
      );
    }
    throw const ToolFailure('Unknown mock command');
  }
}

class FailedConnection extends MockConnection {
  @override
  Future<CommandResult> run(String command) async =>
      const CommandResult('', 'permission denied', 1);
}

void main() {
  late AppDatabase db;
  late ServerRepository repo;
  late TestCredentials keys;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.initialize();
    keys = TestCredentials();
    repo = ServerRepository(RecordStore(db), keys);
  });
  tearDown(() async {
    await db.close();
  });
  const config = ServerConfig(
    name: '测试配置',
    host: 'test.example',
    username: 'links',
  );
  test('secret excluded from metadata; host pin requires first confirmation and rejects changes', () async {
    final server = await repo.save(config, secret: 'mock-password');
    expect(server.data.values, isNot(contains('mock-password')));
    var confirmations = 0;
    final fingerprint = 'SHA256:${'A' * 43}';
    expect(
      await repo.verifyHost(server, 'ssh-ed25519', fingerprint, (_, _) async {
        confirmations++;
        return false;
      }),
      false,
    );
    expect((await repo.store.get(server.id))!.text('hostKey'), '');
    expect(
      await repo.verifyHost(server, 'ssh-ed25519', fingerprint, (_, _) async {
        confirmations++;
        return true;
      }),
      true,
    );
    expect(
      await repo.verifyHost(server, 'ssh-ed25519', fingerprint, (_, _) async {
        throw StateError('must not ask again');
      }),
      true,
    );
    await expectLater(
      repo.verifyHost(
        server,
        'ssh-ed25519',
        'SHA256:${'B' * 43}',
        (_, _) async => true,
      ),
      throwsA(isA<ToolFailure>()),
    );
    expect(confirmations, 2);
    expect((await repo.secret(server))['secret'], 'mock-password');
  });
  test(
    'mock Linux outputs parse CPU delta, memory, root disk, uptime and Docker',
    () async {
      final mock = MockConnection();
      final snapshot = await ServerMonitor().read(
        mock,
        cpuInterval: Duration.zero,
      );
      expect(snapshot.cpuPercent, 50);
      expect(snapshot.memoryAvailableKB, 3000);
      expect(snapshot.diskUsedKB, 4000);
      expect(snapshot.uptimeSeconds, 12345.5);
      expect(snapshot.distro, 'Test Linux 1');
      expect(snapshot.docker.single['Names'], 'test-web');
      expect(snapshot.errors, isEmpty);
    },
  );
  test(
    'failed commands stay unavailable rather than inventing metrics',
    () async {
      final snapshot = await ServerMonitor().read(
        FailedConnection(),
        cpuInterval: Duration.zero,
      );
      expect(snapshot.cpuPercent, isNull);
      expect(snapshot.memoryTotalKB, isNull);
      expect(snapshot.diskTotalKB, isNull);
      expect(snapshot.docker, isEmpty);
      expect(snapshot.errors.length, 6);
    },
  );
  test('real local HTTP status recorded; redirects are not followed and certificate remains unavailable on HTTP', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((req) async {
      requests++;
      req.response.statusCode = 302;
      req.response.headers.set(
        'Location',
        'http://127.0.0.1:${server.port}/next',
      );
      await req.response.close();
    });
    try {
      final result = await WebsiteMonitor().check(
        'http://127.0.0.1:${server.port}/',
      );
      expect(result.status, 302);
      expect(result.error, isNull);
      expect(result.certificateExpires, isNull);
      expect(requests, 1);
      expect(result.elapsed.inMilliseconds, greaterThanOrEqualTo(0));
    } finally {
      await server.close(force: true);
    }
  });
  test(
    'invalid host, private key and website cannot be silently accepted',
    () async {
      await expectLater(
        repo.save(
          const ServerConfig(
            name: 'bad',
            host: 'ssh://host/path',
            username: 'root',
          ),
          secret: 'x',
        ),
        throwsA(isA<ToolFailure>()),
      );
      await expectLater(
        repo.save(
          const ServerConfig(
            name: 'bad',
            host: 'host',
            username: 'root',
            auth: 'key',
          ),
          secret: 'invalid pem',
        ),
        throwsA(isA<ToolFailure>()),
      );
      await expectLater(
        repo.website('bad', 'file:///C:/x'),
        throwsA(isA<ToolFailure>()),
      );
      expect(await repo.store.list('server'), isEmpty);
      expect(keys.values, isEmpty);
    },
  );
}
