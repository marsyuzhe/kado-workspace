import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/jobs/utility_process.dart';
import '../server/server_service.dart';

class HomeDeviceInput {
  const HomeDeviceInput(
    this.name,
    this.type,
    this.host,
    this.port,
    this.protocol, {
    this.managementUrl = '',
    this.tags = const [],
    this.notes = '',
  });
  final String name, type, host, protocol, managementUrl, notes;
  final int port;
  final List<String> tags;
  static const types = {'NAS', 'Router', 'PC', 'TV', 'Server', 'Other'};
  String get normalizedHost => host.trim().replaceAll(RegExp(r'^\[|\]$'), '');
  String get httpUrl => Uri(
    scheme: protocol == 'https' ? 'https' : 'http',
    host: normalizedHost,
    port: port,
    path: '/',
  ).toString();
  String get url => managementUrl.trim().isEmpty && protocol != 'tcp'
      ? httpUrl
      : managementUrl.trim();
  void validate() {
    if (name.trim().isEmpty ||
        name.length > 100 ||
        !types.contains(type) ||
        !{'http', 'https', 'tcp'}.contains(protocol) ||
        port < 1 ||
        port > 65535 ||
        normalizedHost.isEmpty ||
        normalizedHost.length > 253 ||
        normalizedHost.startsWith('-') ||
        !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(normalizedHost) ||
        tags.length > 30 ||
        notes.length > 20000) {
      throw const ToolFailure('设备名称、类型、主机、端口或备注无效。主机只填IP/DNS名称。');
    }
    if (url.isNotEmpty) {
      validateWebsite(url);
      final uri = Uri.parse(url);
      if (uri.queryParameters.keys.any(
        (key) => RegExp(
          r'password|token|api.?key|secret|credential',
          caseSensitive: false,
        ).hasMatch(key),
      )) {
        throw const ToolFailure('管理地址不能包含密码或令牌；请在设备登录页面输入凭据。');
      }
    }
  }

  factory HomeDeviceInput.fromRecord(ToolRecord row) => HomeDeviceInput(
    row.title,
    row.text('type'),
    row.text('host'),
    row.number('port'),
    row.text('protocol'),
    managementUrl: row.text('managementUrl'),
    tags: row.strings('tags'),
    notes: row.body,
  );
}

class HomeDashboardService {
  HomeDashboardService(this.store);
  final RecordStore store;
  Future<ToolRecord> save(HomeDeviceInput input, {ToolRecord? existing}) async {
    input.validate();
    if (existing != null && existing.kind != 'home_device') {
      throw const ToolFailure('设备记录类型无效。');
    }
    final data = {
      ...existing?.data ?? {},
      'payloadVersion': 1,
      'type': input.type,
      'host': input.normalizedHost,
      'port': input.port,
      'protocol': input.protocol,
      'managementUrl': input.url,
      'tags': input.tags.toSet().toList(),
      'syncAllowed': false,
      'isSensitive': true,
    };
    return existing == null
        ? store.create('home_device', input.name, body: input.notes, data: data)
        : store.save(
            existing.copyWith(title: input.name, body: input.notes, data: data),
          );
  }

  Future<void> remove(ToolRecord row, {required bool confirmed}) async {
    if (!confirmed || row.kind != 'home_device') {
      throw const ToolFailure('删除设备需要确认。');
    }
    for (final job in await store.list('utility_job', limit: 10000)) {
      if (!utilityJobStatus(job).terminal &&
          (job.data['inputReferences'] as Map?)?['deviceId'] == row.id) {
        throw const ToolFailure('请先等待或取消此设备的连接检查。');
      }
    }
    await store.transaction(() async {
      for (final check in await store.list('home_check', limit: 10000)) {
        if (check.text('deviceId') == row.id) await store.delete(check);
      }
      await store.delete(row);
    });
  }

  Future<ToolRecord> check(
    ToolRecord original,
    String method,
    UtilityJobContext job,
  ) async {
    final input = HomeDeviceInput.fromRecord(original);
    input.validate();
    if (!{'tcp', 'http', 'ping'}.contains(method) ||
        method == 'ping' && !Platform.isWindows) {
      throw const ToolFailure('检查方式不可用。');
    }
    final current = await store.get(original.id);
    if (current?.kind != 'home_device' ||
        current!.text('host') != input.normalizedHost ||
        current.number('port') != input.port ||
        current.text('managementUrl') != input.url) {
      throw const ToolFailure('设备目标在确认后变化，请重新确认检查。');
    }
    job.check();
    await job.progress(
      0,
      1,
      currentFile: '$method ${input.normalizedHost}:${input.port}',
      force: true,
    );
    final timer = Stopwatch()..start();
    var reachable = false;
    int? status;
    String message;
    if (method == 'http') {
      if (!{'http', 'https'}.contains(input.protocol)) {
        throw const ToolFailure('此设备没有HTTP/HTTPS协议，请选择TCP。');
      }
      final result = await WebsiteMonitor().check(
        input.httpUrl,
        timeout: const Duration(seconds: 3),
      );
      status = result.status;
      reachable = status != null;
      message = result.error ?? 'HTTP $status（只表示此端点响应，不代表设备所有功能正常）';
    } else if (method == 'tcp') {
      Socket? socket;
      try {
        final task = await Socket.startConnect(
          input.normalizedHost,
          input.port,
        );
        job.onCancel(() async {
          task.cancel();
          socket?.destroy();
        });
        socket = await task.socket.timeout(const Duration(seconds: 3));
        job.check();
        reachable = true;
        message = 'TCP端口可连接';
      } catch (_) {
        job.check();
        message = 'TCP连接失败或超时；请核对地址、端口和设备状态。';
      } finally {
        socket?.destroy();
      }
    } else {
      final executable = p.join(
        Platform.environment['SystemRoot'] ?? r'C:\Windows',
        'System32',
        'ping.exe',
      );
      final result = await runUtilityProcess(
        executable,
        ['-n', '1', '-w', '1500', input.normalizedHost],
        job,
        timeout: const Duration(seconds: 4),
      );
      reachable = result.code == 0;
      message = reachable ? '收到ICMP响应' : 'Ping未收到响应（防火墙可能禁用ICMP，不代表设备一定离线）';
    }
    job.check();
    final data = {
      'deviceId': original.id,
      'host': input.normalizedHost,
      'port': input.port,
      'method': method,
      'reachable': reachable,
      'httpStatus': status,
      'elapsedMs': timer.elapsedMilliseconds,
      'message': message,
      'checkedAt': DateTime.now().toUtc().toIso8601String(),
      'syncAllowed': false,
      'isSensitive': true,
    };
    final result = await store.create(
      'home_check',
      '${original.title}连接检查',
      body: message,
      data: data,
    );
    await job.output(result.id);
    final latest = await store.get(original.id);
    if (latest?.kind == 'home_device' &&
        latest!.text('host') == input.normalizedHost &&
        latest.number('port') == input.port) {
      await store.save(
        latest.copyWith(
          data: {
            ...latest.data,
            'lastCheckedAt': data['checkedAt'],
            'lastCheck': data,
          },
        ),
      );
    }
    await job.progress(1, 1, currentFile: message, force: true);
    return result;
  }
}
