import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class CredentialStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

class SystemCredentialStore implements CredentialStore {
  const SystemCredentialStore();
  static const _storage = FlutterSecureStorage();
  static const _prefix = 'com.linkstam.links_toolbox.';

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: '$_prefix$key', value: value);
  @override
  Future<String?> read(String key) => _storage.read(key: '$_prefix$key');
  @override
  Future<void> delete(String key) => _storage.delete(key: '$_prefix$key');
}

/// Touches only a randomly named probe key, and deletes it even after failure.
Future<void> verifyCredentialStore(CredentialStore store) async {
  final random = Random.secure();
  final nonce = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final key = 'probe.$nonce';
  try {
    await store.write(key, nonce);
    if (await store.read(key) != nonce) {
      throw StateError('Secure store verification failed');
    }
  } finally {
    await store.delete(key);
  }
}
