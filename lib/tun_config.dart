import 'dart:convert';

import 'profile_config.dart';
import 'proxy_config.dart';

/// Протоколы, которые действительно уводят трафик на сервер.
/// `freedom` и `blackhole` к ним не относятся: если такой outbound окажется
/// первым, весь трафик пойдёт напрямую — на Android это тихая утечка.
const Set<String> proxyProtocols = {
  'vless',
  'vmess',
  'trojan',
  'shadowsocks',
  'socks',
  'http',
  'wireguard',
};

/// Туннельный inbound, который ядро получает вместо локального прокси.
/// Дескриптор устройства ядро берёт из переменной окружения `xray.tun.fd`
/// (см. proxy/tun/tun_android.go в Xray-core 26.3.27).
Map<String, dynamic> tunInbound({String name = 'tun0', int mtu = 1500}) => {
      'protocol': 'tun',
      'settings': {'name': name, 'MTU': mtu},
      'sniffing': {
        'enabled': true,
        'destOverride': ['http', 'tls'],
      },
      'tag': 'tun-in',
    };

/// Локальный http-вход, через который собственный трафик приложения уходит в
/// туннель (ТД-15).
///
/// Протокол именно http, а не socks: `dart:io` ведёт `HttpClient` только через
/// http-прокси, поддержки SOCKS в библиотеке нет. Порт общий с десктопной
/// сборкой, чтобы точка входа была одна и та же на обеих платформах.
///
/// Вход слушает только петлевой адрес: остальным приложениям телефона он не
/// должен отдавать канал.
Map<String, dynamic> appProxyInbound({int port = defaultHttpPort}) => {
      'protocol': 'http',
      'listen': '127.0.0.1',
      'port': port,
      'tag': 'cvpn-app',
    };

/// Та же точка входа в виде, который нужен приложению (ТД-15).
ProxyEndpoint appProxyEndpoint({int port = defaultHttpPort}) =>
    (protocol: 'http', port: port);

/// Верхнеуровневые блоки, которые ядро читает отдельно от маршрутизации.
/// Без `dns` адрес не резолвится по настройкам пользователя, без
/// `observatory`/`burstObservatory` балансировщик не видит задержек, без
/// `policy` теряются лимиты соединений.
const List<String> passthroughKeys = [
  'dns',
  'observatory',
  'burstObservatory',
  'policy',
];

/// Перестраивает конфиг пользователя под Android.
///
/// Локальные http/socks inbound пользователя на мобильной платформе бесполезны
/// — системный туннель поднимает VpnService, и вместо них подставляется tun.
/// Один локальный вход всё же нужен: через него в туннель идёт собственный
/// трафик приложения (подписка и чат), иначе `HttpClient` ушёл бы напрямую:
/// он смотрит на переменные окружения, а не на настройки VPN.
/// Исходящие серверы берутся из конфига как есть, но
/// обязательно добавляется завершающее правило маршрутизации на прокси:
/// без него трафик без правил ушёл бы в outbound по умолчанию, которым
/// может оказаться `freedom`.
///
/// Бросает [FormatException], если документ не читается, и [Exception]
/// с текстом для пользователя, если в конфиге нет прокси.
String buildTunConfig(String userJson) {
  final decoded = jsonDecode(userJson);
  if (decoded is! Map) {
    throw const FormatException('Конфиг должен быть JSON-объектом');
  }

  final outbounds = decoded['outbounds'];
  if (outbounds is! List || outbounds.isEmpty) {
    throw const FormatException('В конфиге нет секции outbounds');
  }

  final index = _proxyIndex(outbounds);
  final proxy = outbounds[index] as Map;
  final tag = _tagOf(proxy);

  return jsonEncode({
    'log': {'loglevel': 'warning'},
    'inbounds': [tunInbound(), appProxyInbound()],
    'outbounds': _withTag(outbounds, index, tag),
    'routing': _routing(decoded['routing'], tag),
    for (final key in passthroughKeys)
      if (decoded[key] != null) key: decoded[key],
  });
}

/// Локальный inbound для проверки собранного туннельного конфига ядром.
///
/// `xray run -test` на Android не может открыть устройство туннеля: оно
/// передаётся ядру через переменную окружения `xray.tun.fd` только при реальном
/// запуске. Tun-вход меняется на socks — всё остальное, включая локальный вход
/// приложения, остаётся в проверке тем же кодом ядра, что и пойдёт в работу.
///
/// Снифинг с tun-входа переносится на замену: правило по `protocol:` без него
/// ядро не разрешает, а в работе он включён — иначе проверка отклоняла бы
/// конфиг, который на устройстве запускается.
String tunConfigForTest(String tunJson, {int port = 10810}) {
  final decoded = jsonDecode(tunJson);
  if (decoded is! Map) {
    throw const FormatException('Конфиг туннеля должен быть JSON-объектом');
  }
  final map = Map<String, dynamic>.from(decoded.cast<String, dynamic>());
  final inbounds = map['inbounds'] is List
      ? (map['inbounds'] as List).whereType<Map>().toList()
      : const <Map>[];
  Map? tun;
  for (final inbound in inbounds) {
    if (inbound['protocol'] == 'tun') {
      tun = inbound;
      break;
    }
  }
  final sniffing = tun?['sniffing'];
  // Остальные входы остаются: локальный вход приложения тоже должен пройти
  // проверку ядром.
  final kept = [
    for (final inbound in inbounds)
      if (inbound['protocol'] != 'tun')
        Map<String, dynamic>.from(inbound.cast<String, dynamic>()),
  ];
  map['inbounds'] = [
    {
      'listen': '127.0.0.1',
      'port': port,
      'protocol': 'socks',
      'settings': {'udp': true},
      'tag': 'test-in',
      'sniffing': ?sniffing,
    },
    ...kept,
  ];
  return jsonEncode(map);
}

int _proxyIndex(List<dynamic> outbounds) {
  for (var i = 0; i < outbounds.length; i++) {
    final outbound = outbounds[i];
    if (outbound is Map && proxyProtocols.contains(outbound['protocol'])) {
      return i;
    }
  }
  throw Exception(
    'В конфиге нет исходящего прокси-сервера — '
    'подключение подняло бы трафик напрямую.',
  );
}

String _tagOf(Map<dynamic, dynamic> outbound) {
  final tag = outbound['tag'];
  return tag is String && tag.isNotEmpty ? tag : 'cvpn-proxy';
}

/// Возвращает список outbound с гарантированно непустым тегом у прокси.
List<dynamic> _withTag(List<dynamic> outbounds, int index, String tag) {
  return [
    for (var i = 0; i < outbounds.length; i++)
      if (i == index) {...outbounds[i] as Map, 'tag': tag} else outbounds[i],
  ];
}

/// Правила пользователя плюс завершающее «всё в прокси».
///
/// `domainStrategy` принудительно `AsIs`: ядро не должно резолвить домены
/// на устройстве — это обошло бы туннель и раскрыло DNS.
/// Если пользовательский конфиг объявляет балансировщик с нашим узлом в
/// `selector`, завершающее правило ссылается на него: иначе автопереключение
/// внутри региона осталось бы объявленным, но не работающим.
Map<String, dynamic> _routing(dynamic userRouting, String proxyTag) {
  final routing = userRouting is Map
      ? Map<String, dynamic>.from(userRouting.cast<String, dynamic>())
      : <String, dynamic>{};

  final rules = routing['rules'];
  routing['domainStrategy'] = 'AsIs';
  routing['rules'] = [
    if (rules is List) ...rules,
    terminalRule(proxyTag, balancers: routing['balancers']),
  ];
  return routing;
}
