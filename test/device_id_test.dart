import 'dart:math';

import 'package:client_vpn/services/device_id.dart';
import 'package:flutter_test/flutter_test.dart';

/// Хранилище идентификатора в памяти: плагин защищённого хранилища в тесте не
/// поднимается.
class _FakeIdStorage implements IdStorage {
  _FakeIdStorage([this.value]);

  String? value;
  int writes = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String newValue) async {
    value = newValue;
    writes++;
  }
}

final uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  group('DeviceId.generate', () {
    test('даёт UUID версии 4 в формате RFC 4122', () {
      final id = DeviceId(random: Random(7));

      expect(id.generate(), matches(uuidV4));
    });

    test('два вызова дают разные значения', () {
      final id = DeviceId(random: Random(7));

      expect(id.generate(), isNot(id.generate()));
    });
  });

  group('DeviceId.get', () {
    test('пустое хранилище — создаёт, сохраняет и возвращает UUID', () async {
      final storage = _FakeIdStorage();
      final id = DeviceId(storage: storage, random: Random(11));

      final value = await id.get();

      expect(value, matches(uuidV4));
      expect(storage.writes, 1);
      expect(storage.value, value);
    });

    test(
      'повторный вызов возвращает то же значение и не перезаписывает',
      () async {
        final storage = _FakeIdStorage();
        final id = DeviceId(storage: storage, random: Random(11));

        final first = await id.get();
        final second = await id.get();

        expect(second, first);
        expect(storage.writes, 1);
      },
    );

    test('сохранённый ранее идентификатор переживает перезапуск', () async {
      final storage = _FakeIdStorage('persisted-device-id');
      final id = DeviceId(storage: storage, random: Random(11));

      expect(await id.get(), 'persisted-device-id');
      expect(storage.writes, 0);
    });
  });
}
