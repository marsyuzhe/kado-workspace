import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../data/tool_record.dart';

class TargetAction {
  const TargetAction(
    this.type,
    this.target, {
    this.moduleId = '',
    this.arguments = const [],
  });
  factory TargetAction.fromJson(Map<String, dynamic> json) => TargetAction(
    json['type'] as String? ?? '',
    json['target'] as String? ?? '',
    moduleId: json['moduleId'] as String? ?? '',
    arguments: (json['arguments'] as List? ?? []).whereType<String>().toList(),
  );
  final String type, target, moduleId;
  final List<String> arguments;
  Map<String, dynamic> toJson() => {
    'type': type,
    'target': target,
    'moduleId': moduleId,
    'arguments': arguments,
  };
  String get key => '$type|$moduleId|$target|${arguments.join('\u0000')}';
  bool get requiresConfirmation => type == 'application' || type == 'file';
  void validate() {
    if (!{
          'module',
          'record',
          'url',
          'file',
          'folder',
          'application',
        }.contains(type) ||
        target.trim().isEmpty) {
      throw const ToolFailure('请选择有效的快捷入口。');
    }
    if (type == 'url') {
      final uri = Uri.tryParse(target);
      if (uri == null ||
          !{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const ToolFailure('网址必须是没有内嵌凭据的HTTP或HTTPS地址。');
      }
    }
    if (arguments.length > 32 ||
        arguments.any((arg) => arg.contains('\u0000')) ||
        arguments.join().length > 8000) {
      throw const ToolFailure('应用参数过长或格式无效。');
    }
    if (type == 'application' && p.extension(target).toLowerCase() != '.exe') {
      throw const ToolFailure('应用入口请选择Windows .exe；参数单独填写。');
    }
  }
}

class NativePlatformAdapter {
  NativePlatformAdapter() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'filesDropped' && call.arguments is List) {
        _fileDrops.add(
          (call.arguments as List).whereType<String>().take(101).toList(),
        );
      }
      if (call.method == 'hotkey') _hotkeys.add(null);
      if (call.method == 'clipboardChanged') _clipboard.add(null);
      if (call.method == 'windowClosing') {
        bool allow = false;
        try {
          allow = await _closeGuard?.call() ?? true;
        } catch (_) {
          allow = false;
        }
        await _channel.invokeMethod<void>(
          allow ? 'completeClose' : 'cancelClose',
        );
      }
    });
  }
  static const _channel = MethodChannel('com.linkstam.links_toolbox/platform');
  final _hotkeys = StreamController<void>.broadcast(),
      _clipboard = StreamController<void>.broadcast();
  final _fileDrops = StreamController<List<String>>.broadcast();
  Stream<List<String>> get fileDrops => _fileDrops.stream;
  Future<bool> listenFileDrops(bool enabled) async {
    if (!windows) return false;
    try {
      return await _channel.invokeMethod<bool>('listenFileDrops', enabled) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<int> fileDropTargetHandle() async =>
      await _channel.invokeMethod<int>('fileDropTargetHandle') ?? 0;
  Stream<void> get hotkeys => _hotkeys.stream;
  Stream<void> get clipboardChanges => _clipboard.stream;
  bool get windows => Platform.isWindows;
  Future<bool> Function()? _closeGuard;

  /// Identifies only this adapter's native window; never infer a target from
  /// whichever unrelated application happens to be in the foreground.
  Future<int> currentWindowHandle() async {
    if (!windows) throw const ToolFailure('当前平台没有Windows窗口。');
    return await _channel.invokeMethod<int>('currentWindowHandle') ?? 0;
  }

  Future<void> setCloseGuard(Future<bool> Function() guard) async {
    _closeGuard = guard;
    if (!windows) return;
    try {
      await _channel.invokeMethod<void>('setCloseGuard', true);
    } on MissingPluginException {
      /* Widget-only runners have no window. */
    }
  }

  Future<void> moveFileExclusive(String source, String target) async {
    if (!windows) {
      // Mobile archive only exposes copies imported into the app-owned directory.
      if (await FileSystemEntity.type(target, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const ToolFailure('目标已存在，禁止覆盖。');
      }
      await File(source).rename(target);
      return;
    }
    try {
      await _channel.invokeMethod<void>('moveFileExclusive', {
        'source': source,
        'target': target,
      });
    } on PlatformException {
      throw const ToolFailure('移动失败：目标已存在、权限不足或跨磁盘。跨磁盘请使用复制。');
    }
  }

  Future<int?> availableDiskBytes(String path) async {
    if (!windows) return null;
    try {
      return await _channel.invokeMethod<int>('availableDiskBytes', path);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      throw const ToolFailure('无法读取输出磁盘剩余空间，请检查目录权限。');
    }
  }

  Future<Map<String, dynamic>> installerMetadata(String path) async {
    if (!windows) {
      return {'signatureStatus': 'not_supported', 'source': '此平台未接入原生安装包属性'};
    }
    try {
      return await _channel.invokeMapMethod<String, dynamic>(
            'installerMetadata',
            path,
          ) ??
          {};
    } on MissingPluginException {
      return {'signatureStatus': 'not_available', 'source': '未加载原生属性通道'};
    } on PlatformException {
      throw const ToolFailure('文件缺失、是链接或原生属性不可读。');
    }
  }

  Future<void> showFileProperties(String path) async {
    if (!windows) throw const ToolFailure('此平台没有Windows文件属性对话框。');
    await _channel.invokeMethod<void>('showFileProperties', path);
  }

  Future<Map<String, dynamic>> systemEnvironmentSummary() async {
    if (!windows) throw const ToolFailure('环境快照仅支持Windows。');
    try {
      return await _channel.invokeMapMethod<String, dynamic>(
            'systemEnvironmentSummary',
          ) ??
          {};
    } on MissingPluginException {
      throw const ToolFailure('当前运行环境没有Windows硬件信息通道。');
    } on PlatformException {
      throw const ToolFailure('无法读取Windows系统信息。');
    }
  }

  Future<void> registerHotkey(int modifiers, int key) async {
    if (!windows) throw const ToolFailure('此平台使用应用内搜索入口。');
    try {
      await _channel.invokeMethod<void>('registerHotkey', {
        'modifiers': modifiers,
        'key': key,
      });
    } on PlatformException {
      throw const ToolFailure('快捷键注册失败，可能与其他应用冲突。请更换组合。');
    } on MissingPluginException {
      throw const ToolFailure('当前运行环境没有原生快捷键通道。');
    }
  }

  Future<void> unregisterHotkey() async {
    if (windows) await _channel.invokeMethod<void>('unregisterHotkey');
  }

  Future<void> startClipboard() async {
    if (!windows) throw const ToolFailure('移动端请使用主动粘贴或手动保存。');
    await _channel.invokeMethod<void>('startClipboard');
  }

  Future<void> stopClipboard() async {
    if (windows) await _channel.invokeMethod<void>('stopClipboard');
  }

  Future<Map<String, dynamic>?> clipboardSnapshot() async {
    if (!windows) {
      final value = await Clipboard.getData(Clipboard.kTextPlain);
      return value?.text == null ? null : {'type': 'text', 'text': value!.text};
    }
    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'clipboardSnapshot',
    );
    return raw;
  }

  Future<void> copyText(String value) =>
      Clipboard.setData(ClipboardData(text: value));
  Future<void> copyImage(Uint8List png) async {
    if (!windows) throw const ToolFailure('当前移动端适配器只支持重新复制文本。图片仍可查看和导出。');
    await _channel.invokeMethod<void>('copyImage', {'bytes': png});
  }

  Future<void> launch(TargetAction action, {bool confirmed = false}) async {
    action.validate();
    if (action.requiresConfirmation && !confirmed) {
      throw const ToolFailure('需要先确认实际目标和参数。');
    }
    if (action.type == 'url') {
      if (!await launchUrl(
        Uri.parse(action.target),
        mode: LaunchMode.externalApplication,
      )) {
        throw const ToolFailure('系统没有成功打开该网址。');
      }
      return;
    }
    if (!windows) throw const ToolFailure('此平台不支持任意启动本地应用或系统文件夹。请通过系统文件选择器操作。');
    if (action.type == 'application') {
      if (!await File(action.target).exists()) {
        throw const ToolFailure('应用文件不存在，请编辑入口。');
      }
      await Process.start(
        action.target,
        action.arguments,
        runInShell: false,
        mode: ProcessStartMode.detached,
      );
      return;
    }
    if (action.type == 'file' || action.type == 'folder') {
      final exists = action.type == 'file'
          ? await File(action.target).exists()
          : await Directory(action.target).exists();
      if (!exists) throw const ToolFailure('目标已经移动或不可访问。');
      if (!await launchUrl(Uri.file(action.target))) {
        throw const ToolFailure('系统没有成功打开目标。');
      }
      return;
    }
    throw const ToolFailure('这个操作应通过应用内导航打开。');
  }

  void dispose() {
    if (windows) {
      unawaited(
        _channel
            .invokeMethod<void>('setCloseGuard', false)
            .catchError((Object _) {}),
      );
    }
    _channel.setMethodCallHandler(null);
    _hotkeys.close();
    _clipboard.close();
    _fileDrops.close();
  }
}
