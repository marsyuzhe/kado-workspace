import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/storage/owned_file_store.dart';
import '../core/backup/backup_service.dart';
import '../features/clipboard/clipboard_service.dart';
import '../features/archive/archive_service.dart';
import '../features/memory/memory_repository.dart';
import '../features/ai_desk/ai_service.dart';
import '../features/server/server_service.dart';
import '../core/security/credential_store.dart';

import '../core/data/record_store.dart';
import '../core/data/tool_record.dart';
import '../core/modules/module_registry.dart';
import '../core/platform/system_actions.dart';
import '../features/hub/hub_repository.dart';
import '../features/hub/search_service.dart';
import 'providers.dart';

final recordStoreProvider = Provider<RecordStore>(
  (ref) => RecordStore(ref.watch(settingsRepositoryProvider).database),
);
final recordByIdProvider = StreamProvider.family<ToolRecord?, String>(
  (ref, id) => ref.watch(recordStoreProvider).watchOne(id),
);
final credentialsProvider = Provider<CredentialStore>(
  (ref) => const SystemCredentialStore(),
);
final serverRepositoryProvider = Provider<ServerRepository>(
  (ref) => ServerRepository(
    ref.watch(recordStoreProvider),
    ref.watch(credentialsProvider),
  ),
);
final serverConnectorProvider = Provider<ServerConnector>(
  (ref) => DartSshConnector(),
);
final aiRepositoryProvider = Provider<AiRepository>(
  (ref) => AiRepository(
    ref.watch(recordStoreProvider),
    ref.watch(credentialsProvider),
  ),
);
final aiMessagesProvider = StreamProvider.family<List<ToolRecord>, String>(
  (ref, id) => ref.watch(aiRepositoryProvider).watchMessages(id),
);
final aiApiProvider = Provider<AiApi>((ref) {
  final api = AiApi();
  ref.onDispose(api.dispose);
  return api;
});
final memoryRepositoryProvider = Provider<MemoryRepository>(
  (ref) => MemoryRepository(
    ref.watch(recordStoreProvider),
    () => ref.read(ownedFilesProvider.future),
  ),
);
final noteSummariesProvider = StreamProvider<List<NoteSummary>>(
  (ref) => ref.watch(memoryRepositoryProvider).watchSummaries(),
);
final noteSearchProvider = StreamProvider.family<List<NoteSummary>, String>(
  (ref, query) =>
      ref.watch(memoryRepositoryProvider).watchSummaries(searchQuery: query),
);

class NavigationSaveGuard {
  String? owner;
  Future<bool> Function()? callback;
  Future<bool> before(Uri target) async {
    if (target.path == '/modules/memory' &&
        target.queryParameters['id'] == owner) {
      return true;
    }
    return await callback?.call() ?? true;
  }

  void clear(String id) {
    if (owner == id) {
      owner = null;
      callback = null;
    }
  }
}

final navigationSaveGuardProvider = Provider((ref) => NavigationSaveGuard());
final archiveServiceProvider = Provider<ArchiveService>(
  (ref) => ArchiveService(
    ref.watch(recordStoreProvider),
    ref.watch(nativePlatformProvider),
  ),
);
final appDirectoryProvider = FutureProvider<Directory>(
  (ref) async =>
      ref.watch(settingsRepositoryProvider).database.location?.parent ??
      await getApplicationSupportDirectory(),
);
final dataHomeProvider = FutureProvider<LocalDataHome>(
  (ref) async => LocalDataHome(await ref.watch(appDirectoryProvider.future)),
);
final backupServiceProvider = FutureProvider<BackupService>(
  (ref) async => BackupService(
    ref.watch(settingsRepositoryProvider).database,
    await ref.watch(ownedFilesProvider.future),
    await ref.watch(dataHomeProvider.future),
  ),
);
final ownedFilesProvider = FutureProvider<OwnedFileStore>(
  (ref) async => OwnedFileStore(await ref.watch(appDirectoryProvider.future)),
);
final clipboardRepositoryProvider = Provider<ClipboardRepository>(
  (ref) => ClipboardRepository(
    ref.watch(recordStoreProvider),
    () => ref.read(ownedFilesProvider.future),
  ),
);

class ClipboardUiState {
  const ClipboardUiState({
    this.config = const ClipConfig(),
    this.listening = false,
    this.loading = true,
    this.error,
  });
  final ClipConfig config;
  final bool listening, loading;
  final String? error;
}

class ClipboardController extends Notifier<ClipboardUiState> {
  late ClipboardService service;
  bool initialized = false;
  @override
  ClipboardUiState build() {
    service = ClipboardService(
      ref.watch(clipboardRepositoryProvider),
      ref.watch(nativePlatformProvider),
      onError: (message) {
        if (ref.mounted) {
          state = ClipboardUiState(
            config: service.config,
            listening: service.listening,
            loading: false,
            error: message,
          );
        }
      },
    );
    final current = service;
    ref.onDispose(() => unawaited(current.dispose()));
    return const ClipboardUiState();
  }

  Future<void> initialize() async {
    if (initialized) return;
    initialized = true;
    try {
      await service.initialize();
      if (ref.mounted) {
        state = ClipboardUiState(
          config: service.config,
          listening: service.listening,
          loading: false,
        );
      }
    } catch (_) {
      if (ref.mounted) {
        state = ClipboardUiState(
          config: service.config,
          listening: false,
          loading: false,
          error: '剪贴板初始化失败，监听未运行。请检查设置并重新启用。',
        );
      }
    }
  }

  Future<void> configure(ClipConfig value) async {
    await service.configure(value);
    if (ref.mounted) {
      state = ClipboardUiState(
        config: service.config,
        listening: service.listening,
        loading: false,
      );
    }
  }
}

final clipboardProvider =
    NotifierProvider<ClipboardController, ClipboardUiState>(
      ClipboardController.new,
    );
final hubRepositoryProvider = Provider<HubRepository>(
  (ref) => HubRepository(ref.watch(recordStoreProvider)),
);
final favoritesProvider = StreamProvider(
  (ref) => ref.watch(hubRepositoryProvider).watchFavorites(),
);
final recentActionsProvider = StreamProvider(
  (ref) => ref.watch(hubRepositoryProvider).watchRecent(),
);
final recordsProvider = StreamProvider.family<List<ToolRecord>, String>(
  (ref, kind) => ref.watch(recordStoreProvider).watch(kind),
);
final recentNotesProvider = StreamProvider(
  (ref) => ref.watch(recordStoreProvider).watch('note', limit: 5),
);
final nativePlatformProvider = Provider<NativePlatformAdapter>((ref) {
  final value = NativePlatformAdapter();
  ref.onDispose(value.dispose);
  return value;
});
final searchServiceProvider = Provider<SearchService>((ref) {
  final settings = ref.watch(settingsProvider);
  return SearchService([
    ModuleSearchProvider(
      (m) => settings.moduleEnabled(m.moduleId, defaultEnabled: m.enabled),
    ),
    LocalSearchProvider(
      ref.watch(recordStoreProvider),
      isEnabled: (id) => settings.moduleEnabled(
        id,
        defaultEnabled: moduleById(id)?.enabled ?? false,
      ),
    ),
  ]);
});

class HotkeyStatus {
  const HotkeyStatus({
    this.key = 32,
    this.modifiers = 6,
    this.enabled = false,
    this.message = '',
    this.supported = true,
  });
  final int key, modifiers;
  final bool enabled, supported;
  final String message;
}

class HotkeyController extends Notifier<HotkeyStatus> {
  Future<void>? _initialization;
  @override
  HotkeyStatus build() => HotkeyStatus(supported: Platform.isWindows);
  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    if (!Platform.isWindows) return;
    try {
      final raw = await ref.read(recordStoreProvider).setting('hub.hotkey');
      final data = raw == null
          ? {'key': 32, 'modifiers': 6, 'enabled': true}
          : jsonDecode(raw) as Map;
      if (!ref.mounted) return;
      await _apply(
        data['key'] as int,
        data['modifiers'] as int,
        data['enabled'] == true,
      );
    } catch (error) {
      state = HotkeyStatus(
        message: error is ToolFailure ? error.message : '快捷键不可用，请在设置中重新配置。',
      );
    }
  }

  Future<void> apply(int key, int modifiers, bool enabled) async {
    await initialize();
    if (!ref.mounted) return;
    await _apply(key, modifiers, enabled);
  }

  Future<void> _apply(int key, int modifiers, bool enabled) async {
    if (!Platform.isWindows) throw const ToolFailure('此平台请使用应用内搜索。');
    final native = ref.read(nativePlatformProvider),
        store = ref.read(recordStoreProvider);
    final old = state;
    if (enabled) {
      await native.registerHotkey(modifiers, key);
    } else {
      await native.unregisterHotkey();
    }
    try {
      await store.setSetting(
        'hub.hotkey',
        jsonEncode({'key': key, 'modifiers': modifiers, 'enabled': enabled}),
      );
    } catch (_) {
      if (old.enabled) {
        await native.registerHotkey(old.modifiers, old.key);
      } else {
        await native.unregisterHotkey();
      }
      rethrow;
    }
    state = HotkeyStatus(key: key, modifiers: modifiers, enabled: enabled);
  }
}

final hotkeyProvider = NotifierProvider<HotkeyController, HotkeyStatus>(
  HotkeyController.new,
);

/// Authorized, in-memory transfers; receivers never auto-send to a provider.
class DraftTransfer extends Notifier<String> {
  @override
  String build() => '';
  void setDraft(String value) {
    state = value;
  }

  String consume() {
    final value = state;
    state = '';
    return value;
  }
}

final aiDraftProvider = NotifierProvider<DraftTransfer, String>(
  DraftTransfer.new,
);
