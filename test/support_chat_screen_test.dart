import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/chat_service.dart';
import 'package:client_vpn/chat_store.dart';
import 'package:client_vpn/matrix_api.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/provider.dart';
import 'package:client_vpn/support_chat_screen.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const home = 'https://chat.example:8448';
const room = '!abc:chat.example';
const providerId = 'провайдер-1';

/// Узел чата без сети: ответ на `/sync` выдаёт сам тест, поэтому цикл сервиса
/// стоит ровно там, где его проверяют, и не крутится во время прогона виджетов.
class FakeNode {
  final List<String> bodies = [];
  final List<Completer<MatrixReply>> _waiting = [];

  Object? sendFailure;
  Map<String, dynamic>? quickReplies;

  Future<MatrixReply> call(MatrixRequest request) async {
    final path = request.url.path;
    if (path.endsWith('/versions')) return _reply(200, {'versions': ['v1.11']});
    if (path.endsWith('/state/$quickRepliesStateType')) {
      final found = quickReplies;
      return found == null
          ? _reply(404, {'errcode': 'M_NOT_FOUND'})
          : _reply(200, found);
    }
    if (path.endsWith('/login')) {
      return _reply(200, {
        'access_token': 'токен-Т',
        'device_id': 'DEV1',
        'user_id': '@demo:chat.example',
      });
    }
    if (path.endsWith('/logout')) return _reply(200, {});
    if (path.endsWith('/sync')) {
      final completer = Completer<MatrixReply>();
      _waiting.add(completer);
      return completer.future;
    }

    final failure = sendFailure;
    if (failure != null) throw failure;
    bodies.add(jsonDecode(request.body!)['body'] as String);
    return _reply(200, {'event_id': r'$e'});
  }

  void answerSync(Map<String, dynamic> json) => answer(200, json);

  void answer(int status, Map<String, dynamic> json) =>
      _waiting.removeAt(0).complete(_reply(status, json));

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

/// Ядро без процесса: экрану чата от него нужна только состояние туннеля.
class IdleCore implements VpnCore {
  @override
  Stream<String> get logs => const Stream<String>.empty();

  @override
  Stream<bool> get statusChanges => const Stream<bool>.empty();

  @override
  bool get isRunning => false;

  @override
  String? get endpointLabel => null;

  @override
  Future<void> validate(VpnConfig config) async {}

  @override
  Future<void> start(VpnConfig config) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> recoverAfterCrash() async {}

  @override
  Future<void> dispose() async {}
}

Map<String, dynamic> syncWith(String sender, String body, String eventId) => {
      'rooms': {
        'join': {
          room: {
            'timeline': {
              'events': [
                {
                  'type': 'm.room.message',
                  'sender': sender,
                  'origin_server_ts': 1700000000000,
                  'event_id': eventId,
                  'content': {'msgtype': 'm.text', 'body': body},
                },
              ],
            },
          },
        },
      },
      'next_batch': 's$eventId',
    };

void main() {
  late FakeNode node;
  late MemoryVault vault;
  late ChatService chat;
  late AppState state;

  Future<void> pump(WidgetTester tester, [int times = 4]) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    node = FakeNode();
    vault = MemoryVault();
    chat = ChatService(
      ChatStore(await SharedPreferences.getInstance(), vault),
      call: node.call,
      delay: (_) async {},
    );
    state = AppState(await ProfileStore.open(), IdleCore(), chat: chat);
  });

  tearDown(() {
    chat.stop();
    state.dispose();
  });

  Future<void> openScreen(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SupportChatScreen(
        state: state,
        provider: const Provider(
          id: providerId,
          url: 'https://example.org/sub',
          chatHomeserver: home,
          chatRoomId: room,
        ),
      ),
    ));
    await pump(tester);
  }

  Future<void> signIn(WidgetTester tester) async {
    await openScreen(tester);
    await tester.enterText(find.byKey(const ValueKey('user')), '@demo:chat.example');
    await tester.enterText(find.byKey(const ValueKey('password')), 'пароль');
    await tester.tap(find.text('Войти в чат'));
    await pump(tester);
    expect(chat.signedIn, isTrue);
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('draft')), text);
    await tester.tap(find.byIcon(Icons.send));
    await pump(tester);
  }

  testWidgets('форма входа предзаполнена узлом из подписки', (tester) async {
    await openScreen(tester);

    expect(find.text('Чат поддержки'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('homeserver'))).controller!.text,
      home,
    );
    expect(find.textContaining('дежурный'), findsWidgets);
  });

  testWidgets('вход открывает ленту, отправка помечена отправленной',
      (tester) async {
    await signIn(tester);

    expect(find.text('Пока пусто. Напишите первое сообщение.'), findsOneWidget);

    await send(tester, 'Привет');

    expect(node.bodies.single, 'Привет');
    expect(find.text('Привет'), findsOneWidget);
    expect(find.textContaining('отправлено'), findsWidgets);
    expect(vault.values.values, contains('токен-Т'));
  });

  testWidgets('сообщение дежурного появляется в ленте', (tester) async {
    await signIn(tester);

    node.answerSync(syncWith('@support:chat.example', 'Здравствуйте', '1'));
    await pump(tester);

    expect(find.text('Здравствуйте'), findsOneWidget);
    expect(find.text('support'), findsOneWidget);
  });

  testWidgets('сбой отправки: сообщение остаётся в очереди и это видно',
      (tester) async {
    await signIn(tester);
    node.sendFailure = const SocketException('нет связи');

    await send(tester, 'Проверка');

    expect(find.textContaining('не отправлено'), findsOneWidget);
    expect(find.textContaining('В очереди'), findsOneWidget);
    expect(chat.queued, 1);
    node.sendFailure = null;
  });

  testWidgets('выход стирает токен и закрывает чат', (tester) async {
    await signIn(tester);

    await tester.tap(find.byIcon(Icons.logout));
    await pump(tester);

    expect(vault.values, isEmpty);
    expect(chat.session, isNull);
    expect(find.text('Войти в чат'), findsOneWidget);
  });

  testWidgets('доступ закончился: поле ввода заблокировано',
      (tester) async {
    await signIn(tester);

    node.answer(401, const {'errcode': 'M_UNKNOWN_TOKEN'});
    await pump(tester);

    expect(find.textContaining('Доступ к чату закончился'), findsWidgets);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send)).onPressed, isNull);
    expect(chat.status, ChatStatus.blocked);
  });

  testWidgets('без провайдера чат доступен: адрес узла вводится вручную',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SupportChatScreen(state: state),
    ));
    await pump(tester);

    expect(find.text('Провайдер не прислал адрес узла — введите его вручную'),
        findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('homeserver')), home);
    await tester.enterText(
        find.byKey(const ValueKey('user')), '@demo:chat.example');
    await tester.enterText(
        find.byKey(const ValueKey('password')), 'пароль');
    await tester.enterText(find.byKey(const ValueKey('room')), room);
    await tester.tap(find.text('Войти в чат'));
    await pump(tester);

    expect(chat.session?.providerId, 'direct');
    expect(vault.values.containsKey('chat.token.v1.direct'), isTrue);
    expect(find.byKey(const ValueKey('draft')), findsOneWidget);
  });

  testWidgets('кнопки заявки приходят из комнаты и отправляют свой текст', (tester) async {
    node.quickReplies = {
      'items': [
        {'id': 'c1', 'text': 'Не подключается'},
        {'id': 'c3', 'text': 'Медленно работает'},
      ],
    };
    await signIn(tester);

    expect(find.byKey(const ValueKey('quick.c1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('quick.c3')));
    await pump(tester);

    expect(node.bodies, ['Медленно работает']);
  });

  testWidgets('без кнопок в комнате поле ввода работает как раньше', (tester) async {
    await signIn(tester);

    expect(find.byKey(const ValueKey('quick.c1')), findsNothing);
    await send(tester, 'Здравствуйте');
    expect(node.bodies, ['Здравствуйте']);
  });
}
