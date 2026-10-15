import 'dart:convert';

import 'package:client_vpn/chat_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const provider = 'провайдер-1';
const other = 'провайдер-2';

/// Хранилище токена в памяти: проверя поведению, а не реальному Keystore.
class MemoryVault implements TokenVault {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> erase(String key) async => values.remove(key);
}

void main() {
  late SharedPreferences prefs;
  late MemoryVault vault;
  late ChatStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    vault = MemoryVault();
    store = ChatStore(prefs, vault);
  });

  ChatSession session({String id = provider, List<OutboxItem> outbox = const []}) =>
      ChatSession(
        providerId: id,
        homeserver: 'https://chat.example:8448',
        userId: '@demo:chat.example',
        roomId: '!abc:chat.example',
        since: 's1',
        outbox: outbox,
      );

  group('сессии', () {
    test('курсор и очередь переживают перезапуск', () async {
      await store.save(session(outbox: [
        OutboxItem(
          txnId: 'txn-1',
          body: 'Не отправлено',
          at: DateTime.utc(2026, 10, 15, 8),
        ),
      ]));

      final restored = ChatStore(prefs, vault).sessionOf(provider)!;

      expect(restored.since, 's1');
      expect(restored.homeserver, 'https://chat.example:8448');
      expect(restored.roomId, '!abc:chat.example');
      expect(restored.outbox.single.txnId, 'txn-1');
      expect(restored.outbox.single.body, 'Не отправлено');
      expect(restored.outbox.single.at, DateTime.utc(2026, 10, 15, 8));
    });

    test('каждый провайдер со своим чатом, и удаление не задевает прочих',
        () async {
      await store.save(session());
      await store.save(session(id: other));
      await store.saveToken(provider, 'токен-1');
      await store.saveToken(other, 'токен-2');

      await store.drop(provider);

      expect(store.sessionOf(provider), isNull);
      expect(await store.tokenOf(provider), isNull);
      expect(store.sessionOf(other), isNotNull);
      expect(await store.tokenOf(other), 'токен-2');
    });

    test('токен не попадает в обычные настройки', () async {
      await store.save(session());
      await store.saveToken(provider, 'секретный-токен');

      expect(store.sessionOf(provider)!.toJson().containsValue('секретный-токен'),
          isFalse);
      expect(prefs.getString('chat.v1'), isNot(contains('секретный-токен')));
      expect(vault.values.values, contains('секретный-токен'));
    });

    test('битая запись чата пропускается, остальные остаются', () async {
      await store.save(session());
      final broken = jsonDecode(prefs.getString('chat.v1')!) as Map<String, dynamic>
        ..[other] = {'user': 'без узла'};
      await prefs.setString('chat.v1', jsonEncode(broken));

      expect(store.sessionOf(provider), isNotNull);
      expect(store.sessionOf(other), isNull);
    });

    test('пустой хранилище — это null, а не исключение', () {
      expect(store.sessionOf(provider), isNull);
    });
  });

  group('адрес узла', () {
    test('принимается только https с хостом и портом', () {
      expect(chatHomeserverError('https://chat.example:8448'), isNull);
      expect(chatHomeserverError(' https://chat.example:8448/ '), isNull);
      expect(chatHomeserverError('http://chat.example:8448'), isNotNull);
      expect(chatHomeserverError('chat.example:8448'), isNotNull);
      expect(chatHomeserverError('https://chat.example/path'), isNotNull);
      expect(chatHomeserverError('https://user@chat.example:8448'), isNotNull);
      expect(chatHomeserverError(''), isNotNull);
    });

    test('подсказка про порт — по-русски и без значения адреса', () {
      final error = chatHomeserverError('http://chat.example:8448')!;
      expect(error, contains('https://'));
      expect(error, contains('порт'));
      expect(error, isNot(contains('chat.example')));
    });
  });

  test('идентификатор сообщения уникален и короткий', () {
    final ids = {for (var i = 0; i < 200; i++) newTxnId()};
    expect(ids.length, 200);
    expect(ids.every((id) => id.startsWith('c')), isTrue);
  });
}
