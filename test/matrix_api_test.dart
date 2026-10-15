import 'dart:io';

import 'package:client_vpn/matrix_api.dart';
import 'package:flutter_test/flutter_test.dart';

const home = 'https://chat.example:8448';
const room = '!abc123:chat.example';

/// Заглушка обмена с узлом: сеть не нужна, а коды 401/429/5xx проверяются
/// напрямую.
class FakeCaller {
  final List<MatrixRequest> requests = [];

  MatrixReply Function(MatrixRequest request) respond =
      (_) => const MatrixReply(200, {});

  Future<MatrixReply> call(MatrixRequest request) async {
    requests.add(request);
    return respond(request);
  }

  MatrixRequest get last => requests.last;
}

MatrixReply json(int status, Map<String, dynamic> body) => MatrixReply(status, body);

void main() {
  group('вход', () {
    test('идентификатор в форме, которую принимает узел', () async {
      final caller = FakeCaller()
        ..respond = (request) => request.url.path.endsWith('/login')
            ? json(200, {
                'access_token': 'тokен',
                'device_id': 'DEV1',
                'user_id': '@demo:chat.example',
              })
            : json(200, {'versions': ['v1.11']});

      final client = MatrixClient(home, call: caller.call);
      final result = await client.login('@demo:chat.example', 'пароль');

      expect(result.deviceId, 'DEV1');
      expect(result.userId, '@demo:chat.example');
      expect(client.token, 'тokен');
      expect(caller.requests.first.token, isNull);

      final sent = caller.last.body!;
      expect(sent, contains('"type":"m.id.user"'));
      expect(sent, contains('"user":"@demo:chat.example"'));
      expect(sent, isNot(contains('user_id')));
    });

    test('узел без токена в ответе — ошибка, а не тихий вход', () async {
      final caller = FakeCaller()..respond = (_) => json(200, {'device_id': 'D'});
      final client = MatrixClient(home, call: caller.call);

      expect(
        () => client.login('@a:chat.example', 'p'),
        throwsA(isA<MatrixException>()
            .having((e) => e.errcode, 'errcode', 'M_MISSING_TOKEN')),
      );
      expect(client.signedIn, isFalse);
    });

    test('не Matrix-узел: проверка версий падает по коду', () async {
      final caller = FakeCaller()..respond = (_) => json(404, {});
      final client = MatrixClient(home, call: caller.call);

      expect(() => client.versions(),
          throwsA(isA<MatrixException>().having((e) => e.status, 'status', 404)));
    });
  });

  group('запросы', () {
    test('long-poll ждёт и передаёт курсор', () async {
      final caller = FakeCaller()
        ..respond = (_) => json(200, {'next_batch': 's2'});
      final client = MatrixClient(home, token: 'T', call: caller.call);

      await client.sync(since: 's1');

      expect(caller.last.url.path, '/_matrix/client/v3/sync');
      expect(caller.last.url.queryParameters['since'], 's1');
      expect(caller.last.url.queryParameters['timeout'],
        '${matrixSyncWait.inMilliseconds}');
      expect(caller.last.wait, matrixSyncWait + matrixTimeout);
      expect(caller.last.token, 'T');
    });

    test('отправка идёт с txnId в пути, повтор — с тем же', () async {
      final caller = FakeCaller()..respond = (_) => json(200, {'event_id': '\$e'});
      final client = MatrixClient(home, token: 'T', call: caller.call);

      final event = await client.send(room, 'Привет', 'txn-1');
      final again = await client.send(room, 'Привет', 'txn-1');

      expect(event, '\$e');
      expect(again, '\$e');
      expect(caller.last.method, 'PUT');
      expect(
        caller.last.url.path,
        '/_matrix/client/v3/rooms/${Uri.encodeComponent(room)}'
        '/send/m.room.message/txn-1',
      );
      expect(caller.last.body, contains('"msgtype":"m.text"'));
      expect(caller.last.body, contains('Привет'));
    });

    test('пустое и слишком длинное сообщение на узел не уходит', () async {
      final caller = FakeCaller()..respond = (_) => json(200, {});
      final client = MatrixClient(home, token: 'T', call: caller.call);

      expect(() => client.send(room, '   ', 't'), throwsA(isA<FormatException>()));
      // 600 тысяч кириллических символов — больше мегабайта в UTF-8.
      expect(
        () => client.send(room, 'а' * 600000, 't'),
        throwsA(isA<FormatException>()),
      );
      expect(caller.requests, isEmpty);
    });

    test('выход снимает токен с клиента', () async {
      final caller = FakeCaller()..respond = (_) => json(200, {});
      final client = MatrixClient(home, token: 'T', call: caller.call);

      await client.logout();

      expect(caller.last.url.path, '/_matrix/client/v3/logout');
      expect(client.signedIn, isFalse);
    });
  });

  group('разбор ленты', () {
    final payload = <String, dynamic>{
      'next_batch': 's9',
      'rooms': {
        'join': {
          room: {
            'timeline': {
              'events': [
                {
                  'type': 'm.room.message',
                  'sender': '@support:chat.example',
                  'origin_server_ts': 1700000000000,
                  'event_id': '\$1',
                  'content': {'msgtype': 'm.text', 'body': 'Здравствуйте'},
                },
                {
                  'type': 'm.room.message',
                  'sender': '@demo:chat.example',
                  'origin_server_ts': 1700000000001,
                  'event_id': '\$2',
                  'content': {'msgtype': 'm.text', 'body': 'моё'},
                },
                {
                  'type': 'm.room.message',
                  'sender': '@support:chat.example',
                  'origin_server_ts': 1700000000002,
                  'event_id': '\$3',
                  'content': {'msgtype': 'm.image', 'body': 'файл'},
                },
                {
                  'type': 'm.room.member',
                  'sender': '@support:chat.example',
                  'content': {'body': 'служебное'},
                },
              ],
            },
          },
        },
      },
    };

    test('только текстовые сообщения чужих отправителей', () {
      final messages =
          messagesFromSync(payload, room, selfUserId: '@demo:chat.example');

      expect(messages.map((m) => m.eventId), ['\$1']);
      expect(messages.single.senderName, 'support');
      expect(messages.single.body, 'Здравствуйте');
    });

    test('своё узнаётся по локальной части, даже если имя ввели без домена', () {
      final messages = messagesFromSync(payload, room, selfUserId: 'demo');

      expect(messages.map((m) => m.eventId), ['\$1']);
    });

    test('чужая комната и пустой ответ дают пустую ленту', () {
      expect(messagesFromSync(payload, '!other:chat.example'), isEmpty);
      expect(messagesFromSync(const {}, room), isEmpty);
    });
  });

  group('текст ошибки', () {
    test('не раскрывает адрес узла, токен и тело ответа', () {
      const cases = {
        401: 'Доступ к чату закончился',
        403: 'Эта комната не доступна учётке',
        429: 'Узел просит отправлять реже',
        500: 'Узел чата временно не отвечает',
        400: 'Узел чата ответил ошибкой',
      };
      for (final entry in cases.entries) {
        final error = MatrixException(entry.key, '');
        expect(chatErrorOf(error), entry.value);
        expect(chatErrorOf(error), isNot(contains(home)));
      }
      expect(
          chatErrorOf(const MatrixException(401, 'M_UNKNOWN_TOKEN')),
          'Доступ к чату закончился');
    });

    test('отказ входа — это про пароль, а не про комнату', () async {
      final caller = FakeCaller()
        ..respond = (_) => json(403, const {
              'errcode': 'M_FORBIDDEN',
              'error': 'M_FORBIDDEN: Wrong username or password.',
            });
      final client = MatrixClient(home, call: caller.call);

      Object? caught;
      try {
        await client.login('demo', 'неверный');
      } catch (error) {
        caught = error;
      }

      expect(chatErrorOf(caught!), 'Неверный логин или пароль чата');
      // Текст не должен выдавать наружу ни ответ узла, ни адрес.
      expect(chatErrorOf(caught), isNot(contains('Wrong')));
      expect(chatErrorOf(caught), isNot(contains(home)));
    });

    test('сетевые сбои формулируются по-человечески', () {
      expect(
        chatErrorOf(const SocketException('connection refused')),
        'Нет связи с узлом чата',
      );
      expect(
        chatErrorOf(const FormatException('Сообщение слишком длинное')),
        'Сообщение слишком длинное',
      );
    });
  });
}
