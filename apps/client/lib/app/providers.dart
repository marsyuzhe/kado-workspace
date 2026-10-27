import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/database/settings_repository.dart';
import '../core/platform/capability_service.dart';
import '../core/security/credential_store.dart';
import '../core/sync/sync_service.dart';

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => throw StateError('Repository must be initialized'),
);
final initialSettingsProvider = Provider<LocalSettings>(
  (ref) => const LocalSettings(),
);
final capabilityProvider = Provider<CapabilityService>(
  (ref) => LocalCapabilityService(const SystemCredentialStore()),
);
final syncServiceProvider = Provider<SyncService>(
  (ref) => const UnconfiguredSyncService(),
);

class SettingsController extends Notifier<LocalSettings> {
  @override
  LocalSettings build() => ref.watch(initialSettingsProvider);

  Future<void> setTheme(ThemeMode mode) async {
    state = await ref.read(settingsRepositoryProvider).setTheme(mode);
  }

  Future<void> setDensity(bool compact) async {
    state = await ref.read(settingsRepositoryProvider).setDensity(compact);
  }

  Future<void> setModule(String id, bool enabled) async {
    state = await ref
        .read(settingsRepositoryProvider)
        .setModuleEnabled(id, enabled);
  }
}

final settingsProvider = NotifierProvider<SettingsController, LocalSettings>(
  SettingsController.new,
);
