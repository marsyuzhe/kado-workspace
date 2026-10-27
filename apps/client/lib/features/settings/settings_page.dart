import 'package:go_router/go_router.dart';

import '../../shared/record_ui.dart';
import '../../app/brand_config.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/providers.dart';
import '../../app/version.dart';
import '../../core/logging/app_log.dart';
import '../../core/platform/capability_service.dart';
import '../../shared/page_frame.dart';
import '../hub/hub_settings.dart';
import 'backup_settings.dart';
import '../../app/data_providers.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _themeBusy = false, _secureBusy = false, _backupBusy = false;
  String _secureStatus = '尚未验证 · 点击后仅读写并清除一个随机测试键';
  String? _backupPath;
  void _message(String value) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));

  Future<void> _theme(ThemeMode mode) async {
    setState(() => _themeBusy = true);
    try {
      await ref.read(settingsProvider.notifier).setTheme(mode);
    } catch (error) {
      AppLog.record(AppEvent.settingsWriteFailed, error);
      if (mounted) _message('主题保存失败，请检查本地存储。');
    } finally {
      if (mounted) setState(() => _themeBusy = false);
    }
  }

  Future<void> _verifySecureStorage() async {
    setState(() => _secureBusy = true);
    try {
      final result = await ref
          .read(capabilityProvider)
          .requestPermission(Capability.secureStorage);
      if (mounted) {
        setState(
          () => _secureStatus = result == PermissionState.granted
              ? '本机验证通过 · 已读回测试值并删除测试键'
              : '此平台尚不支持；暂不保存凭据。',
        );
      }
    } catch (error) {
      AppLog.record(AppEvent.secureStoreFailed, error);
      if (mounted) setState(() => _secureStatus = '验证失败 · 请检查本机凭据服务，暂不保存凭据。');
    } finally {
      if (mounted) setState(() => _secureBusy = false);
    }
  }

  Future<void> _backup() async {
    setState(() => _backupBusy = true);
    try {
      final directory = await ref.read(appDirectoryProvider.future);
      final file = File(
        p.join(
          directory.path,
          'backups',
          'links-${DateTime.now().microsecondsSinceEpoch}.sqlite',
        ),
      );
      await ref.read(settingsRepositoryProvider).backup(file);
      if (mounted) {
        setState(() => _backupPath = file.path);
        _message('数据库快照已创建。此快照仍在本机，请另行保存到独立介质。');
      }
    } catch (error) {
      AppLog.record(AppEvent.backupFailed, error);
      if (mounted) _message('快照创建失败，原数据库没有被替换。');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return PageFrame(
      eyebrow: 'PREFERENCES',
      title: '让工作台适合你',
      description: '设置保存在本机。当前不连接任何云服务，也不申请额外系统权限。',
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.extension_outlined),
            title: const Text('模块管理'),
            subtitle: const Text('核心工具、可选扩展、旧版入口与排序'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/modules'),
          ),
        ),
        const SizedBox(height: 16),
        const HubSettings(),
        const SizedBox(height: 16),
        const BackupSettings(),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('外观', style: Theme.of(context).textTheme.titleMedium),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('紧凑密度'),
                  subtitle: const Text(
                    'Comfortable / Compact · 统一列表、卡片、表格与侧栏间距',
                  ),
                  value: settings.compact,
                  onChanged: (v) => runUi(
                    context,
                    () => ref.read(settingsProvider.notifier).setDensity(v),
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<ThemeMode>(
                  key: ValueKey(settings.themeMode),
                  initialValue: settings.themeMode,
                  decoration: const InputDecoration(labelText: '主题'),
                  items: const [
                    DropdownMenuItem(value: ThemeMode.dark, child: Text('深色')),
                    DropdownMenuItem(value: ThemeMode.light, child: Text('浅色')),
                    DropdownMenuItem(
                      value: ThemeMode.system,
                      child: Text('跟随系统'),
                    ),
                  ],
                  onChanged: _themeBusy
                      ? null
                      : (mode) {
                          if (mode != null) _theme(mode);
                        },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('隐私与安全', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                const Text(
                  'API Key 与 SSH 凭据将使用系统安全存储，不写入普通数据库。用于AI服务和SSH认证；本机备份不包含这些凭据。',
                  style: TextStyle(height: 1.8),
                ),
                const SizedBox(height: 12),
                Text(_secureStatus, key: const ValueKey('secure-status')),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _secureBusy ? null : _verifySecureStorage,
                  icon: const Icon(Icons.verified_user_outlined, size: 18),
                  label: Text(_secureBusy ? '正在验证…' : '验证本机安全存储'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('数据库诊断快照', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                const Text(
                  'SQLite · Schema v3\n同步未配置，数据仅在本机。此诊断快照只含数据库。完整备份与附件恢复请使用上方入口。',
                  style: TextStyle(height: 1.8),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _backupBusy ? null : _backup,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: Text(_backupBusy ? '正在创建…' : '创建数据库快照'),
                ),
                if (_backupPath != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SelectableText('快照位置：$_backupPath'),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('关于', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                const Text(
                  '${AppBrandConfig.displayName}  $appVersion\n${AppBrandConfig.credit}\nWindows / Android · 本地优先',
                  style: TextStyle(height: 1.8),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => showLicensePage(
                    context: context,
                    applicationName: AppBrandConfig.displayName,
                    applicationVersion: appVersion,
                    applicationLegalese: AppBrandConfig.legal,
                  ),
                  child: const Text('开源依赖许可'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
