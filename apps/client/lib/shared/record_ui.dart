import 'package:flutter/material.dart';

import '../core/data/tool_record.dart';
import '../core/logging/app_log.dart';
import '../core/ui/lt_components.dart';

Future<T?> runUi<T>(
  BuildContext context,
  Future<T> Function() operation, {
  String? success,
}) async {
  try {
    final result = await operation();
    if (context.mounted && success != null) ltMessage(context, success);
    return result;
  } catch (error) {
    AppLog.record(AppEvent.asynchronousError, error);
    if (context.mounted) {
      ltMessage(
        context,
        error is ToolFailure ? error.message : '操作未能完成。请检查权限、连接或磁盘空间后重试。',
      );
    }
    return null;
  }
}

String readableBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String readableTime(DateTime time) {
  final t = time.toLocal();
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
