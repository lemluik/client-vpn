import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Хранилище идентификатора: читает и пишет одно значение.
///
/// Порт нужен, чтобы в испытаниях подменить защищённое хранилище заглушкой —
/// плагин в тестовой среде не поднимается.
abstract class IdStorage {
  Future<String?> read();
  Future<void> write(String value);
}

/// Защищённое хранилище устройства (Keychain / Keystore / DPAPI).
class SecureIdStorage implements IdStorage {
  const SecureIdStorage([this._storage = const FlutterSecureStorage()]);

  static const String _key = 'device_id';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
}

/// Идентификатор устройства для защиты от повторных пробных ключей.
///
/// Это случайный UUID, а не аппаратный номер (IMEI / Android ID): клиент не
/// раскрывает железо и остаётся универсальным. Значение создаётся один раз и
/// переживает перезапуск приложения. Сервер подписывает его своим секретом
/// (§5.1) — на стороне клиента секретов нет, поэтому здесь только генерация.
class DeviceId {
  DeviceId({IdStorage? storage, Random? random})
    : _storage = storage ?? const SecureIdStorage(),
      _random = random ?? Random.secure();

  final IdStorage _storage;
  final Random _random;

  /// Текущий идентификатор: читает сохранённый или создаёт и сохраняет новый.
  Future<String> get() async {
    final existing = await _storage.read();
    if (existing != null && existing.isNotEmpty) return existing;
    final created = generate();
    await _storage.write(created);
    return created;
  }

  /// Случайный UUID версии 4 (RFC 4122).
  String generate() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // версия 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // вариант RFC 4122
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final s = bytes.map(hex).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-'
        '${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }
}
