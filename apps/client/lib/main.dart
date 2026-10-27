import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'app/data_providers.dart';
import 'core/backup/backup_service.dart';
import 'core/database/app_database.dart';
import 'core/database/settings_repository.dart';
import 'core/logging/app_log.dart';
import 'core/ui/app_theme.dart';

RandomAccessFile? _instanceLock;

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) =>
      AppLog.record(AppEvent.frameworkError, details.exception);
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.record(AppEvent.asynchronousError, error);
    return true;
  };
  AppDatabase? database;
  try {
    const compiledDirectory = String.fromEnvironment('LINKS_DATA_DIR');
    final argumentDirectory = arguments
        .where((a) => a.startsWith('--data-dir='))
        .firstOrNull;
    final overrideDirectory =
        argumentDirectory?.substring(11) ??
        Platform.environment['LINKS_DATA_DIR'] ??
        compiledDirectory;
    final executableDirectory = Directory(
      p.dirname(Platform.resolvedExecutable),
    );
    final portable =
        Platform.isWindows &&
        await File(p.join(executableDirectory.path, 'portable.flag')).exists();
    final baseDirectory = overrideDirectory.isNotEmpty
        ? Directory(overrideDirectory)
        : portable
        ? Directory(p.join(executableDirectory.path, 'user-data'))
        : await getApplicationSupportDirectory();
    final home = LocalDataHome(baseDirectory);
    await baseDirectory.create(recursive: true);
    _instanceLock ??= await File(p.join(baseDirectory.path, '.instance.lock'))
        .open(mode: FileMode.append);
    await _instanceLock!.lock(FileLock.exclusive);
    try {
      await home.applyPending();
    } catch (error) {
      AppLog.record(AppEvent.backupFailed, error);
      final pending = File(p.join(baseDirectory.path, 'pending_restore.json'));
      if (await pending.exists()) {
        await pending.rename(
          p.join(
            baseDirectory.path,
            'failed-restore-${DateTime.now().microsecondsSinceEpoch}.json',
          ),
        );
      }
      await File(p.join(baseDirectory.path, 'restore-status.txt'))
          .writeAsString('恢复未能完成，已保留并继续使用当前有效数据。请重新检查备份。', flush: true);
    }
    final directory = await home.active();
    await directory.create(recursive: true);
    database = AppDatabase.file(
      File(p.join(directory.path, 'links_toolbox.sqlite')),
    );
    await database.initialize();
    final repository = SettingsRepository(database);
    final settings = await repository.load();
    AppLog.record(AppEvent.started);
    runApp(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          initialSettingsProvider.overrideWithValue(settings),
          dataHomeProvider.overrideWith((ref) async => home),
        ],
        child: const LinksToolboxApp(),
      ),
    );
  } catch (error) {
    AppLog.record(AppEvent.initializationFailed, error);
    await database?.close();
    runApp(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: const Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: SelectableText(
                '本地数据初始化失败\n\n原数据库已保留，没有自动删除或重置。\n请检查应用数据目录权限、磁盘空间和备份，再重新启动。',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
