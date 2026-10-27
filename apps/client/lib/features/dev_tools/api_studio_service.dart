import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/security/credential_store.dart';

const apiMethods = {'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'};
final sensitiveApiKey = RegExp(
  r'authorization|cookie|password|token|secret|api[-_]?key',
  caseSensitive: false,
);

class ApiRequestSpec {
  const ApiRequestSpec({
    required this.url,
    this.method = 'GET',
    this.headers = const {},
    this.query = const {},
    this.body = '',
    this.bodyType = 'text',
    this.timeoutSeconds = 15,
  });
  final String url, method, body, bodyType;
  final Map<String, String> headers, query;
  final int timeoutSeconds;
  Map<String, dynamic> toJson() => {
    'url': url,
    'method': method,
    'headers': headers,
    'query': query,
    'body': body,
    'bodyType': bodyType,
    'timeoutSeconds': timeoutSeconds,
  };
  factory ApiRequestSpec.fromJson(Map<String, dynamic> json) {
    Map<String, String> map(String key) {
      final raw = json[key] ?? <String, String>{};
      if (raw is! Map ||
          raw.length > 100 ||
          raw.entries.any((e) => e.key is! String || e.value is! String)) {
        throw const ToolFailure('Headers / Query 必须是字符串对象，最多100项。');
      }
      return Map<String, String>.from(raw);
    }

    final spec = ApiRequestSpec(
      url: json['url'] as String,
      method: json['method'] as String? ?? 'GET',
      body: json['body'] as String? ?? '',
      bodyType: json['bodyType'] as String? ?? 'text',
      headers: map('headers'),
      query: map('query'),
      timeoutSeconds: json['timeoutSeconds'] as int? ?? 15,
    );
    spec.validate();
    return spec;
  }
  void validate() {
    if (!apiMethods.contains(method) ||
        url.length > 8192 ||
        body.length > 2 * 1024 * 1024 ||
        !{'text', 'json', 'form'}.contains(bodyType) ||
        timeoutSeconds < 1 ||
        timeoutSeconds > 120 ||
        headers.length > 100 ||
        query.length > 100 ||
        headers.entries.any(
          (e) =>
              e.key.contains(RegExp(r'[\r\n]')) ||
              e.value.contains(RegExp(r'[\r\n]')),
        )) {
      throw const ToolFailure('请求配置超过限制，或包含无效方法/Headers。');
    }
  }
}

class ApiResult {
  const ApiResult(
    this.status,
    this.elapsedMs,
    this.headers,
    this.body,
    this.size,
  );
  final int status, elapsedMs, size;
  final Map<String, List<String>> headers;
  final String body;
  String get contentType => headers['content-type']?.join('; ') ?? '';
}

/// Explicit UI requests may address localhost/LAN. Never shared with metadata
/// fetchers or Agent tools. Redirects, logs and automatic retries are disabled.
class ApiStudioService {
  ApiStudioService(this.store, this.credentials);
  final RecordStore store;
  final CredentialStore credentials;
  static final variable = RegExp(r'\{\{([A-Za-z0-9_.:-]+)\}\}');
  Future<String> resolve(
    String text,
    Map<String, String> variables, [
    int depth = 0,
  ]) async {
    if (depth > 4) throw const ToolFailure('变量引用循环或层数过多。');
    var result = '', end = 0;
    for (final match in variable.allMatches(text)) {
      result += text.substring(end, match.start);
      final key = match[1]!;
      final value = key.startsWith('secret:')
          ? await credentials.read('dev.api.${key.substring(7)}')
          : variables[key];
      if (value == null) throw ToolFailure('变量 $key 尚未配置。');
      result += key.startsWith('secret:')
          ? value
          : await resolve(value, variables, depth + 1);
      if (result.length > 2 * 1024 * 1024) {
        throw const ToolFailure('变量展开超过2MiB。');
      }
      end = match.end;
    }
    return result + text.substring(end);
  }

  Future<ApiResult> send(
    ApiRequestSpec spec, {
    Map<String, String> variables = const {},
    CancelToken? cancelToken,
  }) async {
    spec.validate();
    final token = cancelToken ?? CancelToken(), dio = Dio();
    final watch = Stopwatch()..start();
    final timer = Timer(
      Duration(seconds: spec.timeoutSeconds),
      () => token.cancel('timeout'),
    );
    try {
      final uri = Uri.tryParse(await resolve(spec.url, variables));
      if (uri == null ||
          !{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment) {
        throw const ToolFailure('请输入HTTP(S)地址；凭据通过Headers或安全变量设置。');
      }
      final headers = <String, String>{}, query = <String, String>{};
      for (final e in spec.headers.entries) {
        headers[e.key] = await resolve(e.value, variables);
      }
      for (final e in spec.query.entries) {
        query[e.key] = await resolve(e.value, variables);
      }
      final body = await resolve(spec.body, variables);
      Object? data = body.isEmpty ? null : body;
      if (spec.bodyType == 'json' && body.isNotEmpty) {
        data = jsonDecode(body);
        headers['Content-Type'] = 'application/json';
      }
      if (spec.bodyType == 'form' && body.isNotEmpty) {
        final fields = jsonDecode(body);
        if (fields is! Map<String, dynamic> ||
            fields.values.any((v) => v is! String)) {
          throw const ToolFailure('Form Body 使用字符串对象JSON。');
        }
        data = fields;
        headers['Content-Type'] = 'application/x-www-form-urlencoded';
      }
      if (token.isCancelled) throw const ToolFailure('请求已取消。');
      final timeout = Duration(seconds: spec.timeoutSeconds);
      final response = await dio.request<ResponseBody>(
        uri.toString(),
        data: data,
        queryParameters: query,
        cancelToken: token,
        options: Options(
          method: spec.method,
          headers: headers,
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          receiveTimeout: timeout,
          sendTimeout: timeout,
        ),
      );
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.data!.stream) {
        if (token.isCancelled) throw const ToolFailure('请求已取消或超时。');
        if (bytes.length + chunk.length > 8 * 1024 * 1024) {
          token.cancel();
          throw const ToolFailure('响应超过8MiB，已中止读取。');
        }
        bytes.add(chunk);
      }
      if (token.isCancelled) throw const ToolFailure('请求已取消或超时。');
      final size = bytes.length;
      return ApiResult(
        response.statusCode ?? 0,
        watch.elapsedMilliseconds,
        response.headers.map,
        utf8.decode(bytes.takeBytes(), allowMalformed: true),
        size,
      );
    } on DioException catch (e) {
      throw ToolFailure(
        CancelToken.isCancel(e)
            ? '请求已取消或超时。'
            : '请求失败：${e.type.name}。检查地址、证书或连接。',
      );
    } finally {
      timer.cancel();
      dio.close(force: true);
    }
  }

  /// Convert recognizable credentials into secure-store references before save
  /// or export. Exports contain references only; responses are never persisted.
  Future<ApiRequestSpec> protect(ApiRequestSpec spec) async {
    Future<String> secret(String value) async {
      if (value.isEmpty || variable.hasMatch(value)) return value;
      final key = newId();
      await credentials.write('dev.api.$key', value);
      return '{{secret:$key}}';
    }

    final headers = <String, String>{}, query = <String, String>{};
    for (final e in spec.headers.entries) {
      headers[e.key] = sensitiveApiKey.hasMatch(e.key)
          ? await secret(e.value)
          : e.value;
    }
    final uri = Uri.tryParse(spec.url);
    var url = spec.url;
    if (uri != null && uri.hasQuery) {
      final params = <String, dynamic>{};
      for (final e in uri.queryParametersAll.entries) {
        params[e.key] = [
          for (final v in e.value)
            sensitiveApiKey.hasMatch(e.key) ? await secret(v) : v,
        ];
      }
      url = uri.replace(queryParameters: params).toString();
      // Uri escapes braces; resolve can still see placeholders in URL templates.
      url = url.replaceAllMapped(
        RegExp(r'%7B%7Bsecret%3A([a-f0-9-]+)%7D%7D', caseSensitive: false),
        (m) => '{{secret:${m[1]}}}',
      );
    }
    for (final e in spec.query.entries) {
      query[e.key] = sensitiveApiKey.hasMatch(e.key)
          ? await secret(e.value)
          : e.value;
    }
    Future<Object?> protectJson(Object? value, [String key = '']) async {
      if (sensitiveApiKey.hasMatch(key) && value is String) {
        return secret(value);
      }
      if (value is Map) {
        final map = <String, dynamic>{};
        for (final e in value.entries) {
          map[e.key as String] = await protectJson(e.value, e.key as String);
        }
        return map;
      }
      if (value is List) return Future.wait(value.map((v) => protectJson(v)));
      return value;
    }

    final body = spec.bodyType != 'text' && spec.body.trim().isNotEmpty
        ? jsonEncode(await protectJson(jsonDecode(spec.body)))
        : spec.body;
    return ApiRequestSpec(
      url: url,
      method: spec.method,
      headers: headers,
      query: query,
      body: body,
      bodyType: spec.bodyType,
      timeoutSeconds: spec.timeoutSeconds,
    );
  }

  Future<ToolRecord> save(
    String name,
    ApiRequestSpec spec, {
    ToolRecord? existing,
    String collection = '',
    bool favorite = false,
  }) async {
    if (name.trim().isEmpty || name.length > 200) {
      throw const ToolFailure('请求名称无效。');
    }
    spec.validate();
    if (existing != null && existing.kind != 'api_request') {
      throw const ToolFailure('请求记录类型不匹配。');
    }
    final safe = await protect(spec);
    final data = {
      ...safe.toJson(),
      'collection': collection,
      'favorite': favorite,
      'syncAllowed': false,
      'isSensitive': true,
    };
    return existing == null
        ? store.create('api_request', name, data: data)
        : store.save(existing.copyWith(title: name, data: data));
  }
}
