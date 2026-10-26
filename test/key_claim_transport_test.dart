// Key claim transport against a local stub (Д2-22).
//
// A separate file without widget tests is required: once a suite starts
// TestWidgetsFlutterBinding, every HttpClient in that isolate gets 400 and the
// network is not visible at all. Here the binding is not initialised and the
// exchange is real, but only with 127.0.0.1.

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
    // The stub is an HttpServer on 127.0.0.1 with an ephemeral port: it checks
    // the exchange itself (method, path, body fields, list parsing and error
    // codes) without live addresses and without outside network.
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
          'claim_code',
          'device_id',
          'platform',
          'app_version',
        });
        expect(seenBody!['claim_code'], 'ABC-123');
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
            // The request body is not read: the client closes the connection
            // after the status, and listening to the body stream would throw an
            // unhandled HttpException on the server. drain swallows it.
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

  test('the control point answer shape: links, entry_labels, traffic_left_gb', () {
    // The shape the control point actually returns: every cascade entry in
    // `links`, one per line, labels as a list, the traffic left in gigabytes.
    final key = ClaimedKey.fromJson({
      'name': 'Ноутбук',
      'entry_labels': ['Германия 1', 'Германия 2'],
      'expires_at': null,
      'expiry_label': 'без срока',
      'is_trial': false,
      'links': '$keyOneLink\n$keyTwoLink',
      'traffic_left_gb': 1.5,
    });

    expect(key.link.split('\n'), [keyOneLink, keyTwoLink]);
    expect(key.entryLabel, 'Германия 1, Германия 2');
    expect(key.expiresAt, isNull);
    expect(key.trafficLeftMb, 1536);

    final listed = ClaimedKey.fromJson({
      'name': 'Список',
      'links': [keyOneLink, keyTwoLink],
    });
    expect(listed.link.split('\n'), hasLength(2));
  });
}
