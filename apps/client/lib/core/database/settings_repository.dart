import '../modules/module_registry.dart' show coreModuleIds;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/material.dart';

import 'app_database.dart';

class LocalSettings {
  const LocalSettings({
    this.themeMode = ThemeMode.dark,
    this.enabled = const {},
    this.compact = false,
  });

  final ThemeMode themeMode;
  final bool compact;
  final Map<String, bool> enabled;

  bool moduleEnabled(String id, {bool defaultEnabled = true}) =>
      coreModuleIds.contains(id) || (enabled[id] ?? defaultEnabled);
}

class SettingsRepository {
  SettingsRepository(this.database);
  final AppDatabase database;

  Future<LocalSettings> load() async {
    final row = await (database.select(
      database.appSettings,
    )..where((t) => t.key.equals('themeMode'))).getSingleOrNull();
    final mode = ThemeMode.values.where((m) => m.name == row?.value);
    final density = await (database.select(
      database.appSettings,
    )..where((t) => t.key.equals('displayDensity'))).getSingleOrNull();
    final modules = await database.select(database.modulePreferences).get();
    return LocalSettings(
      compact: density?.value == 'compact',
      themeMode: mode.isEmpty ? ThemeMode.dark : mode.first,
      enabled: Map.unmodifiable({
        for (final m in modules) m.moduleId: m.enabled,
      }),
    );
  }

  Future<LocalSettings> setTheme(ThemeMode mode) async {
    await database
        .into(database.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(key: 'themeMode', value: mode.name),
        );
    return load();
  }

  Future<LocalSettings> setModuleEnabled(String id, bool enabled) async {
    await database
        .into(database.modulePreferences)
        .insertOnConflictUpdate(
          ModulePreferencesCompanion.insert(
            moduleId: id,
            enabled: Value(enabled),
          ),
        );
    return load();
  }

  Future<LocalSettings> setDensity(bool compact) async {
    await database
        .into(database.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: 'displayDensity',
            value: compact ? 'compact' : 'comfortable',
          ),
        );
    return load();
  }

  Future<void> backup(File destination) => database.backupTo(destination);
}
