import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage.dart';

/// Identifier storage: reads and writes a single value.
///
/// The port lets tests replace the secure storage with a stub: the plugin does
/// not start in the test environment.
abstract class IdStorage {
  Future<String?> read();
  Future<void> write(String value);
}

/// The device's secure storage (Keychain / Keystore / DPAPI).
class SecureIdStorage implements IdStorage {
  const SecureIdStorage([this._storage = appSecureStorage]);

  static const String _key = 'device_id';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
}

/// Device identifier that protects against repeated trial keys.
///
/// It is a random UUID, not a hardware number (IMEI / Android ID): the client
/// does not disclose the hardware and stays universal. The value is created
/// once and survives app restarts. The server signs it with its own secret
/// (§5.1); the client holds no secrets, so this is generation only.
class DeviceId {
  DeviceId({IdStorage? storage, Random? random})
    : _storage = storage ?? const SecureIdStorage(),
      _random = random ?? Random.secure();

  final IdStorage _storage;
  final Random _random;

  /// The current identifier: reads the saved one or creates and saves a new one.
  Future<String> get() async {
    final existing = await _storage.read();
    if (existing != null && existing.isNotEmpty) return existing;
    final created = generate();
    await _storage.write(created);
    return created;
  }

  /// A random version 4 UUID (RFC 4122).
  String generate() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final s = bytes.map(hex).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-'
        '${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }
}
