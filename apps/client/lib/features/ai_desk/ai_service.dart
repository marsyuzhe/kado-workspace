import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/security/credential_store.dart';

class AiFailure extends ToolFailure {
  const AiFailure(this.category, super.message);
  final String category;
}

class AiConfig {
  const AiConfig({
    required this.name,
    required this.baseUrl,
    required this.model,
    this.official = false,
    this.timeout = 60,
    this.temperature,
    this.maxTokens = 2048,
    this.includeUsage = true,
    this.currency = 'USD',
    this.inputPrice,
    this.outputPrice,
  });
  factory AiConfig.fromRecord(ToolRecord record) => AiConfig(
    name: record.title,
    baseUrl: record.text('baseUrl'),
    model: record.text('model'),
    official: record.flag('official'),
    timeout: record.number('timeout', 60),
    temperature: (record.data['temperature'] as num?)?.toDouble(),
    maxTokens: record.number('maxTokens', 2048),
    includeUsage: record.data['includeUsage'] != false,
    currency: record.text('currency', 'USD'),
    inputPrice: (record.data['inputPrice'] as num?)?.toDouble(),
    outputPrice: (record.data['outputPrice'] as num?)?.toDouble(),
  );
  final String name, baseUrl, model, currency;
  final bool official, includeUsage;
  final int timeout, maxTokens;
  final double? temperature, inputPrice, outputPrice;
  void validate() {
    final uri = Uri.tryParse(baseUrl);
    if (name.trim().isEmpty || model.trim().isEmpty) {
      throw const ToolFailure('Provider名称和模型ID不能为空。');
    }
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !(uri.scheme == 'https' ||
            uri.scheme == 'http' &&
                {'localhost', '127.0.0.1', '::1'}.contains(uri.host))) {
      throw const ToolFailure('Base URL应为HTTPS地址；本机localhost允许HTTP，不允许内嵌凭据。');
    }
    if (official &&
        baseUrl.replaceAll(RegExp(r'/+$'), '') != 'https://api.openai.com/v1') {
      throw const ToolFailure('官方Provider仅使用https://api.openai.com/v1。');
    }
    if (timeout < 10 || timeout > 180 || maxTokens < 1 || maxTokens > 32768) {
      throw const ToolFailure('超时10–180秒，输出上限1–32768。');
    }
    if (temperature != null &&
        (temperature! < 0 || temperature! > 2 || !temperature!.isFinite)) {
      throw const ToolFailure('temperature应为0–2或留空。');
    }
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
      throw const ToolFailure('币种请使用USD、CNY等三位代码。');
    }
    if ([
      inputPrice,
      outputPrice,
    ].any((v) => v != null && (v < 0 || !v.isFinite))) {
      throw const ToolFailure('每百万Token单价应为非负有限数字。');
    }
  }

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl.replaceAll(RegExp(r'/+$'), ''),
    'model': model,
    'official': official,
    'timeout': timeout,
    'temperature': temperature,
    'maxTokens': maxTokens,
    'includeUsage': includeUsage,
    'currency': currency,
    'inputPrice': inputPrice,
    'outputPrice': outputPrice,
    'priceUnit': 'per_1m_tokens',
    'priceUpdatedAt': DateTime.now().toUtc().toIso8601String(),
  };
}

class AiRepository {
  AiRepository(this.store, this.credentials);
  final RecordStore store;
  final CredentialStore credentials;
  Future<ToolRecord> configure(
    AiConfig config, {
    String? key,
    ToolRecord? existing,
  }) async {
    config.validate();
    final oldRef = existing?.text('credentialRef') ?? '';
    if (existing != null &&
        Uri.parse(existing.text('baseUrl')).origin !=
            Uri.parse(config.baseUrl).origin &&
        (key == null || key.trim().isEmpty)) {
      throw const ToolFailure('更改服务地址后请重新输入Key，避免把旧密钥发送给新服务。');
    }
    var reference = oldRef;
    final changed = key != null && key.trim().isNotEmpty;
    if (!changed && oldRef.isEmpty) {
      throw const ToolFailure('请填写API Key；兼容本机服务可填写服务要求的占位Key。');
    }
    if (changed) {
      reference = 'ai.${newId()}';
      await credentials.write(reference, key.trim());
    }
    late ToolRecord result;
    try {
      final metadata = {...config.toJson(), 'credentialRef': reference};
      result = existing == null
          ? await store.create('ai_provider', config.name, data: metadata)
          : await store.save(
              existing.copyWith(title: config.name, data: metadata),
            );
    } catch (_) {
      if (changed) await credentials.delete(reference);
      rethrow;
    }
    if (changed && oldRef.isNotEmpty) await credentials.delete(oldRef);
    return result;
  }

  Future<String> key(ToolRecord provider) async {
    final key = await credentials.read(provider.text('credentialRef'));
    if (key == null || key.isEmpty) {
      throw const ToolFailure('此设备没有该Provider的API Key，请重新配置。备份不含密钥。');
    }
    return key;
  }

  Future<void> removeProvider(ToolRecord provider) async {
    await store.delete(provider);
    if (provider.text('credentialRef').isNotEmpty) {
      await credentials.delete(provider.text('credentialRef'));
    }
  }

  Future<ToolRecord> newConversation(ToolRecord provider) => store.create(
    'ai_conversation',
    '新对话',
    data: {'providerId': provider.id, 'model': provider.text('model')},
  );
  Future<List<ToolRecord>> messages(String conversationId) async {
    return (await _messagesQuery(conversationId).get())
        .map((r) => ToolRecord.fromRow(store.db.localRecords.map(r.data)))
        .toList();
  }

  Selectable<QueryRow> _messagesQuery(String id) => store.db.customSelect(
    "SELECT * FROM local_records WHERE kind='ai_message' AND deleted_at IS NULL AND json_extract(data,'\u0024.conversationId')=? ORDER BY CAST(json_extract(data,'\u0024.ordinal') AS INTEGER) LIMIT 501",
    variables: [Variable(id)],
    readsFrom: {store.db.localRecords},
  );
  Stream<List<ToolRecord>> watchMessages(String id) =>
      _messagesQuery(id).watch().map(
        (rows) => rows
            .map((r) => ToolRecord.fromRow(store.db.localRecords.map(r.data)))
            .toList(),
      );

  Future<ToolRecord> addMessage(
    String conversationId,
    String role,
    String body, {
    String status = 'complete',
    Map<String, dynamic> extra = const {},
  }) => store.transaction(() async {
    final all = await messages(conversationId);
    return store.create(
      'ai_message',
      role,
      body: body,
      data: {
        'conversationId': conversationId,
        'role': role,
        'status': status,
        'ordinal': all.isEmpty ? 0 : all.last.number('ordinal') + 1,
        ...extra,
      },
    );
  });
  Future<void> clearConversation(
    ToolRecord conversation, {
    bool remove = false,
  }) async {
    await store.transaction(() async {
      for (final row in await messages(conversation.id)) {
        await store.delete(row);
      }
      if (remove) await store.delete(conversation);
    });
  }
}

class AiDelta {
  const AiDelta({this.text = '', this.usage, this.done = false});
  final String text;
  final Map<String, dynamic>? usage;
  final bool done;
}

AiFailure classifyAiError(int? status, {String? code}) {
  if (status == 401 || status == 403) {
    return const AiFailure('authentication', '认证失败，请检查Key、权限与Base URL。');
  }
  if (status == 404) return const AiFailure('model', '接口或模型不存在，请检查模型ID及/v1路径。');
  if (status == 429 &&
      {'insufficient_quota', 'billing_hard_limit_reached'}.contains(code)) {
    return const AiFailure('quota', '服务商返回配额或账单不足，请检查API账户。');
  }
  if (status == 429) return const AiFailure('rate_limit', '请求过于频繁，请稍后手动重试。');
  if (status != null && status >= 500) {
    return const AiFailure('server', '服务端暂时不可用，请稍后重试。');
  }
  return const AiFailure(
    'request',
    '服务商拒绝请求，请检查模型支持的参数；可清空temperature或关闭Usage兼容选项。',
  );
}

class AiApi {
  AiApi({Dio? dio})
    : dio =
          dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)));
  final Dio dio;
  Options _options(String key, AiConfig config, ResponseType type) => Options(
    headers: {
      'Authorization': 'Bearer $key',
      'Content-Type': 'application/json',
    },
    responseType: type,
    sendTimeout: Duration(seconds: config.timeout),
    receiveTimeout: Duration(seconds: config.timeout),
    followRedirects: false,
    validateStatus: (status) => status != null && status >= 200 && status < 300,
  );
  String _url(AiConfig config, String endpoint) =>
      '${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/$endpoint';
  Future<AiFailure> _dioFailure(DioException e) async {
    if (CancelToken.isCancel(e)) return const AiFailure('cancelled', '已停止生成。');
    if ({
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
    }.contains(e.type)) {
      return const AiFailure('timeout', '请求超时，请检查网络或提高超时设置。');
    }
    if (e.response != null) {
      String? code;
      dynamic body = e.response?.data;
      if (body is ResponseBody) {
        try {
          final bytes = <int>[];
          await for (final chunk in body.stream.timeout(
            const Duration(seconds: 3),
          )) {
            bytes.addAll(chunk);
            if (bytes.length > 65536) break;
          }
          body = jsonDecode(utf8.decode(bytes));
        } catch (_) {
          body = null;
        }
      }
      if (body is Map && body['error'] is Map) {
        code = body['error']['code'] as String?;
      }
      return classifyAiError(e.response?.statusCode, code: code);
    }
    return const AiFailure('network', '无法连接服务，请检查网络、证书和Base URL。');
  }

  Future<List<String>> models(AiConfig config, String key) async {
    config.validate();
    try {
      final response = await dio
          .get<dynamic>(
            _url(config, 'models'),
            options: _options(key, config, ResponseType.json),
          )
          .timeout(Duration(seconds: config.timeout));
      final data = response.data;
      if (data is! Map || data['data'] is! List) {
        throw const AiFailure('protocol', '服务未返回兼容模型列表，可手动填写模型ID。');
      }
      return (data['data'] as List)
          .whereType<Map>()
          .map((e) => e['id'])
          .whereType<String>()
          .toSet()
          .toList()
        ..sort();
    } on DioException catch (e) {
      throw await _dioFailure(e);
    } on TimeoutException {
      throw const AiFailure('timeout', '读取模型列表超时。');
    }
  }

  Stream<AiDelta> stream(
    AiConfig config,
    String key,
    List<Map<String, String>> messages,
    CancelToken cancel,
  ) async* {
    config.validate();
    try {
      final response = await dio
          .post<ResponseBody>(
            _url(config, 'chat/completions'),
            data: {
              'model': config.model,
              'messages': messages,
              'stream': true,
              if (config.includeUsage)
                'stream_options': {'include_usage': true},
              if (config.temperature != null) 'temperature': config.temperature,
              (config.official ? 'max_completion_tokens' : 'max_tokens'):
                  config.maxTokens,
            },
            options: _options(key, config, ResponseType.stream),
            cancelToken: cancel,
          )
          .timeout(Duration(seconds: config.timeout));
      final body = response.data;
      if (body == null) throw const AiFailure('protocol', '服务未返回响应流。');
      var wireBytes = 0;
      final lines = body.stream
          .map<List<int>>((e) {
            wireBytes += e.length;
            if (wireBytes > 4 * 1024 * 1024) {
              cancel.cancel();
              throw const AiFailure('limit', '本次响应超过4MB传输上限。');
            }
            return e;
          })
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(Duration(seconds: config.timeout));
      var data = <String>[], buffered = 0;
      bool done = false;
      await for (final line in lines) {
        if (cancel.isCancelled) throw const AiFailure('cancelled', '已停止生成。');
        if (line.isEmpty) {
          if (data.isEmpty) continue;
          final payload = data.join('\n');
          data = [];
          buffered = 0;
          if (payload == '[DONE]') {
            done = true;
            yield const AiDelta(done: true);
            break;
          }
          dynamic decoded;
          try {
            decoded = jsonDecode(payload);
          } catch (_) {
            throw const AiFailure('protocol', '流式数据不是有效JSON。');
          }
          if (decoded is! Map) throw const AiFailure('protocol', '流式响应格式不兼容。');
          if (decoded['error'] is Map) {
            throw classifyAiError(
              400,
              code: decoded['error']['code'] as String?,
            );
          }
          final choices = decoded['choices'];
          String text = '';
          if (choices is List && choices.isNotEmpty && choices.first is Map) {
            final delta = choices.first['delta'];
            if (delta is Map && delta['content'] is String) {
              text = delta['content'] as String;
            }
          }
          yield AiDelta(
            text: text,
            usage: decoded['usage'] is Map
                ? Map<String, dynamic>.from(decoded['usage'] as Map)
                : null,
          );
        } else if (line.startsWith('data:')) {
          final value = line.substring(5).trimLeft();
          buffered += value.length;
          if (buffered > 1024 * 1024) {
            throw const AiFailure('protocol', '单个响应事件超过1MB，已停止。');
          }
          data.add(value);
        }
      }
      if (!done) throw const AiFailure('incomplete', '响应提前中断，已保留部分内容；可手动重试。');
    } on DioException catch (e) {
      throw await _dioFailure(e);
    } on TimeoutException {
      cancel.cancel();
      throw const AiFailure('timeout', '响应流等待超时，已停止本次请求。');
    }
  }

  void dispose() => dio.close(force: true);
}

class AiChatRunner {
  AiChatRunner(this.repository, this.api, {this.onUpdate});
  final AiRepository repository;
  final AiApi api;
  final void Function(String, bool, String?)? onUpdate;
  CancelToken? _token;
  Future<void>? _completion;
  bool get busy => _token != null;
  Future<void> send(
    ToolRecord conversation,
    ToolRecord provider,
    String prompt, {
    bool retry = false,
  }) {
    if (busy) throw const ToolFailure('当前对话正在生成，请先停止。');
    final token = CancelToken();
    _token = token;
    final future = _run(conversation, provider, prompt, token, retry: retry);
    _completion = future;
    return future;
  }

  Future<void> _run(
    ToolRecord conversation,
    ToolRecord provider,
    String prompt,
    CancelToken token, {
    required bool retry,
  }) async {
    ToolRecord? assistant;
    String output = '';
    String? error;
    var status = 'complete';
    Map<String, dynamic>? usage;
    final config = AiConfig.fromRecord(provider);
    try {
      if (prompt.trim().isEmpty && !retry) throw const ToolFailure('请输入内容。');
      final key = await repository.key(provider);
      if (token.isCancelled) throw const AiFailure('cancelled', '已停止生成。');
      var history = await repository.messages(conversation.id);
      if (history.length >= 500) throw const ToolFailure('单个对话最多500条消息，请新建对话。');
      if (!retry) {
        await repository.addMessage(conversation.id, 'user', prompt);
        history = await repository.messages(conversation.id);
      }
      final context = history
          .where(
            (r) => r.text('role') == 'user' || r.text('status') == 'complete',
          )
          .map((r) => {'role': r.text('role'), 'content': r.body})
          .toList();
      if (utf8.encode(context.map((m) => m['content']).join()).length >
          256 * 1024) {
        throw const ToolFailure('发送上下文超过256KB，请新建对话或减少内容。');
      }
      assistant = await repository.addMessage(
        conversation.id,
        'assistant',
        '',
        status: 'generating',
        extra: {'providerId': provider.id, 'model': config.model},
      );
      onUpdate?.call('', true, null);
      await for (final delta in api.stream(config, key, context, token)) {
        if (token.isCancelled) break;
        output += delta.text;
        if (utf8.encode(output).length > 1024 * 1024) {
          token.cancel();
          throw const AiFailure('limit', '回复超过1MB，已停止。');
        }
        usage = delta.usage ?? usage;
        onUpdate?.call(output, true, null);
      }
      if (token.isCancelled) status = 'cancelled';
      usage ??= {
        'prompt_tokens':
            (context.fold<int>(0, (n, m) => n + m['content']!.runes.length) / 4)
                .ceil(),
        'completion_tokens': (output.runes.length / 4).ceil(),
        'source': 'estimated',
      };
    } catch (e) {
      final cancelled =
          token.isCancelled || e is AiFailure && e.category == 'cancelled';
      status = cancelled ? 'cancelled' : 'failed';
      error = e is ToolFailure
          ? e.message
          : cancelled
          ? '已停止生成。'
          : '请求失败，请检查配置后重试。';
    } finally {
      try {
        if (assistant != null) {
          final estimate = usage?['source'] == 'estimated';
          final input = (usage?['prompt_tokens'] as num?)?.toDouble(),
              out = (usage?['completion_tokens'] as num?)?.toDouble();
          final cost =
              input != null &&
                  out != null &&
                  config.inputPrice != null &&
                  config.outputPrice != null
              ? (input * config.inputPrice! + out * config.outputPrice!) /
                    1000000
              : null;
          await repository.store.save(
            assistant.copyWith(
              body: output,
              data: {
                ...assistant.data,
                'status': status,
                'usage': usage,
                'usageSource': usage == null
                    ? 'unavailable'
                    : estimate
                    ? 'estimated'
                    : 'server',
                'cost': cost,
                'currency': config.currency,
                'error': error ?? '',
                'inputPricePer1M': config.inputPrice,
                'outputPricePer1M': config.outputPrice,
              },
            ),
          );
        }
      } catch (_) {
        error = '回复已生成，但历史记录保存失败。请先复制当前回答。';
      }
      _token = null;
      onUpdate?.call(output, false, error);
    }
  }

  Future<void> stop() async {
    final work = _completion;
    _token?.cancel();
    await work;
  }
}
