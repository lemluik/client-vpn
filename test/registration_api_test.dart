import 'dart:convert';
import 'dart:io';

import 'package:client_vpn/services/registration_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// Вымышленный ключ и тестовый идентификатор: боевых значений здесь нет.
const validKey =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.test:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.test'
    '&flow=xtls-rprx-vision#Trial';

const device = DeviceData(
  deviceId: 'test-uuid-1',
  platform: 'windows',
  appVersion: '0.0.0-test',
);

Future<HttpServer> serverWith(void Function(HttpRequest) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  addTearDown(() => server.close(force: true));
  return server;
}

void main() {
  group('ограничения ответа точки контроля', () {
    test('обычный ответ разбирается', () async {
      final server = await serverWith((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'key': validKey, 'service_name': 'Example'}));
        await request.response.close();
      });

      final api = HttpRegistrationApi(
        controlPoint: 'http://127.0.0.1:${server.port}',
      );
      final result = await api.register(
        telegramLogin: '@testuser',
        device: device,
      );

      expect(result.key, validKey);
      expect(result.serviceName, 'Example');
    });

    test('заголовки пришли, тело зависло — ошибка по пределу ожидания',
        () async {
      final server = await serverWith((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{');
        await request.response.flush();
        // Тело намеренно не завершается: без общего предела чтение висело бы
        // вечно, а клиент показывал бы «подключение…» без конца.
      });

      final api = HttpRegistrationApi(
        controlPoint: 'http://127.0.0.1:${server.port}',
        timeout: const Duration(milliseconds: 300),
      );

      final watch = Stopwatch()..start();
      await expectLater(
        api.register(telegramLogin: '@testuser', device: device),
        throwsA(
          isA<RegistrationException>().having(
            (error) => error.message,
            'message',
            'Сервис не отвечает — попробуйте позже',
          ),
        ),
      );
      expect(watch.elapsedMilliseconds, lessThan(5000));
    });

    test('слишком большой ответ отклоняется по размеру', () async {
      final server = await serverWith((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json;
        request.response.write('a' * (maxRegistrationBytes + 1));
        await request.response.close();
      });

      final api = HttpRegistrationApi(
        controlPoint: 'http://127.0.0.1:${server.port}',
      );

      await expectLater(
        api.register(telegramLogin: '@testuser', device: device),
        throwsA(
          isA<RegistrationException>().having(
            (error) => error.message,
            'message',
            'Ответ сервиса слишком большой',
          ),
        ),
      );
    });

    test('клиент, переданный извне, не закрывается', () async {
      var requests = 0;
      final server = await serverWith((request) async {
        requests++;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'key': validKey}));
        await request.response.close();
      });

      final client = HttpClient();
      addTearDown(client.close);
      final api = HttpRegistrationApi(
        controlPoint: 'http://127.0.0.1:${server.port}',
        client: client,
      );

      // Два запроса одним клиентом: закрытый после первого он бы не пережил.
      await api.register(telegramLogin: '@testuser', device: device);
      await api.register(telegramLogin: '@testuser', device: device);

      expect(requests, 2);
    });
  });
}
