import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/platform/system_actions.dart';
import '../../core/storage/owned_file_store.dart';

class ClipConfig {
  const ClipConfig({
    this.enabled = false,
    this.paused = false,
    this.privateMode = false,
    this.maxItems = 200,
    this.retentionDays = 30,
  });
  factory ClipConfig.fromJson(Map<String, dynamic> json) => ClipConfig(
    enabled: json['enabled'] == true,
    paused: json['paused'] == true,
    privateMode: json['privateMode'] == true,
    maxItems: (json['maxItems'] as num? ?? 200).toInt().clamp(1, 500),
    retentionDays: (json['retentionDays'] as num? ?? 30).toInt().clamp(1, 365),
  );
  static const maxTextBytes = 64 * 1024,
      maxImageBytes = 2 * 1024 * 1024,
      maxPixels = 8 * 1024 * 1024;
  final bool enabled, paused, privateMode;
  final int maxItems, retentionDays;
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'paused': paused,
    'privateMode': privateMode,
    'maxItems': maxItems,
    'retentionDays': retentionDays,
  };
  ClipConfig copyWith({
    bool? enabled,
    bool? paused,
    bool? privateMode,
    int? maxItems,
    int? retentionDays,
  }) => ClipConfig(
    enabled: enabled ?? this.enabled,
    paused: paused ?? this.paused,
    privateMode: privateMode ?? this.privateMode,
    maxItems: maxItems ?? this.maxItems,
    retentionDays: retentionDays ?? this.retentionDays,
  );
}

class ClipboardRepository {
  ClipboardRepository(this.store, this.files);
  final RecordStore store;
  final Future<OwnedFileStore> Function() files;
  Future<List<ToolRecord>> history() => store.list('clipboard', limit: 1000);
  Future<ClipConfig> loadConfig() async {
    final raw = await store.setting('clipboard.config');
    return raw == null
        ? const ClipConfig()
        : ClipConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveConfig(ClipConfig config) =>
      store.setSetting('clipboard.config', jsonEncode(config.toJson()));
  Future<ToolRecord?> byHash(String hash) =>
      store.find('clipboard', 'contentHash', hash);
  Future<ToolRecord> pin(ToolRecord record, bool value) =>
      store.save(record.copyWith(data: {...record.data, 'pinned': value}));
  Future<ToolRecord> setPrivate(ToolRecord record, bool value) => store.save(
    record.copyWith(
      data: {...record.data, 'isSensitive': value, 'syncAllowed': false},
    ),
  );
  Future<ToolRecord> setSyncAllowed(ToolRecord record, bool value) async {
    if (value && record.flag('isSensitive')) {
      throw const ToolFailure('私密记录禁止自动上传或授权同步。');
    }
    return store.save(
      record.copyWith(data: {...record.data, 'syncAllowed': value}),
    );
  }

  Future<void> remove(ToolRecord record) async {
    final attachment = record.text('attachment');
    await store.delete(record);
    if (attachment.isNotEmpty) await (await files()).remove(attachment);
  }

  Future<void> clear() async {
    for (final record in await history()) {
      await remove(record);
    }
  }

  Future<void> cleanup(ClipConfig config) async {
    final rows = await history();
    final cutoff = DateTime.now().toUtc().subtract(
      Duration(days: config.retentionDays),
    );
    for (final r in rows.where(
      (r) => !r.flag('pinned') && r.createdAt.isBefore(cutoff),
    )) {
      await remove(r);
    }
    final remaining = await history();
    var excess = remaining.length - config.maxItems;
    for (final r in remaining.reversed.where((r) => !r.flag('pinned'))) {
      if (excess-- <= 0) break;
      await remove(r);
    }
  }

  Future<ToolRecord> snippet(
    String title,
    String body, {
    String category = '提示词',
    List<String> tags = const [],
    ToolRecord? existing,
  }) async {
    if (title.trim().isEmpty || body.trim().isEmpty) {
      throw const ToolFailure('标题和内容不能为空。');
    }
    if (utf8.encode(body).length > ClipConfig.maxTextBytes) {
      throw const ToolFailure('文本片段不能超过64KB。');
    }
    final data = {
      'category': category,
      'tags': tags,
      'pinned': existing?.flag('pinned') ?? false,
      'syncAllowed': false,
    };
    return existing == null
        ? store.create('prompt', title, body: body, data: data)
        : store.save(existing.copyWith(title: title, body: body, data: data));
  }
}

class ClipboardService {
  ClipboardService(this.repository, this.native, {this.onError});
  final ClipboardRepository repository;
  final NativePlatformAdapter native;
  final void Function(String)? onError;
  ClipConfig config = const ClipConfig();
  bool listening = false, _disposed = false;
  StreamSubscription<void>? _events;
  Timer? _cleanup;
  Future<void> _queue = Future.value(), _captureQueue = Future.value();
  String? _ignoreHash;
  DateTime? _ignoreUntil;
  Future<void> initialize() async {
    config = await repository.loadConfig();
    await repository.cleanup(config);
    if (config.enabled &&
        native.windows &&
        !config.paused &&
        !config.privateMode) {
      await _start();
    }
  }

  Future<void> _start() async {
    _events ??= native.clipboardChanges.listen((_) => _onChange());
    await native.startClipboard();
    listening = true;
    _cleanup ??= Timer.periodic(
      const Duration(minutes: 30),
      (_) => _enqueue(() => repository.cleanup(config)),
    );
  }

  Future<void> configure(ClipConfig value) async {
    if (value.maxItems < 1 ||
        value.maxItems > 500 ||
        value.retentionDays < 1 ||
        value.retentionDays > 365) {
      throw const ToolFailure('历史上限应为1–500，保存期限应为1–365天。');
    }
    if ((await repository.history()).where((r) => r.flag('pinned')).length >
        value.maxItems) {
      throw const ToolFailure('收藏数量超过新上限，请先取消部分收藏。');
    }
    final want = value.enabled && !value.paused && !value.privateMode;
    if (want && !native.windows) {
      throw const ToolFailure('移动端不支持后台全局监听，请使用主动粘贴。');
    }
    final old = config;
    final wasListening = listening;
    if (want && !listening) {
      await _start();
    } else if (!want && listening) {
      await native.stopClipboard();
      listening = false;
      await _queue;
      await _captureQueue;
    }
    try {
      await repository.saveConfig(value);
      config = value;
    } catch (_) {
      config = old;
      if (wasListening && !listening) {
        await _start();
      } else if (!wasListening && listening) {
        await native.stopClipboard();
        listening = false;
      }
      rethrow;
    }
    await repository.cleanup(config);
  }

  void _enqueue(Future<void> Function() action) {
    _queue = _queue
        .then((_) async {
          if (!_disposed) await action();
        })
        .catchError((Object error) {
          if (!_disposed) {
            onError?.call(
              error is ToolFailure ? error.message : '剪贴板读取失败，请暂停后重新启用监听。',
            );
          }
        });
  }

  void _onChange() {
    if (!listening || config.paused || config.privateMode || _disposed) return;
    _enqueue(() async {
      Map<String, dynamic>? snapshot;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          snapshot = await native.clipboardSnapshot();
          break;
        } on PlatformException catch (error) {
          if (error.code != 'clipboard_busy' || attempt == 2) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      if (snapshot != null &&
          listening &&
          !config.paused &&
          !config.privateMode) {
        await capture(snapshot, automatic: true);
      }
    });
  }

  Future<void> drain() => _queue;
  static String textHash(String text) =>
      sha256.convert(utf8.encode('text:$text')).toString();
  Future<ToolRecord?> capture(
    Map<String, dynamic> snapshot, {
    bool automatic = false,
    String? forcedType,
  }) async {
    final result = Completer<ToolRecord?>();
    _captureQueue = _captureQueue.then((_) async {
      try {
        result.complete(
          await _capture(
            snapshot,
            automatic: automatic,
            forcedType: forcedType,
          ),
        );
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<ToolRecord?> _capture(
    Map<String, dynamic> snapshot, {
    bool automatic = false,
    String? forcedType,
  }) async {
    if (automatic && (!listening || config.paused || config.privateMode)) {
      return null;
    }
    final type = snapshot['type'];
    String body = '', hash, contentType;
    Uint8List? image;
    if (type == 'text') {
      if (snapshot['text'] is! String) throw const ToolFailure('剪贴板文本类型不正确。');
      body = snapshot['text'] as String;
      if (body.trim().isEmpty) return null;
      if (utf8.encode(body).length > ClipConfig.maxTextBytes) {
        throw const ToolFailure('文本超过64KB上限，没有保存。');
      }
      hash = textHash(body);
      final uri = Uri.tryParse(body.trim());
      contentType =
          forcedType ??
          (uri != null &&
                  {'http', 'https'}.contains(uri.scheme) &&
                  uri.host.isNotEmpty
              ? 'url'
              : 'text');
      if (!{'text', 'url', 'code', 'template'}.contains(contentType)) {
        throw const ToolFailure('未知的文本类型。');
      }
      if (contentType == 'url' &&
          (uri == null ||
              !{'http', 'https'}.contains(uri.scheme) ||
              uri.host.isEmpty)) {
        throw const ToolFailure('URL必须是有效的HTTP或HTTPS地址。');
      }
    } else if (type == 'image') {
      final value = snapshot['bytes'];
      if (value is! Uint8List) throw const ToolFailure('图片数据类型不正确。');
      image = value;
      _validatePng(image);
      hash = sha256.convert(image).toString();
      contentType = 'image';
    } else {
      throw const ToolFailure('当前只记录文本、URL、代码、模板和PNG图片。');
    }
    if (automatic &&
        hash == _ignoreHash &&
        DateTime.now().isBefore(_ignoreUntil ?? DateTime(0))) {
      return null;
    }
    final existing = await repository.byHash(hash);
    if (existing != null) {
      return repository.store.save(
        existing.copyWith(
          data: {
            ...existing.data,
            'lastSeenAt': DateTime.now().toUtc().toIso8601String(),
            if (config.privateMode) 'isSensitive': true,
            if (config.privateMode) 'syncAllowed': false,
            'contentType': ?forcedType,
          },
        ),
      );
    }
    final count = await repository.history();
    if (count.where((r) => r.flag('pinned')).length >= config.maxItems) {
      throw const ToolFailure('收藏已达到历史数量上限，请清理或提高上限。');
    }
    String? attachment;
    if (image != null) {
      attachment = await (await repository.files()).write(
        'clipboard',
        image,
        extension: 'png',
      );
    }
    late ToolRecord result;
    try {
      result = await repository.store.create(
        'clipboard',
        image == null
            ? String.fromCharCodes(body.split('\n').first.runes.take(80))
            : '剪贴板图片',
        body: body,
        data: {
          'contentType': contentType,
          'contentHash': hash,
          'attachment': attachment ?? '',
          'byteLength': image?.length ?? utf8.encode(body).length,
          'sourceName': snapshot['sourceName'] is String
              ? snapshot['sourceName']
              : '',
          'pinned': false,
          'tags': <String>[],
          'isSensitive': config.privateMode,
          'syncAllowed': false,
        },
      );
    } catch (_) {
      if (attachment != null) {
        await (await repository.files()).remove(attachment);
      }
      rethrow;
    }
    try {
      await repository.cleanup(config);
    } catch (_) {
      onError?.call('内容已保存，但自动清理失败。请检查存储权限。');
    }
    return result;
  }

  static void _validatePng(Uint8List bytes) {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 33 || bytes.length > ClipConfig.maxImageBytes) {
      throw const ToolFailure('图片必须是有效PNG且不超过2MB。');
    }
    for (var i = 0; i < 8; i++) {
      if (bytes[i] != signature[i]) throw const ToolFailure('图片不是PNG格式。');
    }
    final view = ByteData.sublistView(bytes);
    final width = view.getUint32(16), height = view.getUint32(20);
    if (width == 0 ||
        height == 0 ||
        width > 4096 ||
        height > 4096 ||
        width * height > ClipConfig.maxPixels) {
      throw const ToolFailure('图片边长不得超过4096，像素总数不得超过838万。');
    }
  }

  Future<ToolRecord?> paste() async {
    final value = await native.clipboardSnapshot();
    if (value == null) throw const ToolFailure('系统剪贴板中没有可保存的文本或图片。');
    return capture(value);
  }

  Future<void> copy(ToolRecord record) async {
    _ignoreHash = record.text('contentHash');
    _ignoreUntil = DateTime.now().add(const Duration(seconds: 2));
    if (record.text('contentType') == 'image') {
      final file = (await repository.files()).resolve(
        record.text('attachment'),
      );
      final bytes = await file.readAsBytes();
      _validatePng(bytes);
      if (sha256.convert(bytes).toString() != record.text('contentHash')) {
        throw const ToolFailure('图片文件完整性检查失败。');
      }
      await native.copyImage(bytes);
    } else {
      if (record.kind == 'prompt') _ignoreHash = textHash(record.body);
      await native.copyText(record.body);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _cleanup?.cancel();
    await _events?.cancel();
    if (listening) {
      try {
        await native.stopClipboard();
      } catch (_) {}
    }
    listening = false;
  }
}
