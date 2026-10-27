import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/record_ui.dart';

class HubSettings extends ConsumerStatefulWidget {
  const HubSettings({super.key});
  @override
  ConsumerState<HubSettings> createState() => _HubSettingsState();
}

class _HubSettingsState extends ConsumerState<HubSettings> {
  bool? recent;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    ref.read(hubRepositoryProvider).recentEnabled().then((value) {
      if (mounted) setState(() => recent = value);
    });
  }

  Future<void> configure() async {
    final current = ref.read(hotkeyProvider);
    var key = current.key, mods = current.modifiers, enabled = current.enabled;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Windows全局快捷键'),
          scrollable: true,
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用呼出搜索'),
                  value: enabled,
                  onChanged: (v) => setLocal(() => enabled = v),
                ),
                DropdownButtonFormField<int>(
                  initialValue: key,
                  decoration: const InputDecoration(labelText: '按键'),
                  items: const [
                    DropdownMenuItem(value: 32, child: Text('Space')),
                    DropdownMenuItem(value: 75, child: Text('K')),
                    DropdownMenuItem(value: 123, child: Text('F12')),
                  ],
                  onChanged: (v) => setLocal(() => key = v!),
                ),
                const SizedBox(height: 12),
                for (final entry in {
                  2: 'Ctrl',
                  4: 'Shift',
                  1: 'Alt',
                  8: 'Win',
                }.entries)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.value),
                    value: (mods & entry.key) != 0,
                    onChanged: (value) => setLocal(
                      () => mods = value == true
                          ? mods | entry.key
                          : mods & ~entry.key,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            LTButton(
              label: '应用',
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    setState(() => busy = true);
    await runUi(
      context,
      () => ref.read(hotkeyProvider.notifier).apply(key, mods, enabled),
    );
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final hotkey = ref.watch(hotkeyProvider);
    return LTCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LTSectionHeader('工作台与快捷键'),
          if (recent != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('记录最近打开的项目'),
              value: recent!,
              onChanged: (v) async {
                final result = await runUi(context, () async {
                  await ref.read(hubRepositoryProvider).setRecentEnabled(v);
                  return v;
                });
                if (mounted && result != null) setState(() => recent = result);
              },
            ),
          LTToolbar(
            children: [
              LTButton(
                label: '清空最近记录',
                style: LTButtonStyle.secondary,
                onPressed: () async {
                  if (await ltConfirm(
                        context,
                        title: '清空最近记录？',
                        message: '只清空访问记录，不删除收藏、笔记或文件。',
                      ) &&
                      context.mounted) {
                    await runUi(
                      context,
                      () => ref.read(hubRepositoryProvider).clearRecent(),
                    );
                  }
                },
              ),
              if (Platform.isWindows)
                LTButton(
                  label: '配置全局快捷键',
                  loading: busy,
                  style: LTButtonStyle.secondary,
                  onPressed: configure,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            Platform.isWindows
                ? (hotkey.message.isNotEmpty
                      ? hotkey.message
                      : hotkey.enabled
                      ? '全局快捷键已向系统注册'
                      : '全局快捷键未启用')
                : '此平台使用应用内搜索入口。',
          ),
        ],
      ),
    );
  }
}
