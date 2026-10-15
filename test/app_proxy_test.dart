import 'dart:convert';
import 'dart:io';

import 'package:client_vpn/app_proxy.dart';
import 'package:client_vpn/provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ссылка стороннего вида из тестовой документации, не боевой узел.
const _link =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?security=reality&sni=www.example.org&fp=chrome'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMdKeySaMd1234&sid=a1b2c3d4#First';

/// Ставит на [server] замену ядра: первая строка запроса пишется в [lines],
/// ответ отдаётся, только если задан [body].
///
/// Отвечать надо сразу по пустой строке после заголовков, а не по закрытию
/// соединения: клиент ждёт ответа и сам не закрывает поток, иначе прогон
/// висел бы до таймаута.
void serveLocalProxy(ServerSocket server, List<String> lines, {String? body}) {
  server.listen((client) {
    final buffered = StringBuffer();
    var answered = false;
    client.listen(
      (chunk) async {
        buffered.write(utf8.decode(chunk, allowMalformed: true));
        if (answered) return;
        final end = buffered.toString().indexOf('\r\n\r\n');
        if (end < 0) return;
        answered = true;
        lines.add(buffered.toString().split('\r\n').first);
        if (body != null) {
          client
            ..write(
              'HTTP/1.1 200 OK\r\n'
              'content-type: text/plain\r\n'
              'connection: close\r\n\r\n',
            )
            ..write(body);
        }
        await client.flush();
        await client.close();
      },
      onError: (Object _) {},
      cancelOnError: true,
    );
  });
}

void main() {
  group('AppProxy.findProxy', () {
    setUp(() => AppProxy.attach(null));

    test('без поднятого входа — напрямую', () {
      final uri = Uri.parse('https://subs.example/t/abc');

      expect(AppProxy.findProxy(uri), 'DIRECT');
      expect(AppProxy.reachesCore, isFalse);
    });

    test('http-вход — через ядро', () {
      AppProxy.attach((protocol: 'http', port: 10808));

      expect(
        AppProxy.findProxy(Uri.parse('https://subs.example/t/abc')),
        'PROXY 127.0.0.1:10808',
      );
      expect(AppProxy.reachesCore, isTrue);
    });

    test('socks-вход — напрямую: в dart:io нет SOCKS для findProxy', () {
      AppProxy.attach((protocol: 'socks', port: 10809));

      expect(
        AppProxy.findProxy(Uri.parse('https://subs.example/t/abc')),
        'DIRECT',
      );
      expect(AppProxy.reachesCore, isFalse);
    });

    test('петлевой адрес не оборачивается: ядро слушает на нём же', () {
      AppProxy.attach((protocol: 'http', port: 10808));

      for (final uri in [
        'http://127.0.0.1:8099/x',
        'http://localhost/x',
        'http://[::1]/x',
        'http://127.0.0.53/x',
      ]) {
        expect(AppProxy.findProxy(Uri.parse(uri)), 'DIRECT', reason: uri);
      }
    });

    test('снятие входа возвращает прямые запросы', () {
      AppProxy.attach((protocol: 'http', port: 10808));

      AppProxy.attach(null);

      expect(AppProxy.endpoint, isNull);
      expect(
        AppProxy.findProxy(Uri.parse('https://subs.example/t/abc')),
        'DIRECT',
      );
    });
  });

  group('AppProxy.isLoopbackHost', () {
    test('петлевые формы', () {
      for (final host in [
        '127.0.0.1',
        '127.255.255.255',
        'localhost',
        'api.localhost',
        '::1',
        '[::1]',
        '0::1',
      ]) {
        expect(AppProxy.isLoopbackHost(host), isTrue, reason: host);
      }
    });

    test('посторонние адреса', () {
      for (final host in [
        '',
        'example.com',
        'subs.example',
        '10.0.0.1',
        '192.168.1.1',
        '::',
        'fe80::1',
        'notlocalhost',
      ]) {
        expect(AppProxy.isLoopbackHost(host), isFalse, reason: host);
      }
    });
  });

  group('загрузка подписки через локальный вход', () {
    late ServerSocket proxy;
    late List<String> lines;

    setUp(() async {
      AppProxy.attach(null);
      lines = [];
      proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await proxy.close();
      AppProxy.attach(null);
    });

    test('запрос уходит на вход ядра с абсолютным адресом цели', () async {
      serveLocalProxy(proxy, lines, body: _link);
      AppProxy.attach((protocol: 'http', port: proxy.port));

      final response = await fetchSubscription('http://subs.example/t/abc');

      expect(lines, ['GET http://subs.example/t/abc HTTP/1.1']);
      expect(response.body.trim(), _link);
    });

    test('без входа тот же адрес на локальный прокси не приходит', () async {
      serveLocalProxy(proxy, lines);

      await fetchSubscription(
        'http://subs.example/t/abc',
      ).catchError((Object _) => const SubscriptionResponse(body: ''));

      expect(lines, isEmpty);
    });
  });
}
