import 'dart:convert';

import 'share_link.dart';

/// Тег первого исходящего соединения. На него ссылается завершающее правило
/// маршрутизации, и его же интерфейс показывает как текущий путь.
const String proxyTag = 'cvpn-proxy';

/// Тег исходящего «напрямую» — для правил-исключений, например пресета страны.
const String directTag = 'cvpn-direct';

/// Порты локальной точки входа по умолчанию: их подхватывает системный прокси.
const int defaultHttpPort = 10808;
const int defaultSocksPort = 10809;

/// Тег исходящего соединения для профиля с номером [index].
String tagForProfile(int index) =>
    index == 0 ? proxyTag : '$proxyTag-${index + 1}';

/// Балансировщик, которому доверен outbound с тегом [tag], или null.
///
/// Ядро читает `balancers` только внутри `routing` и берёт узлы из `selector`.
/// Балансировщик без нашего узла в списке не годится: правило на него отдало бы
/// трафик узлам, которые пользователь для этого пути не выбирал.
String? balancerTagFor(Object? balancers, String tag) {
  if (balancers is! List) return null;
  for (final balancer in balancers) {
    if (balancer is! Map) continue;
    final name = balancer['tag'];
    if (name is! String || name.isEmpty) continue;
    final selector = balancer['selector'];
    if (selector is List && selector.contains(tag)) return name;
  }
  return null;
}

/// Завершающее правило маршрутизации: весь остальной трафик — на прокси.
///
/// При объявленном балансировщике правило ссылается на него (`balancerTag`),
/// а не на метку первого исходящего соединения: иначе узлы региона,
/// собранные в балансировщик, никогда не выбирались бы ядром.
Map<String, dynamic> terminalRule(String tag, {Object? balancers}) {
  final balancer = balancerTagFor(balancers, tag);
  if (balancer != null) {
    return {'type': 'field', 'network': 'tcp,udp', 'balancerTag': balancer};
  }
  return {'type': 'field', 'network': 'tcp,udp', 'outboundTag': tag};
}

/// Собирает конфиг ядра из разобранных ссылок — целиком в памяти.
///
/// Файл пользователя не создаётся и не читается: на диске оказывается только
/// служебный конфиг, который приложение пишет само перед запуском ядра.
/// Правила из [rules] встают **до** завершающего «всё в прокси», поэтому пресет
/// «напрямую» для своей страны работает, не меняя остальной трафик.
/// Балансировщики из [balancers] остаются внутри `routing` — только там их
/// читает ядро, — и завершающее правило начинает ссылаться на них.
/// Блоки [observatory] и [burstObservatory] встают на верхнем уровне: без
/// наблюдателя ядро не принимает явную стратегию балансировщика.
String buildConfigFromLinks(
  Iterable<ShareLink> links, {
  int httpPort = defaultHttpPort,
  int socksPort = defaultSocksPort,
  List<Map<String, dynamic>> rules = const [],
  List<Map<String, dynamic>> balancers = const [],
  Map<String, dynamic>? observatory,
  Map<String, dynamic>? burstObservatory,
}) {
  final profiles = links.toList();
  if (profiles.isEmpty) {
    throw LinkFormatException('Нет ни одной ссылки для подключения');
  }

  return jsonEncode({
    'log': {'loglevel': 'warning'},
    'observatory': ?observatory,
    'burstObservatory': ?burstObservatory,
    'inbounds': [
      {
        'protocol': 'http',
        'listen': '127.0.0.1',
        'port': httpPort,
        'tag': 'cvpn-http',
      },
      {
        'protocol': 'socks',
        'listen': '127.0.0.1',
        'port': socksPort,
        'tag': 'cvpn-socks',
        'settings': {'udp': true},
      },
    ],
    'outbounds': [
      for (final (index, link) in profiles.indexed)
        link.toOutbound(tag: tagForProfile(index)),
      {'protocol': 'freedom', 'tag': directTag},
    ],
    // `AsIs` принудительно: ядро не должно резолвить домены на устройстве,
    // иначе запрос уйдёт в открытый DNS мимо туннеля.
    'routing': {
      'domainStrategy': 'AsIs',
      if (balancers.isNotEmpty) 'balancers': balancers,
      'rules': [...rules, terminalRule(proxyTag, balancers: balancers)],
    },
  });
}
