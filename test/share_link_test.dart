import 'dart:convert';

import 'package:client_vpn/share_link.dart';
import 'package:flutter_test/flutter_test.dart';

const testUuid = '2f6bd5a1-1e73-4b1a-9d3c-000000000001';
const testPublicKey = 'SaMdKeySaMdKeySaMdKeySaMdKeySaMdKeySaMd1234';

/// Ссылка VLESS+Reality с русским именем профиля в percent-кодировке.
const realityLink =
    'vless://$testUuid@example.org:443'
    '?type=tcp&security=reality&flow=xtls-rprx-vision'
    '&sni=www.example.org&fp=chrome&pbk=$testPublicKey&sid=a1b2c3d4'
    '#%D0%9C%D0%BE%D1%81%D0%BA%D0%B2%D0%B0';

String vless({String query = 'security=none', String name = ''}) =>
    'vless://$testUuid@example.org:443?$query${name.isEmpty ? '' : '#$name'}';

String vmess(Map<String, dynamic> data) =>
    'vmess://${base64.encode(utf8.encode(jsonEncode(data)))}';

Map<String, dynamic> outboundOf(ShareLink link) =>
    link.toOutbound(tag: 'proxy');

void main() {
  group('parseShareLink: vless', () {
    test('разбирает ссылку Reality', () {
      final link = parseShareLink(realityLink);

      expect(link.protocol, LinkProtocol.vless);
      expect(link.name, 'Москва');
      expect(link.address, 'example.org');
      expect(link.port, 443);
      expect(link.id, testUuid);
      expect(link.security, 'reality');
      expect(link.network, 'tcp');
      expect(link.flow, 'xtls-rprx-vision');
      expect(link.sni, 'www.example.org');
      expect(link.fingerprint, 'chrome');
      expect(link.publicKey, testPublicKey);
      expect(link.shortId, 'a1b2c3d4');
      expect(link.source, realityLink);
    });

    test('принимает none и raw как tcp-транспорт', () {
      expect(parseShareLink(vless(query: 'type=none')).network, 'tcp');
      expect(parseShareLink(vless(query: 'type=raw')).network, 'tcp');
      expect(parseShareLink(vless(query: 'type=')).network, 'tcp');
    });

    test('подставляет порт 443 и имя по адресу, если их нет', () {
      final link = parseShareLink(
        'vless://$testUuid@example.org?security=none',
      );

      expect(link.port, 443);
      expect(link.name, 'example.org');
      expect(link.sni, isNull);
    });

    test('принимает адрес IPv6 в скобках', () {
      final link = parseShareLink(
        'vless://$testUuid@[2001:db8::1]:8443?security=none',
      );

      expect(link.address, '2001:db8::1');
      expect(link.port, 8443);
    });

    test('раскрывает percent-кодировку в пути ws', () {
      final link = parseShareLink(
        vless(query: 'type=ws&host=cdn.example.org&path=%2Fray%2Fpath'),
      );

      expect(link.network, 'ws');
      expect(link.host, 'cdn.example.org');
      expect(link.path, '/ray/path');
    });

    test('нормализует h2 в http', () {
      expect(parseShareLink(vless(query: 'type=h2')).network, 'http');
    });

    test('разбирает alpn и небезопасный сертификат', () {
      final link = parseShareLink(
        vless(query: 'security=tls&alpn=h2,http&allowInsecure=1'),
      );

      expect(link.security, 'tls');
      expect(link.alpn, ['h2', 'http']);
      expect(link.allowInsecure, isTrue);
      expect(link.sni, 'example.org');
    });

    test('берёт имя сервера из host транспорта, если sni не задан', () {
      final link = parseShareLink(
        vless(query: 'security=tls&type=ws&host=cdn.example.org'),
      );

      expect(link.sni, 'cdn.example.org');
    });
  });

  group('parseShareLink: trojan и vmess', () {
    test('разбирает trojan с паролем в authority', () {
      final link = parseShareLink(
        'trojan://secret-pass@example.org:8443?sni=example.org#Узел',
      );

      expect(link.protocol, LinkProtocol.trojan);
      expect(link.id, 'secret-pass');
      expect(link.port, 8443);
      expect(link.security, 'tls');
      expect(link.name, 'Узел');
    });

    test('trojan без явного security считается tls', () {
      final link = parseShareLink('trojan://pass@example.org:443');

      expect(link.security, 'tls');
      expect(link.sni, 'example.org');
    });

    test('разбирает vmess из base64', () {
      final link = parseShareLink(
        vmess({
          'v': '2',
          'ps': 'Тестовый узел',
          'add': 'example.org',
          'port': '2087',
          'id': testUuid,
          'aid': '4',
          'scy': 'auto',
          'net': 'ws',
          'type': 'none',
          'host': 'cdn.example.org',
          'path': '/ws',
          'tls': 'tls',
          'fp': 'chrome',
          'alpn': 'h2,http',
        }),
      );

      expect(link.protocol, LinkProtocol.vmess);
      expect(link.name, 'Тестовый узел');
      expect(link.address, 'example.org');
      expect(link.port, 2087);
      expect(link.alterId, 4);
      expect(link.encryption, 'auto');
      expect(link.network, 'ws');
      expect(link.security, 'tls');
      expect(link.sni, 'cdn.example.org');
      expect(link.alpn, ['h2', 'http']);
    });

    test('в vmess имя службы gRPC берётся из path', () {
      final link = parseShareLink(
        vmess({
          'add': 'example.org',
          'port': '443',
          'id': testUuid,
          'net': 'grpc',
          'path': 'grpc-service',
        }),
      );

      expect(link.network, 'grpc');
      expect(link.serviceName, 'grpc-service');
    });
  });

  group('toOutbound', () {
    test('собирает исходящее соединение Reality', () {
      final outbound = outboundOf(parseShareLink(realityLink));
      final vnext = (outbound['settings'] as Map)['vnext'] as List;
      final user = (vnext.single as Map)['users'] as List;
      final stream = outbound['streamSettings'] as Map;
      final reality = stream['realitySettings'] as Map;

      expect(outbound['protocol'], 'vless');
      expect(outbound['tag'], 'proxy');
      expect((vnext.single as Map)['address'], 'example.org');
      expect((vnext.single as Map)['port'], 443);
      expect((user.single as Map)['id'], testUuid);
      expect((user.single as Map)['flow'], 'xtls-rprx-vision');
      expect((user.single as Map)['encryption'], 'none');
      expect(stream['network'], 'tcp');
      expect(stream['security'], 'reality');
      expect(reality['serverName'], 'www.example.org');
      expect(reality['fingerprint'], 'chrome');
      expect(reality['publicKey'], testPublicKey);
      expect(reality['shortId'], 'a1b2c3d4');
    });

    test('собирает настройки ws с заголовком Host', () {
      final stream =
          outboundOf(
                parseShareLink(
                  vless(query: 'type=ws&host=cdn.example.org&path=/ray'),
                ),
              )['streamSettings']
              as Map;
      final ws = stream['wsSettings'] as Map;

      expect(stream['network'], 'ws');
      expect(ws['path'], '/ray');
      expect((ws['headers'] as Map)['Host'], 'cdn.example.org');
    });

    test('собирает настройки grpc и tls', () {
      final outbound = outboundOf(
        parseShareLink(
          vless(query: 'type=grpc&serviceName=svc&security=tls&fp=chrome'),
        ),
      );
      final stream = outbound['streamSettings'] as Map;

      expect((stream['grpcSettings'] as Map)['serviceName'], 'svc');
      expect((stream['tlsSettings'] as Map)['fingerprint'], 'chrome');
      expect((stream['tlsSettings'] as Map)['allowInsecure'], isFalse);
      expect(stream.containsKey('realitySettings'), isFalse);
    });

    test('собирает исходящее соединение trojan', () {
      final outbound = outboundOf(
        parseShareLink('trojan://pass@example.org:443?sni=example.org'),
      );
      final servers = (outbound['settings'] as Map)['servers'] as List;

      expect(outbound['protocol'], 'trojan');
      expect((servers.single as Map)['password'], 'pass');
      expect((servers.single as Map)['port'], 443);
    });

    test('собирает исходящее соединение vmess', () {
      final outbound = outboundOf(
        parseShareLink(
          vmess({
            'add': 'example.org',
            'port': '2087',
            'id': testUuid,
            'aid': '4',
            'scy': 'auto',
            'net': 'tcp',
          }),
        ),
      );
      final users =
          ((outbound['settings'] as Map)['vnext'] as List).single['users']
              as List;

      expect(outbound['protocol'], 'vmess');
      expect((users.single as Map)['id'], testUuid);
      expect((users.single as Map)['alterId'], 4);
      expect((users.single as Map)['security'], 'auto');
    });

    test('без тега исходящее соединение остаётся без метки', () {
      expect(
        parseShareLink(realityLink).toOutbound().containsKey('tag'),
        isFalse,
      );
    });
  });

  group('отказы разбора', () {
    test('чужая схема отклоняется с названием схемы', () {
      expect(
        () => parseShareLink('ss://YWVzLTI1Ni1nY206c2VjcmV0@example.org:8389'),
        throwsA(
          isA<UnsupportedLinkException>()
              .having((e) => e.scheme, 'scheme', 'ss')
              .having((e) => e.message, 'message', contains('ss')),
        ),
      );
    });

    test('Reality без открытого ключа отклоняется', () {
      expect(
        () => parseShareLink(vless(query: 'security=reality&fp=chrome')),
        throwsA(
          isA<LinkFormatException>().having(
            (e) => e.message,
            'message',
            contains('pbk'),
          ),
        ),
      );
    });

    test('устаревший flow отклоняется', () {
      expect(
        () => parseShareLink(vless(query: 'flow=xtls-rprx-direct')),
        throwsA(isA<LinkFormatException>()),
      );
    });

    test('устаревший XTLS отклоняется', () {
      expect(
        () => parseShareLink(vless(query: 'security=xtls')),
        throwsA(isA<LinkFormatException>()),
      );
    });

    test('неподдерживаемый транспорт отклоняется', () {
      expect(
        () => parseShareLink(vless(query: 'type=quic')),
        throwsA(isA<LinkFormatException>()),
      );
    });

    test('ссылка без идентификатора отклоняется', () {
      expect(
        () => parseShareLink('vless://@example.org:443?security=none'),
        throwsA(isA<LinkFormatException>()),
      );
    });

    test('ссылка без адреса отклоняется', () {
      expect(
        () => parseShareLink('vless://$testUuid?security=none'),
        throwsA(isA<LinkFormatException>()),
      );
    });

    test('неверный порт отклоняется', () {
      expect(
        () => parseShareLink('vless://$testUuid@example.org:abc?security=none'),
        throwsA(isA<LinkFormatException>()),
      );
      expect(
        () => parseShareLink(
          vmess({'add': 'example.org', 'port': '0', 'id': testUuid}),
        ),
        throwsA(isA<LinkFormatException>()),
      );
      expect(
        () => parseShareLink(
          vmess({'add': 'example.org', 'port': '70000', 'id': testUuid}),
        ),
        throwsA(isA<LinkFormatException>()),
      );
    });

    test('повреждённый vmess отклоняется', () {
      expect(
        () => parseShareLink('vmess://не-base64-текст'),
        throwsA(isA<LinkFormatException>()),
      );
      expect(
        () => parseShareLink(vmess({'add': 'example.org', 'port': '443'})),
        throwsA(isA<LinkFormatException>()),
      );
    });

    test('пустая ссылка отклоняется', () {
      expect(() => parseShareLink('   '), throwsA(isA<LinkFormatException>()));
    });

    test('текст ошибки не содержит значений из ссылки', () {
      const broken =
          'vless://$testUuid@example.org:443?security=reality'
          '&pbk=$testPublicKey&flow=xtls-rprx-direct';

      try {
        parseShareLink(broken);
        fail('ссылка должна была отклониться');
      } on LinkFormatException catch (e) {
        expect(e.message, isNot(contains(testUuid)));
        expect(e.message, isNot(contains(testPublicKey)));
      }
    });
  });

  group('parseLinks', () {
    test('принимает список ссылок построчно', () {
      final result = parseLinks(
        '$realityLink\ntrojan://pass@example.org:443?sni=example.org',
      );

      expect(result.links, hasLength(2));
      expect(result.skipped, isEmpty);
      expect(result.links[1].protocol, LinkProtocol.trojan);
    });

    test('принимает несколько ссылок в одной строке', () {
      final result = parseLinks('$realityLink $realityLink');

      expect(result.links, hasLength(2));
    });

    test('пропускает повреждённые строки с номером и причиной', () {
      final result = parseLinks(
        [
          realityLink,
          'ss://YWVz@example.org:8389',
          'мусор',
          'trojan://pass@example.org:443',
        ].join('\n'),
      );

      expect(result.links, hasLength(2));
      expect(result.skipped, hasLength(2));
      expect(result.skipped[0].line, 2);
      expect(result.skipped[0].scheme, 'ss');
      expect(result.skipped[1].line, 3);
      expect(result.skipped[1].scheme, 'неизвестно');
      expect(result.skipped[1].reason, isNotEmpty);
    });

    test('два слова в строке считаются двумя пропусками', () {
      final result = parseLinks('просто текст');

      expect(result.links, isEmpty);
      expect(result.skipped, hasLength(2));
      expect(result.skipped.every((skip) => skip.line == 1), isTrue);
    });

    test('пустой текст даёт пустой результат без ошибок', () {
      final result = parseLinks('  \n\n');

      expect(result.links, isEmpty);
      expect(result.skipped, isEmpty);
      expect(result.isEmpty, isTrue);
    });
  });

  group('фрагментация рукопожатия (Д2-20)', () {
    // Ровно та форма, что подтверждена прогонами ядра 26.3.27: интервал —
    // `delay`, тегов `handshake` и `interval` в сборке нет.
    const confirmedForm = {
      'tcp': [
        {
          'type': 'fragment',
          'settings': {
            'packets': 'tlshello',
            'length': '100-200',
            'delay': '10-20',
            'maxSplit': '2-8',
          },
        },
      ],
    };

    test('при выключенной опции конфиг не содержит finalmask', () {
      final outbound = outboundOf(parseShareLink(realityLink));

      expect(jsonEncode(outbound), isNot(contains('finalmask')));
      expect(
        (outbound['streamSettings'] as Map).containsKey('finalmask'),
        isFalse,
      );
    });

    test('при включённой опции — ровно подтверждённая форма', () {
      final outbound = parseShareLink(
        realityLink,
      ).toOutbound(tag: 'proxy', fragmentHandshake: true);

      expect((outbound['streamSettings'] as Map)['finalmask'], confirmedForm);
    });

    test('блок уходит только в tcp-транспорт', () {
      final ws = parseShareLink(
        vless(query: 'security=tls&type=ws&host=example.org&path=%2Fws'),
      ).toOutbound(fragmentHandshake: true);

      expect((ws['streamSettings'] as Map).containsKey('finalmask'), isFalse);
    });

    test('мёртвое поле packetEncoding не уходит в конфиг ядра', () {
      final link = parseShareLink(
        vless(query: 'security=none&packetEncoding=xudp'),
      );

      // Ссылка разбирается и сохраняется без потерь…
      expect(link.packetEncoding, 'xudp');
      expect(link.source, contains('packetEncoding=xudp'));
      // …но в vnext поля нет: сборка 26.3.27 его не читает.
      final outbound = link.toOutbound(tag: 'proxy', fragmentHandshake: true);
      final user =
          (((outbound['settings'] as Map)['vnext'] as List).first
                  as Map)['users']
              as List;

      expect((user.first as Map).containsKey('packetEncoding'), isFalse);
    });
  });
}
