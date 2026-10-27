import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/modules/module_registry.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/core/network/api_client.dart';
import 'package:links_toolbox/core/platform/capability_service.dart';
import 'package:links_toolbox/core/security/credential_store.dart';
import 'package:links_toolbox/core/sync/sync_service.dart';

class MemoryCredentials implements CredentialStore {
  final values = <String, String>{};
  bool failRead = false;
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('injected read failure');
    return values[key];
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  test(
    'registry defaults apply until the user saves an explicit module choice',
    () {
      const defaults = LocalSettings();
      expect(
        defaults.moduleEnabled('optional', defaultEnabled: false),
        isFalse,
      );
      const settings = LocalSettings(enabled: {'optional': true});
      expect(settings.moduleEnabled('optional', defaultEnabled: false), isTrue);
    },
  );
  test('registry IDs and routes are unique, all six modules have metadata', () {
    expect(
      modules.map((m) => m.moduleId),
      containsAll([
        'hub',
        'archive',
        'clipboard',
        'ai_desk',
        'server',
        'memory',
      ]),
    );
    expect(modules.map((m) => m.moduleId).toSet().length, modules.length);
    expect(modules.map((m) => m.route).toSet().length, modules.length);
    for (final module in modules) {
      expect(module.supportedPlatforms, isNotEmpty);
      if ({
        'hub',
        'archive',
        'clipboard',
        'ai_desk',
        'server',
        'memory',
      }.contains(module.moduleId)) {
        expect(module.supportedPlatforms.length, 3);
      }
      expect(module.version, isNotEmpty);
    }
    expect(moduleById('renamer')!.supportedPlatforms, {AppPlatform.windows});
  });
  test(
    'offline sync reports unconfigured and cannot pretend to succeed',
    () async {
      const service = UnconfiguredSyncService();
      expect(
        (await service.status()).availability,
        SyncAvailability.notConfigured,
      );
      await expectLater(service.synchronize(), throwsStateError);
    },
  );
  test('secure storage is unverified until actual roundtrip; probe leaves user keys alone', () async {
    final credentials = MemoryCredentials()
      ..values['existing-user-key'] = 'keep';
    final service = LocalCapabilityService(
      credentials,
      platform: TargetPlatform.windows,
    );
    expect(
      await service.checkPermission(Capability.secureStorage),
      PermissionState.unverified,
    );
    expect(
      await service.requestPermission(Capability.secureStorage),
      PermissionState.granted,
    );
    expect(credentials.values, {'existing-user-key': 'keep'});
    expect(service.isSupported(Capability.globalHotkey), isTrue);
    expect(
      await service.checkPermission(Capability.globalHotkey),
      PermissionState.unverified,
    );
    expect(
      await service.requestPermission(Capability.fileScan),
      PermissionState.unverified,
    );
    await expectLater(
      service.openSystemSettings(Capability.ssh),
      throwsUnsupportedError,
    );
  });
  test(
    'failed secure probe cleans up and does not mark storage verified',
    () async {
      final credentials = MemoryCredentials()..failRead = true;
      final service = LocalCapabilityService(
        credentials,
        platform: TargetPlatform.android,
      );
      await expectLater(
        service.requestPermission(Capability.secureStorage),
        throwsStateError,
      );
      expect(credentials.values, isEmpty);
      expect(
        await service.checkPermission(Capability.secureStorage),
        PermissionState.unverified,
      );
    },
  );
  test(
    'network client rejects unsafe origin and endpoint before sending requests',
    () async {
      for (final uri in [
        'http://example.com',
        'https://user:pass@example.com',
        'https://example.com?token=secret',
      ]) {
        expect(() => DioApiClient(Uri.parse(uri)), throwsArgumentError);
      }
      final client = DioApiClient(Uri.parse('https://example.com'));
      for (final path in [
        'https://other.example/api/v1/x',
        '//other.example/api/v1/x',
        '/api/v1/../admin',
        '/admin',
      ]) {
        await expectLater(client.get(path), throwsArgumentError);
      }
      client.close();
    },
  );
}
