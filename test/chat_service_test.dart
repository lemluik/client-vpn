import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_vpn/chat_service.dart';
import 'package:client_vpn/chat_store.dart';
import 'package:client_vpn/matrix_api.dart';
import 'package:client_vpn/provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const home = 'https://chat.example:8448';
const room = '!abc:chat.example';
const providerId = 'провайдер-1';

final at = DateTime.utc(2026, 10, 15, 8);

/// Узел чата без сети: ответы `/sync` выдаёт сам тест, поэтому цикл сервиса
/// идёт ровно настолько, насколько его проверят, а не крутится вхолостую.
class FakeNode {
  final List<MatrixRequest> requests = [];
  final List<String> bodies = [];
  final List<String> txns = [];
  final List<Object?> sendFailures = [];
  final List<Duration> delays = [];

  /// Комнаты, приглашение в которые клиент принял.
  final List<String> joins = [];

  final List<Completer<MatrixReply>> _waiting = [];
  Object? syncFailure;
  Object? joinFailure;
  Map<String, dynamic>? quickReplies;

  List<MatrixRequest> get syncs =>
      requests.where((request) => request.url.path.endsWith('/sync')).toList();

  List<MatrixRequest> get puts =>
      requests.where((request) => request.method == 'PUT').toList();

  Future<void> delay(Duration value) async => delays.add(value);

  Future<MatrixReply> call(MatrixRequest request) async {
    requests.add(request);
    final path = request.url.path;

    if (path.endsWith('/versions')) {
      return _reply(200, {'versions': ['v1.11']});
    }
    if (path.endsWith('/login')) {
      return _reply(200, {
        'access_token': 'токен-Т',
        'device_id': 'DEV1',
        'user_id': '@demo:chat.example',
      });
    }
    if (path.endsWith('/logout')) {
      return _reply(200, {});
    }
    if (path.contains('/join/')) {
      final failure = joinFailure;
      if (failure != null) throw failure;
      final joined = Uri.decodeComponent(path.split('/join/').last);
      joins.add(joined);
      return _reply(200, {'room_id': joined});
    }
    if (path.endsWith('/sync')) {
      final failure = syncFailure;
      if (failure != null) throw failure;
      final completer = Completer<MatrixReply>();
      _waiting.add(completer);
      return completer.future;
    }
    if (path.endsWith('/state/$quickRepliesStateType')) {
      final found = quickReplies;
      return found == null
          ? _reply(404, {'errcode': 'M_NOT_FOUND'})
          : _reply(200, found);
    }

    if (path.endsWith('/messages')) {
      return _reply(200, {'chunk': []});
    }

    bodies.add(jsonDecode(request.body!)['body'] as String);
    txns.add(path.split('/').last);
    final failure = sendFailures.isEmpty ? null : sendFailures.removeAt(0);
    if (failure != null) throw failure;
    return _reply(200, {'event_id': '\$e${txns.length}'});
  }

  /// Отвечает на самое раннее ожидание.
  void answerSync(Map<String, dynamic> json) =>
      _waiting.removeAt(0).complete(_reply(200, json));

  void failSync(Object error) => _waiting.removeAt(0).completeError(error);

  static MatrixReply _reply(int status, Map<String, dynamic> json) =>
      MatrixReply(status, json);
}

class MemoryVault implements TokenVault {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> erase(String key) async => values.remove(key);
}

Map<String, dynamic> timeline(List<Map<String, Object?>> events) => {
      'rooms': {
        'join': {
          room: {
            'timeline': {
              'events': [
                for (final event in events)
                  {
                    'type': 'm.room.message',
                    'content': {'msgtype': 'm.text', 'body': event['body']},
                    'sender': event['sender'],
                    'origin_server_ts': 1700000000000,
                    'event_id': event['id'],
                  },
              ],
            },
          },
        },
      },
    };

/// Ответ `/sync`, в котором комната уже наша: приглашение принимать не надо.
Map<String, dynamic> joinedSync([String batch = 's0']) => {
      'rooms': {
        'join': {room: {}},
      },
      'next_batch': batch,
    };

Future<void> pump([int times = 4]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeNode node;
  late MemoryVault vault;
  late ChatStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    node = FakeNode();
    vault = MemoryVault();
    store = ChatStore(await SharedPreferences.getInstance(), vault);
  });

  ChatService service() => ChatService(
        store,
        call: node.call,
        delay: node.delay,
        now: () => at,
      );

  Future<ChatService> opened() async {
    final chat = service();
    final pending = chat.signIn(
      providerId: providerId,
      homeserver: home,
      user: '@demo:chat.example',
      password: 'пароль',
      roomId: room,
    );
    await pump();
    // Комната пришла из подписки: вход сверяет членство первым `/sync`.
    node.answerSync(joinedSync());

    expect(await pending, isNull);
    await pump();
    return chat;
  }

  group('вход', () {
    test('сессия и токен сохраняются, пароль в хранилище не попадает', () async {
      final chat = await opened();
      addTearDown(chat.stop);

      final session = store.sessionOf(providerId)!;
      expect(session.homeserver, home);
      expect(session.roomId, room);
      expect(session.userId, '@demo:chat.example');
      expect(vault.values.values, contains('токен-Т'));
      expect(store.sessionOf(providerId)!.toJson().containsValue('токен-Т'), isFalse);
      expect(jsonEncode(vault.values), isNot(contains('пароль')));
      expect(chat.status, ChatStatus.live);
      // Комната уже была наша: приглашение принимать не пришлось.
      expect(node.joins, isEmpty);
    });

    test('комната из подписки — приглашение принимается до сохранения сессии',
        () async {
      final chat = service();
      addTearDown(chat.stop);
      final pending = chat.signIn(
        providerId: providerId,
        homeserver: home,
        user: '@demo:chat.example',
        password: 'пароль',
        roomId: room,
      );
      await pump();
      // Узел положил учётку в приглашения: в `rooms.join` комнаты ещё нет.
      node.answerSync({'rooms': {'join': {}}, 'next_batch': 's0'});
      await pump();

      expect(node.joins, [room]);
      // Членство подтверждается вторым `/sync`, и только потом пишется сессия:
      // сохранённая комната без входа в неё дала бы пустую ленту.
      expect(store.sessionOf(providerId), isNull);
      node.answerSync(joinedSync('s1'));

      expect(await pending, isNull);
      expect(store.sessionOf(providerId)!.roomId, room);
      expect(chat.signedIn, isTrue);
    });

    test('узел не принял приглашение — ошибка входа, а не пустой чат',
        () async {
      final chat = service();
      addTearDown(chat.stop);
      node.joinFailure = const MatrixException(403, 'M_FORBIDDEN');
      final pending = chat.signIn(
        providerId: providerId,
        homeserver: home,
        user: '@demo:chat.example',
        password: 'пароль',
        roomId: room,
      );
      await pump();
      node.answerSync({'rooms': {'join': {}}, 'next_batch': 's0'});

      expect(await pending, 'Эта комната не доступна учётке');
      expect(chat.session, isNull);
      expect(store.sessionOf(providerId), isNull);
    });

    test('автологин по подписке: нечем входить — null, сбой — текст ошибки',
        () async {
      const bare = Provider(id: providerId, url: 'https://example.org/sub');
      expect(chatCredentialsReady(bare), isFalse);
      expect(chatCredentialsReady(null), isFalse);
      // «Нечем входить» остаётся null: экран отличает его от сбоя сам.
      expect(await service().signInWithProvider(bare), isNull);

      const ready = Provider(
        id: providerId,
        url: 'https://example.org/sub',
        chatHomeserver: home,
        chatRoomId: room,
        chatUser: '@demo:chat.example',
        chatPassword: 'пароль',
      );
      expect(chatCredentialsReady(ready), isTrue);

      node.syncFailure = const SocketException('нет связи');
      final chat = service();
      addTearDown(chat.stop);
      expect(await chat.signInWithProvider(ready), 'Нет связи с узлом чата');
      expect(chat.status, ChatStatus.retrying);
    });

    test('комнату можно не знать — первая из join берётся сама', () async {
      final chat = service();
      final pending = chat.signIn(
        providerId: providerId,
        homeserver: home,
        user: '@demo:chat.example',
        password: 'пароль',
      );
      await pump();
      node.answerSync({'rooms': {'join': {room: {}}}, 'next_batch': 's1'});

      expect(await pending, isNull);
      expect(store.sessionOf(providerId)!.roomId, room);
      chat.stop();
    });

    test('адрес без схемы и порта — вход не начинается', () async {
      final chat = service();

      expect(
        await chat.signIn(
          providerId: providerId,
          homeserver: 'chat.example',
          user: '@demo:chat.example',
          password: 'пароль',
          roomId: room,
        ),
        isNotNull,
      );
      expect(node.requests, isEmpty);
      expect(chat.session, isNull);
    });

    test('отозванный доступ при входе — состояние «доступ закончился»', () async {
      final chat = service();
      node.syncFailure = const MatrixException(401, 'M_UNKNOWN_TOKEN');

      final error = await chat.signIn(
        providerId: providerId,
        homeserver: home,
        user: '@demo:chat.example',
        password: 'пароль',
      );

      expect(error, 'Доступ к чату закончился');
      expect(chat.status, ChatStatus.blocked);
      expect(chat.session, isNull);
    });
  });

  group('кнопки заявки', () {
    int stateReads() => node.requests
        .where((request) => request.url.path.endsWith('/state/$quickRepliesStateType'))
        .length;

    test('набор кнопок приходит из комнаты, подпись можно задавать отдельно', () async {
      node.quickReplies = {
        'items': [
          {'id': 'c1', 'text': 'Не подключается'},
          {'id': 'c5', 'text': 'Проблема с ключом', 'label': 'Ключ'},
          {'id': 'broken', 'text': '   '},
        ],
      };
      final chat = await opened();
      addTearDown(chat.stop);

      expect(chat.quickReplies.map((reply) => reply.text), ['Не подключается', 'Проблема с ключом']);
      expect(chat.quickReplies.first.caption, 'Не подключается');
      expect(chat.quickReplies.last.caption, 'Ключ');
    });

    test('кнопок у комнаты нет — чат работает как раньше', () async {
      final chat = await opened();
      addTearDown(chat.stop);

      expect(chat.quickReplies, isEmpty);
      await chat.send('Здравствуйте');
      expect(node.bodies, ['Здравствуйте']);
    });

    test('после входящего сообщения набор перечитывается', () async {
      node.quickReplies = {
        'items': [
          {'id': 'c7', 'text': 'Другое'}
        ],
      };
      final chat = await opened();
      addTearDown(chat.stop);
      final before = stateReads();

      node.answerSync(timeline([
        {'body': 'Ответ оператора', 'sender': '@owner:chat.example', 'id': r'$r1'},
      ]));
      await pump();

      expect(stateReads(), greaterThan(before));
      expect(chat.messages.last.body, 'Ответ оператора');
    });

    test('личная комната выбирается по m.direct, а не как первая в ответе', () async {
      const dm = '!dm:chat.example';
      final chat = service();
      final pending = chat.signIn(
        providerId: providerId,
        homeserver: home,
        user: '@demo:chat.example',
        password: 'пароль',
      );
      await pump();
      node.answerSync({
        'rooms': {
          'join': {
            room: {},
            dm: {},
          },
        },
        'account_data': {
          'events': [
            {
              'type': 'm.direct',
              'content': {
                '@owner:chat.example': [dm],
              },
            },
          ],
        },
        'next_batch': 's1',
      });

      expect(await pending, isNull);
      expect(store.sessionOf(providerId)!.roomId, dm);
      chat.stop();
    });
  });

  group('отправка', () {
    test('сообщение уходит один раз и снимается с очереди', () async {
      final chat = await opened();

      await chat.send('Здравствуйте');

      expect(node.puts, hasLength(1));
      expect(node.bodies.single, 'Здравствуйте');
      expect(chat.queued, 0);
      expect(chat.messages.single.pending, isFalse);
      expect(chat.messages.single.failed, isFalse);
      chat.stop();
    });

    test('не отправлено остаётся в очереди с прежним txnId', () async {
      final chat = await opened();
      node.sendFailures.add(const MatrixException(500, ''));

      await chat.send('Потерялось');
      final txn = node.txns.single;
      expect(chat.messages.single.failed, isTrue);
      expect(chat.queued, 1);
      chat.stop();
      // У остановленного цикла остаётся невостребованный long-poll: гасим его,
      // иначе ответ уйдёт старому соединению, а новый вход будет ждать вечно.
      node.answerSync({'rooms': {}, 'next_batch': 's0'});
      await pump();

      // Перезапуск приложения: очередь восстановилась и ушла на узел прежним
      // txnId — дубля на стороне homeserver не будет.
      final restored = service();
      final resumed = restored.resume(providerId);
      await pump();
      node.answerSync({'rooms': {'join': {room: {}}}, 'next_batch': 's1'});
      expect(await resumed, isTrue);
      await pump();

      expect(restored.messages.single.body, 'Потерялось');
      expect(restored.messages.single.pending, isFalse);
      expect(node.txns, [txn, txn]);
      expect(restored.queued, 0);
      expect(store.sessionOf(providerId)!.outbox, isEmpty);
      restored.stop();
    });

    test('лимит запросов: пауза перед тем как сказать про ошибку', () async {
      final chat = await opened();
      node.sendFailures.add(const MatrixException(429, 'M_LIMIT_EXCEEDED'));

      await chat.send('Слишком часто');

      expect(node.delays, contains(const Duration(seconds: 1)));
      expect(chat.messages.single.failed, isTrue);
      chat.stop();
    });

    test('сообщения из ленты приходят и своё не дублируется', () async {
      final chat = await opened();

      node.answerSync(timeline([
        {'sender': '@support:chat.example', 'body': 'Принято', 'id': '\$1'},
        {'sender': '@demo:chat.example', 'body': 'Здравствуйте', 'id': '\$2'},
      ]));
      await pump();

      expect(chat.messages.map((message) => message.body), ['Принято']);
      expect(chat.messages.last.senderName, 'support');
      chat.stop();
    });
  });

  group('курсор и ретраи', () {
    test('курсор сохраняется и следующий запрос идёт с ним', () async {
      final chat = await opened();

      node.answerSync({...timeline([]), 'next_batch': 's42'});
      await pump();

      expect(store.sessionOf(providerId)!.since, 's42');
      expect(node.syncs.last.url.queryParameters['since'], 's42');
      chat.stop();
    });

    test('экран закрыли и открыли снова: приём поднимается одним циклом', () async {
      final chat = await opened();
      final before = node.syncs.length;

      chat.stop();
      node.answerSync({...timeline([]), 'next_batch': 's43'});
      await pump();
      expect(node.syncs.length, before,
          reason: 'остановленный цикл новых запросов не заводит');

      chat.resumePolling();
      await pump();
      expect(node.syncs.length, before + 1,
          reason: 'поднят ровно один новый запрос, старый цикл не воскрес');
      node.answerSync({...timeline([]), 'next_batch': 's44'});
      await pump();

      expect(chat.status, ChatStatus.live);
      expect(store.sessionOf(providerId)!.since, 's44');
      expect(node.syncs.length, before + 2,
          reason: 'на ответ цикл заводит следующий запрос, а не два');
      chat.stop();
    });

    test('сетевой сбой повторяется по 1/2/4/8/16 с, дальше очередь ждёт', () async {
      final chat = service();
      final pending = chat.signIn(
        providerId: providerId,
        homeserver: home,
        user: '@demo:chat.example',
        password: 'пароль',
        roomId: room,
      );
      await pump();
      node.answerSync(joinedSync());
      expect(await pending, isNull);
      await pump();
      // Пять пауз по спецификации; шестой сбой цикл уже не продолжает.
      for (var i = 0; i < 6; i++) {
        await pump();
        node.failSync(const SocketException('нет связи'));
      }
      await pump();

      expect(node.delays, chatBackoffs);
      expect(chat.status, ChatStatus.retrying);
      expect(chat.error, contains('очередь ждёт сети'));

      // Кнопка повтора поднимает цикл: очередь и курсор на месте.
      await chat.retry();
      await pump();
      node.answerSync({...timeline([]), 'next_batch': 's7'});
      await pump();

      expect(chat.status, ChatStatus.live);
      expect(store.sessionOf(providerId)!.since, 's7');
      chat.stop();
    });

    test('401 во время работы: доступ закончился, цикл остановлен', () async {
      final chat = await opened();
      // Вход уже сделал `/sync` для проверки членства: считаем от него.
      final before = node.syncs.length;

      node.failSync(const MatrixException(401, 'M_UNKNOWN_TOKEN'));
      await pump();

      expect(chat.status, ChatStatus.blocked);
      expect(chat.error, 'Доступ к чату закончился');
      // Цикл остановлен: нового `/sync` после 401 нет.
      expect(node.syncs.length, before);
      chat.stop();
    });
  });

  group('выход и изоляция', () {
    test('выход снимает сессию с узла и стирает локальные данные', () async {
      final chat = await opened();
      await chat.send('Последнее');

      await chat.signOut();
      await pump();

      expect(node.requests.any((r) => r.url.path.endsWith('/logout')), isTrue);
      expect(store.sessionOf(providerId), isNull);
      expect(vault.values, isEmpty);
      expect(chat.messages, isEmpty);
    });

    test('данные чата провайдера удаляются вместе с его записью', () async {
      final chat = await opened();
      await chat.send('Осталось в очереди');
      chat.stop();

      await service().forget(providerId);

      expect(store.sessionOf(providerId), isNull);
      expect(vault.values, isEmpty);
    });

    test('без сохранённой сессии чат остаётся закрытым', () async {
      final chat = service();

      expect(await chat.resume(providerId), isFalse);
      expect(chat.status, ChatStatus.signedOut);
      expect(node.syncs, isEmpty);
    });

    test('сессия есть, а токена нет — доступ потерян, а не пустой экран',
        () async {
      await store.save(const ChatSession(
        providerId: providerId,
        homeserver: home,
        userId: '@demo:chat.example',
        roomId: room,
      ));

      final chat = service();
      expect(await chat.resume(providerId), isFalse);
      expect(chat.status, ChatStatus.blocked);
      expect(chat.error, 'Доступ к чату закончился');
    });

    test('службу уничтожили раньше экрана: остановка и досчитанный sync молчат',
        () async {
      final chat = await opened();
      final pending = node.syncs.length;

      chat.dispose();
      expect(chat.stop, returnsNormally);

      // Долгий запрос досчитывает свой век после уничтожения службы: цикл
      // обязан выйти сам, а не оповещать снятых слушателей.
      node.answerSync({...timeline([]), 'next_batch': 's99'});
      await pump();

      expect(node.syncs.length, pending,
          reason: 'новый запрос после уничтожения службы не заведён');
    });
  });
}
