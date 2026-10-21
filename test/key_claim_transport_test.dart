// Транспорт авторецепта против локальной заглушки (Д2-22).
//
// Отдельный файл без виджетных тестов обязателен: как только в сюите
// поднимается TestWidgetsFlutterBinding, любой HttpClient в этом изоляте
// начинает получать 400 и сеть не видна вовсе. Здесь binding не
// инициализируется, и обмен идёт по-настоящему — но только с 127.0.0.1.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_vpn/services/key_claim_api.dart';
import 'package:client_vpn/services/registration_api.dart' show DeviceData;
import 'package:flutter_test/flutter_test.dart';

const keyOneLink =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org#Первый';

const keyTwoLink =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000002@example.org:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org#Второй';

void main() {
  group('реальный транспорт против локальной заглушки', () {
    // Заглушка — HttpServer на 127.0.0.1 с эфемерным портом: проверяется
    // сам обмен (метод, путь, состав тела, разбор списка и коды ошибок)
    // без боевых адресов и без сети наружу.
    Future<HttpServer> stub({
      void Function(HttpRequest request)? respond,
    }) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        if (respond != null) {
          respond(request);
          return;
        }
        request.listen((_) {});
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'keys': [
                {
                  'key': keyOneLink,
                  'name': 'Первый',
                  'entry': 'Вход А',
                  'expires_at': null,
                  'is_trial': false,
                },
                {
                  'key': keyTwoLink,
                  'name': 'Второй',
                  'entry': 'Вход Б',
                  'expires_at': '2027-01-01T00:00:00Z',
                  'is_trial': true,
                  'traffic_left_mb': 512,
                },
              ],
            }),
          );
        request.response.close();
      });
      return server;
    }

    HttpKeyClaimApi apiFor(HttpServer server) =>
        HttpKeyClaimApi(controlPoint: 'http://127.0.0.1:${server.port}');

    test(
      'POST /api/v1/keys: тело — только код и устройство, список разобран',
      () async {
        String? seenPath;
        String? seenMethod;
        Map<String, dynamic>? seenBody;
        final server = await stub(
          respond: (request) async {
            seenMethod = request.method;
            seenPath = request.uri.path;
            seenBody =
                jsonDecode(await utf8.decoder.bind(request).join())
                    as Map<String, dynamic>;
            request.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(
                jsonEncode({
                  'keys': [
                    {
                      'key': keyOneLink,
                      'name': 'Первый',
                      'entry': 'Вход А',
                      'is_trial': false,
                    },
                  ],
                }),
              );
            await request.response.close();
          },
        );

        final keys = await apiFor(server).claim(
          code: 'ABC-123',
          device: const DeviceData(
            deviceId: 'dev-1',
            platform: 'linux',
            appVersion: '0.4.2',
          ),
        );
        await server.close(force: true);

        expect(seenMethod, 'POST');
        expect(seenPath, '/api/v1/keys');
        expect(seenBody!.keys.toSet(), {
          'code',
          'device_id',
          'platform',
          'app_version',
        });
        expect(seenBody!['code'], 'ABC-123');
        expect(keys, hasLength(1));
        expect(keys.single.name, 'Первый');
        expect(keys.single.entryLabel, 'Вход А');
        expect(keys.single.link, keyOneLink);
        expect(keys.single.isExpiredAt(DateTime.utc(2026, 10, 22)), isFalse);
      },
    );

    test(
      'полный ответ: срок, пробный признак и остаток трафика разобраны',
      () async {
        final server = await stub();
        final keys = await apiFor(server).claim(
          code: 'ABC-123',
          device: const DeviceData(
            deviceId: 'dev-1',
            platform: 'linux',
            appVersion: '0.4.2',
          ),
        );
        await server.close(force: true);

        expect(keys, hasLength(2));
        expect(keys[1].expiresAt, DateTime.utc(2027, 1, 1));
        expect(keys[1].trial, isTrue);
        expect(keys[1].trafficLeftMb, 512);
      },
    );

    test(
      '401 и 404 превращаются в понятные тексты, 404 — «закончилось»',
      () async {
        Future<KeyClaimException> expectError(int status) async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((request) {
            // Тело запроса не читаем: клиент после статуса соединением сам
            // закрывает, и подписка на поток тела сыпала бы на сервер
            // необработанной HttpException. drain гасит это молча.
            unawaited(request.drain<void>().catchError((_) {}));
            request.response.statusCode = status;
            request.response.close();
          });
          try {
            await apiFor(server).claim(
              code: 'ABC-123',
              device: const DeviceData(
                deviceId: 'dev-1',
                platform: 'linux',
                appVersion: '0.4.2',
              ),
            );
            fail('исключение ожидалось');
          } on KeyClaimException catch (error) {
            return error;
          } finally {
            await server.close(force: true);
          }
        }

        final unauthorized = await expectError(HttpStatus.unauthorized);
        expect(unauthorized.message, contains('Код не принят'));
        expect(unauthorized.connectionExpired, isFalse);

        final notFound = await expectError(HttpStatus.notFound);
        expect(notFound.message, 'Подключение закончилось');
        expect(notFound.connectionExpired, isTrue);
      },
    );
  });
}
