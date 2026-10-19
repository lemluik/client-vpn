import 'package:client_vpn/services/service_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ассет-бандл для проверки загрузки: отдаёт заданную строку или «падает»,
/// имитируя отсутствие файла в открытой сборке.
class _FakeBundle extends AssetBundle {
  _FakeBundle(this._value, {this.absent = false});

  final String? _value;
  final bool absent;

  @override
  Future<ByteData> load(String key) async => ByteData(0);

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    if (absent || _value == null) throw Exception('Unable to load asset: $key');
    return _value;
  }
}

void main() {
  group('ServiceConfig.fromJson', () {
    test('имя и точка контроля берутся из формата deployment.json', () {
      final config = ServiceConfig.fromJson(const {
        'controlPoint': 'https://control.example.com/',
        'brand': {'productName': 'Example'},
        'trial': {'enabled': true},
      });

      expect(config.serviceName, 'Example');
      expect(config.controlPoint, 'https://control.example.com/');
      expect(config.trialEnabled, isTrue);
    });

    test('без бренда имя нейтральное — «сервис»', () {
      final config = ServiceConfig.fromJson(const {
        'brand': {'productName': '   '},
        'trial': {'enabled': true},
      });

      expect(config.serviceName, ServiceConfig.defaultServiceName);
      expect(config.serviceName, 'сервис');
    });

    test('пустой конфиг даёт нейтральные значения по умолчанию', () {
      const config = ServiceConfig();

      expect(config.serviceName, 'сервис');
      expect(config.controlPoint, isNull);
      expect(config.trialEnabled, isFalse);
    });

    test('trial.enabled не true — пробный ключ выключен', () {
      final config = ServiceConfig.fromJson(const {
        'brand': {'productName': 'Example'},
        'trial': {'enabled': false},
      });

      expect(config.trialEnabled, isFalse);
    });
  });

  group('ServiceConfig.load', () {
    test('читает ассет сборки', () async {
      final config = await ServiceConfig.load(
        bundle: _FakeBundle(
          '{"brand":{"productName":"Example"},'
          '"controlPoint":"https://control.example.com/",'
          '"trial":{"enabled":true}}',
        ),
      );

      expect(config.serviceName, 'Example');
      expect(config.trialEnabled, isTrue);
    });

    test('нет ассета (открытый клиент) — значения по умолчанию', () async {
      final config = await ServiceConfig.load(
        bundle: _FakeBundle(null, absent: true),
      );

      expect(config.serviceName, 'сервис');
      expect(config.controlPoint, isNull);
      expect(config.trialEnabled, isFalse);
    });

    test('битый JSON не роняет клиент — значения по умолчанию', () async {
      final config = await ServiceConfig.load(bundle: _FakeBundle('{не json'));

      expect(config.serviceName, 'сервис');
      expect(config.trialEnabled, isFalse);
    });

    test('JSON не объект — значения по умолчанию', () async {
      final config = await ServiceConfig.load(bundle: _FakeBundle('[1, 2, 3]'));

      expect(config.serviceName, 'сервис');
    });
  });
}
