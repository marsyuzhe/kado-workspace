import '../web_library/web_models.dart';
import '../web_library/web_providers.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/data_providers.dart';
import '../../app/providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/modules/module_registry.dart';
import '../../core/platform/system_actions.dart';
import '../../core/ui/lt_components.dart';

void contextGoSearch(BuildContext context) => context.go('/search');
void contextGoSettings(BuildContext context) => context.go('/settings');

Future<void> openTarget(
  BuildContext context,
  WidgetRef ref,
  TargetAction action, {
  String? title,
}) async {
  action.validate();
  final hub = ref.read(hubRepositoryProvider),
      web = ref.read(webRepositoryProvider);
  var source = action.moduleId;
  if (action.type == 'module' || action.type == 'record') {
    source = action.type == 'module' ? action.target : action.moduleId;
    final module = moduleById(source);
    if (module == null ||
        !ref
            .read(settingsProvider)
            .moduleEnabled(source, defaultEnabled: module.enabled)) {
      throw const ToolFailure('模块未启用，请先在模块管理中启用。');
    }
    final location = action.type == 'module'
        ? module.route
        : Uri(
            path: module.route,
            queryParameters: {'id': action.target},
          ).toString();
    if (context.mounted) context.go(location);
    title ??= module.displayName;
  } else {
    if (action.requiresConfirmation) {
      if (!context.mounted) return;
      final confirmed = await ltConfirm(
        context,
        title: '打开此目标？',
        message:
            '目标：${action.target}${action.arguments.isEmpty ? '' : '\n参数数组：${action.arguments}'}',
        confirmLabel: '打开',
      );
      if (!confirmed) return;
    }
    await ref.read(nativePlatformProvider).launch(action, confirmed: true);
    source = 'hub';
  }
  if (action.type == 'url') {
    final row = await hub.store.find('favorite', 'targetKey', action.key);
    if (row != null && row.data['webDataVersion'] != null) {
      await web.recordOpened(WebsiteBookmark(row));
      return;
    }
  }
  await hub.recordOpened(title ?? action.target, source, action);
}
