import 'package:client_vpn/proxy_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseProxyInbound', () {
    test('находит http inbound с числовым портом', () {
      final proxy = parseProxyInbound('''
        {"inbounds": [{"protocol": "http", "listen": "127.0.0.1", "port": 10809}]}
      ''');

      expect(proxy, (protocol: 'http', port: 10809));
    });

    test('находит socks inbound', () {
      final proxy = parseProxyInbound('''
        {"inbounds": [{"protocol": "socks", "port": 10808}]}
      ''');

      expect(proxy, (protocol: 'socks', port: 10808));
    });

    test('принимает порт, заданный строкой', () {
      final proxy = parseProxyInbound('''
        {"inbounds": [{"protocol": "socks", "port": " 10808 "}]}
      ''');

      expect(proxy, (protocol: 'socks', port: 10808));
    });

    test('возвращает первый подходящий inbound', () {
      final proxy = parseProxyInbound('''
        {"inbounds": [
          {"protocol": "vless", "port": 443},
          {"protocol": "socks", "port": 10808},
          {"protocol": "http", "port": 10809}
        ]}
      ''');

      expect(proxy, (protocol: 'socks', port: 10808));
    });

    // Регрессия H1: без локального прокси системные настройки не меняются,
    // трафик идёт напрямую, а интерфейс показывал бы «Подключён».
    test('null, если http/socks inbound отсутствует', () {
      expect(
        parseProxyInbound('{"inbounds": [{"protocol": "vless", "port": 443}]}'),
        isNull,
      );
    });

    test('null, если у подходящего inbound нет читаемого порта', () {
      expect(parseProxyInbound('{"inbounds": [{"protocol": "http"}]}'), isNull);
      expect(
        parseProxyInbound(
          '{"inbounds": [{"protocol": "http", "port": "abc"}]}',
        ),
        isNull,
      );
    });

    test('null, если ключа inbounds нет или он не список', () {
      expect(parseProxyInbound('{}'), isNull);
      expect(parseProxyInbound('{"inbounds": {"port": 10809}}'), isNull);
    });

    test('null, если документ не объект', () {
      expect(parseProxyInbound('[{"protocol": "http", "port": 1}]'), isNull);
      expect(parseProxyInbound('"строка"'), isNull);
    });

    test('пропускает элементы списка, не являющиеся объектами', () {
      expect(
        parseProxyInbound(
          '{"inbounds": [null, 42, {"protocol": "http", "port": 10809}]}',
        ),
        (protocol: 'http', port: 10809),
      );
    });
  });

  group('parsePort', () {
    test('число проходит как есть', () {
      expect(parsePort(10809), 10809);
    });

    test('строка с пробелами парсится', () {
      expect(parsePort(' 10809 '), 10809);
    });

    test('нечитаемое значение даёт null', () {
      expect(parsePort(''), isNull);
      expect(parsePort('abc'), isNull);
      expect(parsePort(null), isNull);
      expect(parsePort(1.5), isNull);
      expect(parsePort(true), isNull);
      expect(parsePort([1]), isNull);
    });
  });
}
