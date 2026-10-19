import 'dart:io';

import 'package:client_vpn/mac_system_proxy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Поддельный `networksetup`: держит настройки служб в памяти и отвечает
/// в том же текстовом виде, что настоящий.
class FakeNetworkSetup {
  FakeNetworkSetup(List<String> services, {List<String> disabled = const []})
    : _services = services,
      _disabled = disabled {
    for (final s in services) {
      proxies[s] = {
        'web': MacProxyEntry.off,
        'secureweb': MacProxyEntry.off,
        'socksfirewall': MacProxyEntry.off,
      };
      bypass[s] = ['*.local', '169.254/16'];
    }
  }

  List<String> _services;
  final List<String> _disabled;
  final Map<String, Map<String, MacProxyEntry>> proxies = {};
  final Map<String, List<String>> bypass = {};
  final List<List<String>> calls = [];

  void removeService(String s) =>
      _services = _services.where((x) => x != s).toList();

  Future<ProcessResult> call(List<String> args) async {
    calls.add(args);
    final cmd = args.first;
    String out = '';
    if (cmd == '-listallnetworkservices') {
      out = [
        'An asterisk (*) denotes that a network service is disabled.',
        ..._services,
        ..._disabled.map((s) => '*$s'),
      ].join('\n');
    } else if (RegExp(
      r'^-get(web|secureweb|socksfirewall)proxy$',
    ).hasMatch(cmd)) {
      final kind = cmd.substring(4, cmd.length - 5);
      final e = proxies[args[1]]![kind]!;
      out =
          'Enabled: ${e.enabled ? 'Yes' : 'No'}\nServer: ${e.server}\n'
          'Port: ${e.port}\nAuthenticated Proxy Enabled: 0\n';
    } else if (cmd == '-getproxybypassdomains') {
      final list = bypass[args[1]]!;
      out = list.isEmpty
          ? "There aren't any bypass domains set on ${args[1]}.\n"
          : '${list.join('\n')}\n';
    } else if (RegExp(
      r'^-set(web|secureweb|socksfirewall)proxy$',
    ).hasMatch(cmd)) {
      final kind = cmd.substring(4, cmd.length - 5);
      // Настоящий networksetup при -setwebproxy сразу включает прокси;
      // нужное состояние код выставляет следующей командой.
      proxies[args[1]]![kind] = MacProxyEntry(
        enabled: true,
        server: args[2],
        port: int.tryParse(args[3]) ?? 0,
      );
    } else if (RegExp(
      r'^-set(web|secureweb|socksfirewall)proxystate$',
    ).hasMatch(cmd)) {
      final kind = cmd.substring(4, cmd.length - 10);
      final e = proxies[args[1]]![kind]!;
      proxies[args[1]]![kind] = MacProxyEntry(
        enabled: args[2] == 'on',
        server: e.server,
        port: e.port,
      );
    } else if (cmd == '-setproxybypassdomains') {
      final rest = args.sublist(2);
      bypass[args[1]] = rest.length == 1 && rest.first == 'Empty' ? [] : rest;
    } else {
      return ProcessResult(0, 1, '', 'unknown $cmd');
    }
    return ProcessResult(0, 0, out, '');
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('список служб без пояснения и выключенных', () {
    expect(
      MacSystemProxy.parseServices(
        'An asterisk (*) denotes that a network service is disabled.\n'
        'Wi-Fi\nUSB 10/100 LAN\n*Thunderbolt Bridge\n',
      ),
      ['Wi-Fi', 'USB 10/100 LAN'],
    );
  });

  test('разбор прокси и пустых исключений', () {
    expect(
      MacProxyEntry.parse(
        'Enabled: Yes\nServer: 10.0.0.1\nPort: 3128\n'
        'Authenticated Proxy Enabled: 0\n',
      ),
      const MacProxyEntry(enabled: true, server: '10.0.0.1', port: 3128),
    );
    expect(
      MacProxyEntry.parse('Enabled: No\nServer: \nPort: 0\n'),
      MacProxyEntry.off,
    );
    expect(
      MacSystemProxy.parseBypass(
        "There aren't any bypass domains set on Wi-Fi.\n",
      ),
      isEmpty,
    );
  });

  test('локальные исключения дописываются без дублей', () {
    expect(MacSystemProxy.withLocalBypass(['*.local', 'corp.example']), [
      '*.local',
      'corp.example',
      'localhost',
      '127.0.0.1',
      '::1',
      '169.254/16',
    ]);
  });

  test('http: включается на всех службах и возвращается как было', () async {
    final fake = FakeNetworkSetup(['Wi-Fi', 'Ethernet'], disabled: ['VPN']);
    fake.proxies['Ethernet']!['web'] = const MacProxyEntry(
      enabled: false,
      server: 'proxy.corp',
      port: 3128,
    );
    final proxy = MacSystemProxy(run: fake.call);

    await proxy.enable('127.0.0.1', 10808);

    for (final s in ['Wi-Fi', 'Ethernet']) {
      expect(
        fake.proxies[s]!['web'],
        const MacProxyEntry(enabled: true, server: '127.0.0.1', port: 10808),
      );
      expect(fake.proxies[s]!['secureweb']!.enabled, isTrue);
      expect(fake.proxies[s]!['socksfirewall']!.enabled, isFalse);
      expect(fake.bypass[s], contains('localhost'));
    }
    expect(fake.calls.any((c) => c.contains('VPN')), isFalse);

    await proxy.disable();

    expect(fake.proxies['Wi-Fi']!['web'], MacProxyEntry.off);
    expect(fake.proxies['Wi-Fi']!['secureweb'], MacProxyEntry.off);
    expect(
      fake.proxies['Ethernet']!['web'],
      const MacProxyEntry(enabled: false, server: 'proxy.corp', port: 3128),
    );
    expect(fake.bypass['Wi-Fi'], ['*.local', '169.254/16']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });

  test('socks включает только SOCKS-прокси', () async {
    final fake = FakeNetworkSetup(['Wi-Fi']);
    final proxy = MacSystemProxy(run: fake.call);

    await proxy.enable('127.0.0.1', 10808, socks: true);

    expect(fake.proxies['Wi-Fi']!['socksfirewall']!.enabled, isTrue);
    expect(fake.proxies['Wi-Fi']!['web']!.enabled, isFalse);
  });

  test('повторное включение не затирает снимок пользователя', () async {
    final fake = FakeNetworkSetup(['Wi-Fi']);
    final proxy = MacSystemProxy(run: fake.call);

    await proxy.enable('127.0.0.1', 10808);
    await proxy.enable('127.0.0.1', 10809);
    await proxy.disable();

    expect(fake.proxies['Wi-Fi']!['web']!.enabled, isFalse);
  });

  test('пропавшая служба при отключении пропускается', () async {
    final fake = FakeNetworkSetup(['Wi-Fi', 'iPhone USB']);
    final proxy = MacSystemProxy(run: fake.call);

    await proxy.enable('127.0.0.1', 10808);
    fake.removeService('iPhone USB');
    await proxy.disable();

    expect(fake.proxies['Wi-Fi']!['web']!.enabled, isFalse);
  });

  test('килл-свитч держит наш прокси, а авария снимается при старте', () async {
    final fake = FakeNetworkSetup(['Wi-Fi']);
    final proxy = MacSystemProxy(run: fake.call);

    await proxy.enable('127.0.0.1', 10808);
    // Пользователь или система сбросили прокси, пока ядро падало.
    fake.proxies['Wi-Fi']!['web'] = MacProxyEntry.off;
    await proxy.lockLeak();
    expect(
      fake.proxies['Wi-Fi']!['web'],
      const MacProxyEntry(enabled: true, server: '127.0.0.1', port: 10808),
    );

    await MacSystemProxy(run: fake.call).cleanupAfterCrash();
    expect(fake.proxies['Wi-Fi']!['web']!.enabled, isFalse);
    expect(fake.bypass['Wi-Fi'], ['*.local', '169.254/16']);
  });

  test('чужой прокси после аварии не трогается', () async {
    final fake = FakeNetworkSetup(['Wi-Fi']);
    final proxy = MacSystemProxy(run: fake.call);

    await proxy.enable('127.0.0.1', 10808);
    const other = MacProxyEntry(
      enabled: true,
      server: '127.0.0.1',
      port: 9090,
    );
    fake.proxies['Wi-Fi']!['web'] = other;

    await proxy.cleanupAfterCrash();

    expect(fake.proxies['Wi-Fi']!['web'], other);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });

  test('отключение без нашего включения ничего не делает', () async {
    final fake = FakeNetworkSetup(['Wi-Fi']);
    await MacSystemProxy(run: fake.call).disable();
    expect(fake.calls, isEmpty);
  });
}
