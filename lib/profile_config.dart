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

/// Собирает конфиг ядра из разобранных ссылок — целиком в памяти.
///
/// Файл пользователя не создаётся и не читается: на диске оказывается только
/// служебный конфиг, который приложение пишет само перед запуском ядра.
/// Правила из [rules] встают **до** завершающего «всё в прокси», поэтому пресет
/// «напрямую» для своей страны работает, не меняя остальной трафик.
String buildConfigFromLinks(
  Iterable<ShareLink> links, {
  int httpPort = defaultHttpPort,
  int socksPort = defaultSocksPort,
  List<Map<String, dynamic>> rules = const [],
}) {
  final profiles = links.toList();
  if (profiles.isEmpty) {
    throw LinkFormatException('Нет ни одной ссылки для подключения');
  }

  return jsonEncode({
    'log': {'loglevel': 'warning'},
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
      'rules': [
        ...rules,
        {'type': 'field', 'network': 'tcp,udp', 'outboundTag': proxyTag},
      ],
    },
  });
}
