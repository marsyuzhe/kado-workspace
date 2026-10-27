import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/parser.dart' as html;
import 'package:flutter/services.dart';

import '../../core/data/tool_record.dart';
import '../../core/platform/system_actions.dart';
import 'personal_tools.dart';

/// Explicit user request only. Resolve and pin a public address for every hop;
/// HttpClient still verifies TLS against the original host.
class BookmarkMetadataService {
  BookmarkMetadataService({this.directNetworkAllowed});
  final Future<bool> Function(Uri)? directNetworkAllowed;
  static const _policyChannel = MethodChannel(
    'com.linkstam.links_toolbox/platform',
  );
  static Future<bool> systemAllowsDirect(Uri uri) async {
    // 保守遵守已有代理/PAC策略，不读取、输出或修改代理凭据。
    if (!Platform.isWindows) return false;
    final env = Platform.environment;
    for (final name in [
      'http_proxy',
      'https_proxy',
      'all_proxy',
      'HTTP_PROXY',
      'HTTPS_PROXY',
      'ALL_PROXY',
    ]) {
      if ((env[name] ?? '').trim().isNotEmpty) return false;
    }
    try {
      return await _policyChannel.invokeMethod<bool>('allowsDirectMetadata') ==
          true;
    } catch (_) {
      return false;
    }
  }

  static bool publicAddress(InternetAddress address) {
    final b = address.rawAddress;
    if (b.length == 4) {
      if ({0, 10, 127}.contains(b[0]) ||
          b[0] >= 224 ||
          b[0] == 169 && b[1] == 254 ||
          b[0] == 172 && b[1] >= 16 && b[1] <= 31 ||
          b[0] == 192 && (b[1] == 168 || b[1] == 0) ||
          b[0] == 100 && b[1] >= 64 && b[1] <= 127 ||
          b[0] == 198 && (b[1] == 18 || b[1] == 19)) {
        return false;
      }
      return true;
    }
    // Only globally routed unicast. IPv4-mapped, ULA, link-local, multicast,
    // documentation addresses and all transition prefixes are refused.
    return b.length == 16 &&
        (b[0] & 0xe0) == 0x20 &&
        !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) &&
        !(b[0] == 0x20 && b[1] == 0x02) &&
        !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0 && b[3] == 0);
  }

  static void validateUri(Uri uri) {
    TargetAction('url', uri.toString()).validate();
    final host = uri.host.toLowerCase();
    if (!{80, 443}.contains(uri.port) ||
        !host.contains('.') && InternetAddress.tryParse(host) == null ||
        host.endsWith('.local') ||
        host.endsWith('.localhost') ||
        host.endsWith('.internal')) {
      throw const ToolFailure('网页信息读取仅允许公共HTTP/HTTPS地址与标准端口。');
    }
    final ip = InternetAddress.tryParse(host);
    if (ip != null && !publicAddress(ip)) {
      throw const ToolFailure('拒绝读取本地、私有或保留网络地址。');
    }
  }

  static BookmarkInput parse(String source, Uri uri) {
    final doc = html.parse(source);
    final title = doc.querySelector('title')?.text.trim() ?? '';
    final desc =
        doc.querySelector('meta[name="description"]')?.attributes['content'] ??
        doc
            .querySelector('meta[property="og:description"]')
            ?.attributes['content'] ??
        '';
    return BookmarkInput(
      title.isEmpty ? uri.host : title.substring(0, title.length.clamp(0, 300)),
      uri.toString(),
      description: desc.substring(0, desc.length.clamp(0, 4000)),
      source: 'web-metadata',
    );
  }

  Future<BookmarkInput> fetch(String url) async => parse(
    utf8.decode(
      await readPublic(
        url,
        mimeTypes: const {'text/html', 'application/xhtml+xml'},
      ),
      allowMalformed: true,
    ),
    Uri.parse(url.trim()),
  );

  Future<Uint8List> readPublic(
    String url, {
    Set<String> mimeTypes = const {
      'image/png',
      'image/jpeg',
      'image/webp',
      'image/x-icon',
      'image/vnd.microsoft.icon',
    },
    int byteLimit = 512 * 1024,
    bool sameOriginOnly = false,
  }) async {
    var uri = Uri.parse(url.trim());
    try {
      for (var hop = 0; hop <= 3; hop++) {
        validateUri(uri);
        if (!await (directNetworkAllowed ?? systemAllowsDirect)(uri)) {
          throw const ToolFailure(
            '当前系统使用代理/PAC，或无法确认网络策略；请手动填写，或用系统浏览器访问。未绕过现有设置。',
          );
        }
        final addresses = await InternetAddress.lookup(uri.host)
            .timeout(const Duration(seconds: 4));
        if (addresses.isEmpty || addresses.any((ip) => !publicAddress(ip))) {
          throw const ToolFailure('网址解析到受限地址，未发送网页请求。');
        }
        final pinned = addresses.first,
            client = HttpClient()
              ..connectionTimeout = const Duration(seconds: 5)
              ..findProxy = (_) => 'DIRECT';
        final deadline = Timer(
          const Duration(seconds: 20),
          () => client.close(force: true),
        );
        client.connectionFactory = (target, proxyHost, proxyPort) {
          if (target.host != uri.host || proxyHost != null) {
            throw const ToolFailure('连接目标变化，已停止。');
          }
          return Socket.startConnect(pinned, target.port);
        };
        try {
          final request = await client
              .getUrl(uri)
              .timeout(const Duration(seconds: 6));
          request.followRedirects = false;
          request.headers.set(
            HttpHeaders.userAgentHeader,
            'KADO-Desk/2.3 Metadata',
          );
          final response = await request.close().timeout(
            const Duration(seconds: 8),
          );
          if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            if (location == null || hop == 3) {
              throw const ToolFailure('网页重定向过多或缺少目标。');
            }
            final next = uri.resolve(location);
            if (sameOriginOnly && next.origin != Uri.parse(url.trim()).origin) {
              throw const ToolFailure('图标跳转到其他站点，未发送跨站请求；可选择自定义图标。');
            }
            uri = next;
            continue;
          }
          if (response.statusCode != 200 ||
              !mimeTypes.contains(response.headers.contentType?.mimeType)) {
            throw const ToolFailure('网页不可访问或不是HTML，仍可手动收藏原地址。');
          }
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in response.timeout(
            const Duration(seconds: 8),
          )) {
            bytes.add(chunk);
            if (bytes.length > byteLimit) {
              throw const ToolFailure('网页信息超过512KB，已停止读取。');
            }
          }
          return bytes.takeBytes();
        } finally {
          deadline.cancel();
          client.close(force: true);
        }
      }
      throw const ToolFailure('网页重定向过多。');
    } on ToolFailure {
      rethrow;
    } catch (_) {
      throw const ToolFailure('网页信息读取失败，可继续手动收藏原地址。');
    }
  }
}
