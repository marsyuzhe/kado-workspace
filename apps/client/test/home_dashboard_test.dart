import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/features/utilities/home_dashboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This service test uses an owned real loopback server. Undo the widget
  // binding's automatic HTTP-400 substitute for this isolated test process.
  HttpOverrides.global = null;
  late Directory temp;
  late AppDatabase db;
  late RecordStore store;
  late UtilityJobEngine jobs;
  late HomeDashboardService service;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-home-test-');
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    jobs = UtilityJobEngine(JobQueueRepository(store));
    service = HomeDashboardService(store);
  });
  tearDown(() async {
    await jobs.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  Future<ToolRecord> check(ToolRecord device, String method) async {
    final job = await jobs.submit(
      'home_dashboard',
      'check',
      '检测自有服务',
      {'deviceId': device.id},
      confirmed: true,
      run: (ctx, _) async => (await service.check(device, method, ctx)).id,
    );
    final done = await jobs.waitFor(job.id);
    expect(
      utilityJobStatus(done),
      UtilityJobStatus.succeeded,
      reason: done.text('errorMessage'),
    );
    return (await store.get(done.text('resultReference')))!;
  }

  test(
    'real loopback HTTP and TCP status changes persist, with no network scan',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var status = 200;
      server.listen((request) {
        request.response.statusCode = status;
        request.response.write('owned endpoint');
        request.response.close();
      });
      final device = await service.save(
        HomeDeviceInput(
          '测试NAS',
          'NAS',
          '127.0.0.1',
          server.port,
          'http',
          tags: ['家庭'],
          notes: '自有HTTP服务',
        ),
      );
      try {
        final first = await check(device, 'http');
        expect(first.flag('reachable'), true);
        expect(first.number('httpStatus'), 200);
        status = 503;
        final changed = await check((await store.get(device.id))!, 'http');
        expect(changed.flag('reachable'), true);
        expect(changed.number('httpStatus'), 503);
        expect(
          (await check((await store.get(device.id))!, 'tcp')).flag('reachable'),
          true,
        );
      } finally {
        await server.close(force: true);
      }
      final down = await check((await store.get(device.id))!, 'tcp');
      expect(down.flag('reachable'), false);
      expect(down.body, contains('连接失败'));
      await db.close();
      db = AppDatabase.file(File('${temp.path}/test.sqlite'));
      await db.initialize();
      store = RecordStore(db);
      service = HomeDashboardService(store);
      final reopened = (await store.get(device.id))!;
      expect(reopened.text('lastCheckedAt'), isNotEmpty);
      expect((reopened.data['lastCheck'] as Map)['reachable'], false);
      expect(reopened.strings('tags'), ['家庭']);
      await service.remove(reopened, confirmed: true);
      expect(await store.list('home_device'), isEmpty);
      expect(await store.list('home_check'), isEmpty);
    },
  );
  test('invalid hosts, credentials in management URLs and changed confirmed targets are refused', () async {
    for (final input in [
      const HomeDeviceInput('x', 'NAS', '-n 100', 80, 'http'),
      const HomeDeviceInput('x', 'TV', '127.0.0.1', 0, 'tcp'),
      const HomeDeviceInput(
        'x',
        'PC',
        'localhost',
        80,
        'http',
        managementUrl: 'http://user:password@localhost',
      ),
      const HomeDeviceInput(
        'x',
        'Router',
        'localhost',
        80,
        'http',
        managementUrl: 'http://localhost/?token=private',
      ),
    ]) {
      await expectLater(service.save(input), throwsA(isA<ToolFailure>()));
    }
    final device = await service.save(
      const HomeDeviceInput('x', 'PC', 'localhost', 8080, 'http'),
    );
    await service.save(
      const HomeDeviceInput('x', 'PC', 'localhost', 8081, 'http'),
      existing: device,
    );
    final job = await jobs.submit(
      'home_dashboard',
      'check',
      '拒绝目标变化',
      {'deviceId': device.id},
      confirmed: true,
      run: (ctx, _) async => (await service.check(device, 'tcp', ctx)).id,
    );
    await jobs.waitIdle();
    expect(
      utilityJobStatus(await jobs.repository.require(job.id)),
      UtilityJobStatus.failed,
    );
    expect(await store.list('home_check'), isEmpty);
  });
}
