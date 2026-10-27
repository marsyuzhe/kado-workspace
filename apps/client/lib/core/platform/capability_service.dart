import 'package:flutter/foundation.dart';

import '../security/credential_store.dart';

enum Capability {
  localDatabase,
  secureStorage,
  globalHotkey,
  clipboardMonitor,
  fileScan,
  ssh,
}

enum PermissionState { granted, unverified, unsupported }

abstract interface class CapabilityService {
  bool isSupported(Capability capability);
  Future<PermissionState> checkPermission(Capability capability);
  Future<PermissionState> requestPermission(Capability capability);
  Future<void> openSystemSettings(Capability capability);
}

class LocalCapabilityService implements CapabilityService {
  LocalCapabilityService(this.credentials, {TargetPlatform? platform})
    : platform = platform ?? defaultTargetPlatform;
  final CredentialStore credentials;
  final TargetPlatform platform;
  bool _secureStoreVerified = false;

  @override
  bool isSupported(Capability capability) {
    final native =
        !kIsWeb &&
        {
          TargetPlatform.windows,
          TargetPlatform.android,
          TargetPlatform.iOS,
        }.contains(platform);
    if (!native) return false;
    return switch (capability) {
      Capability.globalHotkey ||
      Capability.clipboardMonitor => platform == TargetPlatform.windows,
      _ => true,
    };
  }

  @override
  Future<PermissionState> checkPermission(Capability capability) async {
    if (!isSupported(capability)) return PermissionState.unsupported;
    if (capability == Capability.secureStorage && !_secureStoreVerified) {
      return PermissionState.unverified;
    }
    if (capability != Capability.secureStorage &&
        capability != Capability.localDatabase) {
      return PermissionState.unverified;
    }
    return PermissionState.granted;
  }

  @override
  Future<PermissionState> requestPermission(Capability capability) async {
    if (!isSupported(capability)) return PermissionState.unsupported;
    if (capability == Capability.secureStorage) {
      _secureStoreVerified = false;
      await verifyCredentialStore(credentials);
      _secureStoreVerified = true;
    }
    return checkPermission(capability);
  }

  @override
  Future<void> openSystemSettings(Capability capability) async {
    throw UnsupportedError('当前阶段没有系统设置适配器；请手动打开系统设置。');
  }
}
