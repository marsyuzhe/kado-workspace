import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/security/credential_store.dart';

class ServerConfig {
  const ServerConfig({
    required this.name,
    required this.host,
    required this.username,
    this.port = 22,
    this.auth = 'password',
    this.tags = const [],
    this.notes = '',
    this.timeout = 20,
  });
  factory ServerConfig.fromRecord(ToolRecord r) => ServerConfig(
    name: r.title,
    host: r.text('host'),
    username: r.text('username'),
    port: r.number('port', 22),
    auth: r.text('auth', 'password'),
    tags: r.strings('tags'),
    notes: r.body,
    timeout: r.number('timeout', 20),
  );
  final String name, host, username, auth, notes;
  final int port, timeout;
  final List<String> tags;
  void validate() {
    if (name.trim().isEmpty ||
        host.trim().isEmpty ||
        username.trim().isEmpty ||
        host.contains(RegExp(r'[\s/\\]')) ||
        host.contains('://') ||
        host.contains('@') ||
        host.contains('\u0000')) {
      throw const ToolFailure('请填写有效名称、主机名/IP和SSH用户名，主机不包含协议或路径。');
    }
    if (port < 1 || port > 65535 || timeout < 5 || timeout > 120) {
      throw const ToolFailure('端口1–65535，超时5–120秒。');
    }
    if (!{'password', 'key'}.contains(auth)) {
      throw const ToolFailure('认证方式应为password或key。');
    }
  }

  Map<String, dynamic> toJson() => {
    'host': host.trim(),
    'username': username.trim(),
    'port': port,
    'auth': auth,
    'tags': tags,
    'timeout': timeout,
  };
}

class ServerRepository {
  ServerRepository(this.store, this.credentials);
  final RecordStore store;
  final CredentialStore credentials;
  Future<ToolRecord> save(
    ServerConfig config, {
    String? secret,
    String passphrase = '',
    ToolRecord? existing,
  }) async {
    config.validate();
    final oldRef = existing?.text('credentialRef') ?? '';
    final changed = secret != null && secret.isNotEmpty;
    if (!changed && (oldRef.isEmpty || existing!.text('auth') != config.auth)) {
      throw const ToolFailure('请提供此认证方式的密码或私钥。');
    }
    if (config.auth == 'key' && changed) {
      try {
        SSHKeyPair.fromPem(secret, passphrase);
      } catch (_) {
        throw const ToolFailure('私钥格式或口令无效，仅支持SSH库兼容的PEM/OpenSSH密钥。');
      }
    }
    final reference = changed ? 'ssh.${newId()}' : oldRef;
    if (changed) {
      await credentials.write(
        reference,
        jsonEncode({'secret': secret, 'passphrase': passphrase}),
      );
    }
    final sameHost =
        existing != null &&
        existing.text('host') == config.host.trim() &&
        existing.number('port', 22) == config.port;
    late ToolRecord result;
    try {
      final data = {
        ...config.toJson(),
        'credentialRef': reference,
        'hostKey': sameHost ? existing.text('hostKey') : '',
        'hostKeyType': sameHost ? existing.text('hostKeyType') : '',
      };
      result = existing == null
          ? await store.create(
              'server',
              config.name,
              body: config.notes,
              data: data,
            )
          : await store.save(
              existing.copyWith(
                title: config.name,
                body: config.notes,
                data: data,
              ),
            );
    } catch (_) {
      if (changed) await credentials.delete(reference);
      rethrow;
    }
    if (changed && oldRef.isNotEmpty) await credentials.delete(oldRef);
    return result;
  }

  Future<Map<String, String>> secret(ToolRecord server) async {
    final value = await credentials.read(server.text('credentialRef'));
    if (value == null) throw const ToolFailure('此设备缺少SSH凭据，请重新配置。备份不包含密码或私钥。');
    final data = jsonDecode(value) as Map;
    return {
      'secret': data['secret'] as String,
      'passphrase': data['passphrase'] as String? ?? '',
    };
  }

  Future<bool> verifyHost(
    ToolRecord server,
    String type,
    String fingerprint,
    Future<bool> Function(String, String) confirm,
  ) async {
    if (!RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$').hasMatch(fingerprint)) {
      throw const ToolFailure('主机返回的指纹格式无效。');
    }
    final current = await store.get(server.id);
    if (current == null) throw const ToolFailure('服务器配置已移除。');
    final known = current.text('hostKey');
    if (known.isNotEmpty) {
      if (known != fingerprint || current.text('hostKeyType') != type) {
        throw const ToolFailure('SSH主机指纹已变化，已拒绝连接。请通过可信渠道核对后，在配置中手动移除旧指纹。');
      }
      return true;
    }
    if (!await confirm(type, fingerprint)) return false;
    await store.save(
      current.copyWith(
        data: {...current.data, 'hostKey': fingerprint, 'hostKeyType': type},
      ),
    );
    return true;
  }

  Future<void> forgetHost(ToolRecord server, {required bool confirmed}) async {
    if (!confirmed) throw const ToolFailure('重置指纹需要明确确认。');
    await store.save(
      server.copyWith(data: {...server.data, 'hostKey': '', 'hostKeyType': ''}),
    );
  }

  Future<void> remove(ToolRecord server) async {
    await store.delete(server);
    await credentials.delete(server.text('credentialRef'));
  }

  Future<ToolRecord> website(
    String title,
    String url, {
    ToolRecord? existing,
  }) async {
    validateWebsite(url);
    return existing == null
        ? store.create('website', title, data: {'url': url})
        : store.save(
            existing.copyWith(
              title: title,
              data: {...existing.data, 'url': url},
            ),
          );
  }
}

const serverCommands = <String, String>{
  'cpu': 'cat /proc/stat',
  'memory': 'cat /proc/meminfo',
  'disk': 'LC_ALL=C df -Pk /',
  'uptime': 'cat /proc/uptime',
  'distro': 'cat /etc/os-release',
  'docker': "docker ps -a --format '{{json .}}'",
};

/// Accept fixed monitoring commands or a Docker read with a strict hexadecimal
/// container ID. No names, shell metacharacters or mutating verbs are accepted.
bool isReadOnlyServerCommand(String command) =>
    serverCommands.values.contains(command) ||
    command == "docker image ls --format '{{json .}}'" ||
    RegExp(r"^docker logs --tail 200 --timestamps [a-f0-9]{12,64}$")
        .hasMatch(command) ||
    RegExp(
      r"^docker stats --no-stream --format '\{\{json \.\}\}' [a-f0-9]{12,64}$",
    ).hasMatch(command);

String dockerReadCommand(String kind, String id) {
  if (!RegExp(r'^[a-f0-9]{12,64}$').hasMatch(id)) {
    throw const ToolFailure('容器ID无效。');
  }
  return switch (kind) {
    'logs' => 'docker logs --tail 200 --timestamps $id',
    'stats' => "docker stats --no-stream --format '{{json .}}' $id",
    _ => throw const ToolFailure('只支持Docker日志或资源只读查询。'),
  };
}

class CommandResult {
  const CommandResult(this.output, this.error, this.exitCode);
  final String output, error;
  final int? exitCode;
}

abstract interface class ServerConnection {
  bool get connected;
  Future<CommandResult> run(String command);
  Future<void> close();
}

abstract interface class ServerConnector {
  Future<ServerConnection> connect(
    ServerConfig config,
    Map<String, String> credential,
    Future<bool> Function(String, String) verify,
  );
}

class DartSshConnector implements ServerConnector {
  @override
  Future<ServerConnection> connect(
    ServerConfig config,
    Map<String, String> credential,
    Future<bool> Function(String, String) verify,
  ) async {
    config.validate();
    SSHSocket? socket;
    SSHClient? client;
    try {
      socket = await SSHSocket.connect(
        config.host,
        config.port,
        timeout: Duration(seconds: config.timeout),
      );
      client = SSHClient(
        socket,
        username: config.username,
        onVerifyHostKey: (type, bytes) => verify(type, utf8.decode(bytes)),
        onPasswordRequest: config.auth == 'password'
            ? () => credential['secret']
            : null,
        identities: config.auth == 'key'
            ? SSHKeyPair.fromPem(
                credential['secret']!,
                credential['passphrase'],
              )
            : null,
      );
      // Attach a completion observer immediately so transport errors are consumed.
      unawaited(client.done.then((_) {}, onError: (Object _) {}));
      await client.authenticated.timeout(Duration(seconds: config.timeout));
      return DartSshConnection(client, Duration(seconds: config.timeout));
    } catch (e) {
      client?.close();
      socket?.destroy();
      if (e is ToolFailure) rethrow;
      throw const ToolFailure('SSH连接失败：请检查地址、端口、认证、指纹或超时设置。');
    }
  }
}

class DartSshConnection implements ServerConnection {
  DartSshConnection(this.client, this.timeout);
  final SSHClient client;
  final Duration timeout;
  @override
  bool get connected => !client.isClosed;
  @override
  Future<CommandResult> run(String command) async {
    if (!isReadOnlyServerCommand(command)) {
      throw const ToolFailure('当前只允许内置只读监控命令。');
    }
    if (!connected) throw const ToolFailure('SSH已断开。');
    SSHSession? session;
    Future<String> collect(Stream<List<int>> stream) async {
      final bytes = <int>[];
      await for (final chunk in stream) {
        bytes.addAll(chunk);
        if (bytes.length > 512 * 1024) {
          throw const ToolFailure('监控输出超过512KB，已停止本次读取。');
        }
      }
      return utf8.decode(bytes, allowMalformed: true);
    }

    try {
      session = await client.execute(command).timeout(timeout);
      final output = await Future.wait([
        collect(session.stdout),
        collect(session.stderr),
      ]).timeout(timeout);
      await session.done.timeout(timeout);
      return CommandResult(output[0], output[1], session.exitCode);
    } on TimeoutException {
      throw const ToolFailure('读取监控信息超时。');
    } finally {
      session?.close();
    }
  }

  @override
  Future<void> close() async {
    client.close();
    await client.done.catchError((Object _) {});
  }
}

class ServerSnapshot {
  const ServerSnapshot({
    this.cpuPercent,
    this.memoryTotalKB,
    this.memoryAvailableKB,
    this.diskTotalKB,
    this.diskUsedKB,
    this.uptimeSeconds,
    this.distro,
    this.docker = const [],
    this.errors = const {},
  });
  final double? cpuPercent, uptimeSeconds;
  final int? memoryTotalKB, memoryAvailableKB, diskTotalKB, diskUsedKB;
  final String? distro;
  final List<Map<String, dynamic>> docker;
  final Map<String, String> errors;
  String toMarkdown() =>
      '# 服务器只读快照\n\n检查时间：${DateTime.now().toUtc().toIso8601String()}\n\nCPU：${cpuPercent?.toStringAsFixed(1) ?? '不可用'}%\n内存：${memoryAvailableKB ?? '不可用'} / ${memoryTotalKB ?? '不可用'} KB可用\n根分区已用：${diskUsedKB ?? '不可用'} / ${diskTotalKB ?? '不可用'} KB\n运行时间：${uptimeSeconds ?? '不可用'}秒\n发行版：${distro ?? '不可用'}\n\nDocker：${jsonEncode(docker)}\n\n错误：${jsonEncode(errors)}';
}

List<int>? parseCpu(String text) {
  final line = text.split('\n').where((l) => l.startsWith('cpu ')).firstOrNull;
  if (line == null) return null;
  final values = line
      .trim()
      .split(RegExp(r'\s+'))
      .skip(1)
      .map(int.tryParse)
      .toList();
  if (values.length < 4 || values.any((n) => n == null)) return null;
  // Linux total excludes guest/guest_nice: these are already included in user/nice.
  final total = values.take(8).fold<int>(0, (n, v) => n + v!);
  final idle = values[3]! + (values.length > 4 ? values[4]! : 0);
  return [total, idle];
}

class ServerMonitor {
  Future<ServerSnapshot> read(
    ServerConnection connection, {
    Duration cpuInterval = const Duration(milliseconds: 350),
  }) async {
    final results = <String, String>{}, errors = <String, String>{};
    Future<void> fetch(String key) async {
      try {
        final value = await connection.run(serverCommands[key]!);
        if (value.exitCode != 0) {
          errors[key] = key == 'docker'
              ? 'Docker未安装、服务未运行或当前用户没有读取权限。'
              : '命令返回失败';
        } else {
          results[key] = value.output;
        }
      } catch (_) {
        errors[key] = '无法读取（连接、权限或超时）';
      }
    }

    await fetch('cpu');
    final first = parseCpu(results['cpu'] ?? '');
    await Future.wait(
      ['memory', 'disk', 'uptime', 'distro', 'docker'].map(fetch),
    );
    await Future<void>.delayed(cpuInterval);
    await fetch('cpu');
    final second = parseCpu(results['cpu'] ?? '');
    double? cpu;
    if (first != null && second != null && second[0] > first[0]) {
      cpu = ((1 - (second[1] - first[1]) / (second[0] - first[0])) * 100).clamp(
        0,
        100,
      );
    }
    final memory = <String, int>{};
    for (final line in (results['memory'] ?? '').split('\n')) {
      final m = RegExp(r'^(\w+):\s+(\d+)').firstMatch(line);
      if (m != null) memory[m.group(1)!] = int.parse(m.group(2)!);
    }
    final disk = (results['disk'] ?? '')
        .trim()
        .split('\n')
        .last
        .split(RegExp(r'\s+'));
    final distro = (results['distro'] ?? '')
        .split('\n')
        .where((l) => l.startsWith('PRETTY_NAME='))
        .firstOrNull
        ?.substring(12)
        .replaceAll(RegExp(r'^"|"$'), '');
    final containers = <Map<String, dynamic>>[];
    for (final line
        in (results['docker'] ?? '')
            .split('\n')
            .where((l) => l.trim().isNotEmpty)) {
      try {
        containers.add(Map<String, dynamic>.from(jsonDecode(line) as Map));
      } catch (_) {
        errors['docker'] = 'Docker输出格式不兼容';
      }
    }
    return ServerSnapshot(
      cpuPercent: cpu,
      memoryTotalKB: memory['MemTotal'],
      memoryAvailableKB: memory['MemAvailable'],
      diskTotalKB: disk.length >= 6 ? int.tryParse(disk[1]) : null,
      diskUsedKB: disk.length >= 6 ? int.tryParse(disk[2]) : null,
      uptimeSeconds: double.tryParse(
        (results['uptime'] ?? '').split(' ').first,
      ),
      distro: distro,
      docker: containers,
      errors: errors,
    );
  }
}

void validateWebsite(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const ToolFailure('网址必须是没有内嵌凭据的HTTP/HTTPS地址。');
  }
}

class WebsiteResult {
  const WebsiteResult(
    this.status,
    this.elapsed,
    this.checkedAt, {
    this.certificateExpires,
    this.error,
  });
  final int? status;
  final Duration elapsed;
  final DateTime checkedAt;
  final DateTime? certificateExpires;
  final String? error;
  Map<String, dynamic> toJson() => {
    'status': status,
    'elapsedMs': elapsed.inMilliseconds,
    'checkedAt': checkedAt.toUtc().toIso8601String(),
    'certificateExpires': certificateExpires?.toUtc().toIso8601String(),
    'error': error ?? '',
  };
}

class WebsiteMonitor {
  Future<WebsiteResult> check(
    String url, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    validateWebsite(url);
    final uri = Uri.parse(url);
    final watch = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = timeout;
    int? status;
    DateTime? expiry;
    String? error;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.followRedirects = false;
      request.headers.set('User-Agent', 'LinksToolbox/1.0');
      final response = await request.close().timeout(timeout);
      status = response.statusCode;
      expiry = response.certificate?.endValidity;
      // Status and headers are sufficient. Cancel the body to avoid downloading a site.
      final subscription = response.listen((_) {});
      await subscription.cancel();
    } catch (_) {
      error = '网站检测失败（网络、TLS证书、地址或超时）。';
    } finally {
      client.close(force: true);
    }
    return WebsiteResult(
      status,
      watch.elapsed,
      DateTime.now(),
      certificateExpires: expiry,
      error: error,
    );
  }
}
