import 'package:client_vpn/profile_config.dart';
import 'package:client_vpn/routing_presets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('пресеты', () {
    test('выключенный пресет не даёт правил', () {
      expect(offPreset.isOff, isTrue);
      expect(offPreset.rules, isEmpty);
    });

    test('«Россия напрямую» ведёт адреса и домены РФ в направление напрямую',
        () {
      final rules = ruPreset.rules;

      expect(rules, hasLength(3));
      for (final rule in rules) {
        expect(rule['outboundTag'], directTag);
      }
      expect((rules[0]['ip'] as List).contains('geoip:ru'), isTrue);
      expect(
        (rules[1]['domain'] as List).every((code) =>
            code is String && code.startsWith('geosite:')),
        isTrue,
      );
      expect((rules[2]['ip'] as List), ['geoip:private']);
    });

    test('кодов пресета нет в списках других пресетов повторно', () {
      final keys = routingPresets.map((preset) => preset.key).toList();

      expect(keys.toSet().length, keys.length);
    });
  });

  group('выбор по языку устройства', () {
    test('русская локаль получает пресет России', () {
      expect(defaultPresetFor('ru').key, 'ru');
      expect(defaultPresetFor('RU').key, 'ru');
      expect(defaultPresetFor('ru_BY').key, 'ru');
    });

    test('прочая локаль и пустой язык — без пресета', () {
      expect(defaultPresetFor('en').isOff, isTrue);
      expect(defaultPresetFor('').isOff, isTrue);
      expect(defaultPresetFor('de').isOff, isTrue);
    });

    test('неизвестный ключ хранения читается как выключенный пресет', () {
      expect(presetByKey('kz').isOff, isTrue);
      expect(presetByKey(null).isOff, isTrue);
    });
  });

  group('PresetStore', () {
    test('без сохранённого выбора — пресет по языку', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      expect(PresetStore(prefs).load('ru').key, 'ru');
      expect(PresetStore(prefs).load('en').isOff, isTrue);
    });

    test('сохранённый выбор важнее языка устройства', () async {
      SharedPreferences.setMockInitialValues({'routing.preset.v1': 'ru'});
      final prefs = await SharedPreferences.getInstance();

      expect(PresetStore(prefs).load('en').key, 'ru');
    });

    test('сохранение и чтение дают один и тот же пресет', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = PresetStore(prefs);

      await store.save('ru');

      expect(store.load('en').key, 'ru');
      expect(prefs.getString('routing.preset.v1'), 'ru');
    });
  });
}
