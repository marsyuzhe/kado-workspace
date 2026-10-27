import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/data/tool_record.dart';
import 'hash_service.dart';

/// One explicit host/port only. No discovery, scan ranges, credentials, Agent
/// registration or automatic requests. TLS inspection sends no HTTP payload.
class NetworkInspectorService {
  Future<Map<String, dynamic>> check(
    String host,
    int port,
    String protocol, {
    Duration timeout = const Duration(seconds: 3),
    DevCancellation? cancellation,
  }) async {
    host = host.trim();
    if (host.isEmpty ||
        host.length > 253 ||
        !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(host) ||
        port < 1 ||
        port > 65535 ||
        !{'dns', 'tcp', 'http', 'https'}.contains(protocol) ||
        timeout.inMilliseconds < 100 ||
        timeout.inSeconds > 30) {
      throw const ToolFailure('主机、端口、协议或超时无效。');
    }
    final cancel = cancellation ?? DevCancellation(),
        clock = Stopwatch()..start();
    final addresses = await InternetAddress.lookup(host).timeout(timeout);
    cancel.check();
    final result = <String, dynamic>{
      'host': host,
      'port': port,
      'protocol': protocol,
      'addresses': addresses.map((a) => a.address).toList(),
    };
    if (protocol == 'dns') {
      result['elapsedMs'] = clock.elapsedMilliseconds;
      return result;
    }
    if (protocol == 'http') {
      final client = HttpClient()..connectionTimeout = timeout;
      final timer = Timer(timeout, () => client.close(force: true));
      try {
        final request = await client
            .getUrl(Uri(scheme: 'http', host: host, port: port, path: '/'))
            .timeout(timeout);
        request.followRedirects = false;
        final response = await request.close().timeout(timeout);
        cancel.check();
        result['status'] = response.statusCode;
      } finally {
        timer.cancel();
        client.close(force: true);
      }
    } else {
      final task = await Socket.startConnect(host, port);
      Socket? socket;
      final timer = Timer(timeout, () {
        task.cancel();
        socket?.destroy();
      });
      try {
        socket = await task.socket.timeout(timeout);
        cancel.check();
        result['connected'] = true;
        if (protocol == 'https') {
          var trusted = true;
          final tls = await SecureSocket.secure(
            socket,
            host: host,
            onBadCertificate: (_) {
              trusted = false;
              return true;
            },
          ).timeout(timeout);
          socket = tls;
          cancel.check();
          final cert = tls.peerCertificate;
          if (cert == null) throw const ToolFailure('对端未提供证书。');
          result['certificate'] = {
            'subject': cert.subject,
            'issuer': cert.issuer,
            'starts': cert.startValidity.toUtc().toIso8601String(),
            'expires': cert.endValidity.toUtc().toIso8601String(),
            'sha256': sha256.convert(cert.der).toString(),
            'trusted': trusted,
            'note': trusted ? '本机信任链检查通过' : '证书不被本机信任；仅完成诊断握手，未发送HTTP数据/凭据',
          };
        }
      } finally {
        timer.cancel();
        task.cancel();
        socket?.destroy();
      }
    }
    cancel.check();
    result['elapsedMs'] = clock.elapsedMilliseconds;
    return result;
  }

  Future<List<Map<String, dynamic>>> interfaces() async => [
    for (final interface in await NetworkInterface.list())
      {
        'name': interface.name,
        'addresses': interface.addresses.map((a) => a.address).toList(),
      },
  ];

  /// Fixed native command. User host/port text is never interpolated into shell.
  Future<String> windowsConnections() async {
    if (!Platform.isWindows) throw const ToolFailure('此列表仅Windows可用。');
    final executable = p.join(
      Platform.environment['SystemRoot'] ?? r'C:\Windows',
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    final process = await Process.start(executable, [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r"Get-NetTCPConnection -ErrorAction Stop | Select-Object -First 500 LocalAddress,LocalPort,RemoteAddress,RemotePort,State,OwningProcess,@{Name='Process';Expression={(Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName}} | ConvertTo-Json -Depth 3 -Compress",
    ]);
    final output = BytesBuilder(copy: false),
        errors = BytesBuilder(copy: false);
    var exceeded = false;
    void collect(BytesBuilder sink, List<int> chunk) {
      if (sink.length + chunk.length > 1024 * 1024) {
        exceeded = true;
        process.kill();
      } else {
        sink.add(chunk);
      }
    }

    final a = process.stdout.listen((chunk) => collect(output, chunk)),
        b = process.stderr.listen((chunk) => collect(errors, chunk));
    final outDone = a.asFuture<void>(), errorDone = b.asFuture<void>();
    final timer = Timer(const Duration(seconds: 8), process.kill);
    try {
      final code = await process.exitCode;
      await outDone;
      await errorDone;
      if (code != 0 || exceeded) throw const ToolFailure('读取连接失败、超时或权限不足。');
      return utf8.decode(output.takeBytes(), allowMalformed: true);
    } finally {
      timer.cancel();
      process.kill();
    }
  }
}
