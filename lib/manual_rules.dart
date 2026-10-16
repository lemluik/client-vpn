import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'profile_config.dart';

/// Поля правила, которые принимает ядро.
///
/// Список измерен 16.10.2026 на Xray-core 26.3.27 (`xray run -test`):
/// `domain`, `ip`, `port`, `sourcePort`, `network`, `protocol`, `inboundTag`,
/// `source`, `user` — код 0; `packageName`, `package`, `processName`,
/// `ruleSet`, `overrides` и любое вымышленное имя — код 23 с текстом
/// «this rule has no effective fields». Поэтому редактор не предлагает условия
/// чужого ядра (sing-box), а показывает только эти девять: правило, собранное
/// здесь, ядро точно разберёт.
enum RuleField {
  /// Домены и коды geo-баз: `example.com`, `geosite:category-bank-ru`,
  /// `regexp:^.*\\.ru$`, `keyword:youtube`.
  domain('Домены', 'example.com, geosite:vk, keyword:youtube'),

  /// Адреса и сети назначения: `8.8.8.8`, `10.0.0.0/8`, `geoip:ru`.
  ip('Адреса назначения', '8.8.8.8, 192.168.0.0/16, geoip:ru'),

  /// Порт назначения: `443` или диапазон `8000-9000`.
  port('Порт назначения', '443 или 8000-9000', single: true),

  /// Порт на устройстве пользователя.
  sourcePort('Порт на устройстве', '1024-65535', single: true),

  /// Протокол транспорта: `tcp`, `udp` или `tcp,udp`.
  network('Сеть', 'tcp, udp или tcp,udp', single: true),

  /// Опознанный протокол соединения: `tls`, `http`, `bittorrent`, `ssh`.
  protocol('Протокол соединения', 'tls, http, bittorrent'),

  /// Адрес или сеть источника.
  source('Адрес источника', '192.168.1.20, 192.168.1.0/24'),

  /// Локальный вход ядра, с которого идёт трафик.
  inboundTag('Вход ядра', 'cvpn-http, cvpn-socks'),

  /// Пользователь входящего соединения.
  user('Пользователь', 'имя из ссылки подключения');

  const RuleField(this.title, this.hint, {this.single = false});

  /// Имя поля в интерфейсе.
  final String title;

  /// Имя поля в конфиге ядра.
  String get key => switch (this) {
    RuleField.domain => 'domain',
    RuleField.ip => 'ip',
    RuleField.port => 'port',
    RuleField.sourcePort => 'sourcePort',
    RuleField.network => 'network',
    RuleField.protocol => 'protocol',
    RuleField.source => 'source',
    RuleField.inboundTag => 'inboundTag',
    RuleField.user => 'user',
  };

  /// Подсказка в интерфейсе: какие значения сюда пишут.
  final String hint;

  /// Поле принимает одну строку, а не список (так в схеме ядра).
  final bool single;
}

/// Правило маршрутизации, которое составил пользователь.
///
/// Хранится как данные, а не как код: правило — это набор условий и
/// направление. Адресов нашего сервиса здесь нет и быть не может (гейт У-8) —
/// направление выбирается из двух тегов ядра, `cvpn-direct` и `cvpn-proxy`.
class ManualRule {
  const ManualRule({
    required this.id,
    required this.title,
    required this.outbound,
    required this.conditions,
    this.enabled = true,
  });

  final String id;

  /// Название только для интерфейса: в конфиг ядро оно не попадает.
  final String title;

  /// Куда идёт совпавший трафик: `directTag` или `proxyTag`.
  final String outbound;

  final bool enabled;

  /// Условия. Пустых списков здесь не держим: см. [validate].
  final Map<RuleField, List<String>> conditions;

  /// Идентификатор нового правила: время создания в микросекундах.
  static String newId() => DateTime.now().microsecondsSinceEpoch.toString();

  static ManualRule? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final title = value['title'];
    final outbound = value['outbound'];
    final raw = value['conditions'];
    if (id is! String || title is! String || outbound is! String) return null;
    if (outbound != directTag && outbound != proxyTag) return null;
    if (raw is! Map) return null;
    final conditions = <RuleField, List<String>>{};
    for (final entry in raw.entries) {
      // Неизвестное поле выбрасывается, а не переносится в ближайшее: правило
      // из сохранённого файла не должно внезапно начать ловить другой трафик.
      RuleField? field;
      for (final candidate in RuleField.values) {
        if (candidate.key == entry.key) field = candidate;
      }
      final values = entry.value;
      if (field == null || values is! List) continue;
      final cleaned = [
        for (final value in values)
          if (value is String && value.trim().isNotEmpty) value.trim(),
      ];
      if (cleaned.isNotEmpty) conditions[field] = cleaned;
    }
    return ManualRule(
      id: id,
      title: title,
      outbound: outbound,
      conditions: conditions,
      enabled: value['enabled'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'outbound': outbound,
    if (!enabled) 'enabled': false,
    'conditions': {
      for (final entry in conditions.entries) entry.key.key: entry.value,
    },
  };

  /// Правила ядра: только непустые условия и направление.
  ///
  /// Ядро читает `port` и `sourcePort` строкой, а не списком, — эти поля
  /// склеиваются через запятую.
  Map<String, dynamic> toXrayRule() {
    final rule = <String, dynamic>{'type': 'field'};
    for (final entry in conditions.entries) {
      final field = entry.key;
      final values = entry.value;
      if (values.isEmpty) continue;
      rule[field.key] = field.single ? values.join(',') : values;
    }
    rule['outboundTag'] = outbound;
    return rule;
  }

  /// Правила, собранные из списка, в том порядке, в котором их видит
  /// пользователь. Выключенные правила в конфиг не идут.
  static List<Map<String, dynamic>> xrayRules(List<ManualRule> rules) => [
    for (final rule in rules)
      if (rule.enabled && rule.validate() == null) rule.toXrayRule(),
  ];

  /// Id правила, которое держит список исключений по адресам.
  ///
  /// Исключения живут в том же хранилище, что и правила редактора
  /// (`routing.rules.v1`), а не в отдельном ключе: второе хранилище расходится
  /// с первым, и пользователь получает два разных ответа на один вопрос.
  static const String splitDirectId = 'split.direct';
  static const String splitTunnelId = 'split.tunnel';

  /// Хосты сохранённого списка исключений для одного направления.
  static List<String> splitHosts(List<ManualRule> rules, String id) {
    for (final rule in rules) {
      if (rule.id == id) {
        return List.of(rule.conditions[RuleField.domain] ?? const []);
      }
    }
    return const [];
  }

  /// Заменяет список исключений, не трогая остальные правила.
  ///
  /// Пустой список не оставляет правила в списке: иначе в редакторе висит
  /// правило без условия, а ядро такое отвергает.
  static List<ManualRule> withSplitHosts(
    List<ManualRule> rules, {
    required List<String> direct,
    required List<String> tunnel,
    required String directTitle,
    required String tunnelTitle,
  }) {
    final kept = [
      for (final rule in rules)
        if (rule.id != splitDirectId && rule.id != splitTunnelId) rule,
    ];
    if (direct.isNotEmpty) {
      kept.add(
        ManualRule(
          id: splitDirectId,
          title: directTitle,
          outbound: directTag,
          conditions: {RuleField.domain: direct},
        ),
      );
    }
    if (tunnel.isNotEmpty) {
      kept.add(
        ManualRule(
          id: splitTunnelId,
          title: tunnelTitle,
          outbound: proxyTag,
          conditions: {RuleField.domain: tunnel},
        ),
      );
    }
    return kept;
  }

  /// Название направления для интерфейса.
  String get directionLabel =>
      outbound == directTag ? 'напрямую' : 'через подключение';

  /// Краткое описание условий для списка правил.
  ///
  /// Список значений может быть длинным: исключения домашнего региона
  /// хранятся одним правилом на сотни хостов, а строка интерфейса не должна
  /// растягиваться на весь экран. Показываем начало и счётчик остатка.
  String get summary => [
    for (final entry in conditions.entries)
      '${entry.key.title}: ${_brief(entry.value)}',
  ].join(' · ');

  static String _brief(List<String> values) {
    const limit = 4;
    if (values.length <= limit) return values.join(', ');
    return '${values.take(limit).join(', ')} и ещё ${values.length - limit}';
  }

  /// Причина, почему правило нельзя применить, или null.
  ///
  /// Проверка повторяет то, за что ядро отвергает конфиг (замер 16.10.2026):
  /// правило без условия. Значения полей здесь не проверяются на смысл —
  /// неизвестный код geo-базы или кривой порт ядро ловит сам при `_core.validate`
  /// перед подключением, и пользователь видит его текст в журнале.
  String? validate() {
    if (title.trim().isEmpty) return 'ruleTitleRequired';
    if (conditions.isEmpty) return 'ruleNeedsCondition';
    for (final entry in conditions.entries) {
      if (entry.value.any((value) => value.trim().isEmpty)) {
        return 'ruleEmptyValue';
      }
      if (entry.key == RuleField.port || entry.key == RuleField.sourcePort) {
        for (final value in entry.value) {
          if (!_portsValid(value.trim())) return 'ruleBadPort';
        }
      }
    }
    return null;
  }

  /// Порт или диапазон `от-до`: числа от 1 до 65535.
  static bool _portsValid(String value) {
    final parts = value.split('-');
    if (parts.length > 2 ||
        parts.any((part) => !_numberPattern.hasMatch(part))) {
      return false;
    }
    final numbers = parts.map(int.parse).toList();
    if (numbers.any((number) => number < 1 || number > 65535)) return false;
    return numbers.length == 1 || numbers.first <= numbers.last;
  }

  static final _numberPattern = RegExp(r'^\d{1,5}$');
}

/// Хранение правил пользователя на устройстве.
///
/// Формат — JSON в локальных настройках. Дорожная карта предполагала
/// protobuf-формат «из кодовой базы», но в этом дереве protobuf нет: правила
/// здесь — обычные Map'ы конфига ядра, а сериализует их `jsonEncode`
/// (см. 03_Клиент/ПРАВИЛА_И_ПРЕСЕТЫ.md).
class RuleStore {
  const RuleStore(this._prefs);

  static const _key = 'routing.rules.v1';

  final SharedPreferences _prefs;

  List<ManualRule> load() {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) return const [];
    final rules = <ManualRule>[];
    for (final item in decoded) {
      final rule = ManualRule.fromJson(item);
      if (rule != null) rules.add(rule);
    }
    return rules;
  }

  Future<void> save(List<ManualRule> rules) =>
      _prefs.setString(_key, jsonEncode([for (final r in rules) r.toJson()]));
}

/// Результат вставки списка адресов пачкой.
class PastedHosts {
  const PastedHosts({
    required this.hosts,
    required this.duplicates,
    required this.skipped,
  });

  /// Хосты в том виде, в котором их видит ядро: ASCII, без схемы и пути.
  final List<String> hosts;

  /// Сколько раз хост уже был в списке.
  final int duplicates;

  /// Строки, из которых хост достать не удалось (не считая пустых).
  final int skipped;
}

/// Разбор пачки ссылок и доменов в список адресов-исключений.
///
/// Из строки `https://example.com/path?q=1` берётся только хост: правило
/// маршрутизации сравнивает имя хоста, а путь и запрос ядру не показаны.
/// Пустые строки не считаются пропущенными — это перевод строки, а не ошибка.
PastedHosts parseHostBlock(String block) {
  final hosts = <String>[];
  var duplicates = 0;
  var skipped = 0;
  for (final line in block.split('\n')) {
    if (line.trim().isEmpty) continue;
    final host = exceptionHost(line);
    if (host == null) {
      skipped++;
      continue;
    }
    if (hosts.contains(host)) {
      duplicates++;
      continue;
    }
    hosts.add(host);
  }
  return PastedHosts(hosts: hosts, duplicates: duplicates, skipped: skipped);
}

/// Хост из одной строки: ссылка, домен, поддомен или имя с кириллицей.
///
/// Имя с не-ASCII метками возвращается в punycode: только в таком виде его
/// присылает браузер и только так оно совпадает с правилом ядра
/// (замер 16.10.2026: `www.рф` приходит как `www.xn--p1ai`, а кириллическое
/// имя SOCKS-вход отвергает).
String? exceptionHost(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  var host = Uri.tryParse(
    value.contains('://') ? value : 'http://$value',
  )?.host;
  if (host == null || host.isEmpty) {
    // Голый адрес со Scheme, которого Uri не увидел: отрезаем всё после имени.
    host = value.split(RegExp(r'[/\s?#:]')).first;
  }
  if (host.startsWith('*.')) host = host.substring(2);
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  try {
    // `Uri.host` кириллицу percent-кодирует — возвращаем имя как было.
    host = Uri.decodeComponent(host);
  } on ArgumentError {
    return null;
  }
  // Понижаем регистр уже после распаковки: `Uri.host` отдаёт `%D0%A1`, и
  // `toLowerCase` до распаковки трогает только шестнадцатеричные цифры, а
  // заглавная `СПБ.РФ` доходит до punycode заглавной и никогда не совпадёт
  // с тем, что пришлёт браузер.
  host = host.toLowerCase();
  final labels = host.split('.');
  if (labels.length < 2) return null;
  final top = labels.last;
  // Числовая «зона» — это адрес, а не домен: правило по имени его не ловит.
  if (top.length < 2 || _digitOnly.hasMatch(top)) return null;
  final ascii = [for (final label in labels) idnAsciiLabel(label)];
  if (ascii.any((label) => label == null)) return null;
  return ascii.cast<String>().join('.');
}

final RegExp _digitOnly = RegExp(r'^[0-9]+$');

/// Метка домена в ASCII: как есть либо в punycode.
///
/// null — если метка не является именем хоста или смешивает кириллицу с
/// латиницей. Наружу эта функция нужна пресету: зону домашнего региона
/// пользователь видит как `рф`, а ядро должно получить `xn--p1ai`.
String? idnAsciiLabel(String label) {
  if (label.isEmpty) return null;
  final lowered = label.toLowerCase();
  if (lowered.codeUnits.every((unit) => unit < 0x80)) {
    return _labelPattern.hasMatch(lowered) ? lowered : null;
  }
  if (lowered.runes.any((value) => value < 0x80)) return null;
  return 'xn--${_punycodeEncode(lowered)}';
}

/// Метка без символов, которых в имени хоста быть не может.
final RegExp _labelPattern = RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$');

/// Кодирование метки в punycode по RFC 3492.
///
/// Своей реализацией, а не зависимостью: пакет IDNA потянул бы за собой
/// лицензию и вес ради одной функции, а `Uri.host` в Dart кириллицу
/// percent-кодирует, а доменному имени нужен punycode.
String _punycodeEncode(String input) {
  const base = 36, tMin = 1, tMax = 26;
  const initialBias = 72, initialN = 128;
  final codePoints = input.runes.toList();
  final out = StringBuffer();
  var bias = initialBias;
  var n = initialN;
  var delta = 0;
  final basic = codePoints.where((value) => value < initialN).toList();
  if (basic.isNotEmpty) {
    out
      ..write(String.fromCharCodes(basic))
      ..write('-');
  }
  var handled = basic.length;
  while (handled < codePoints.length) {
    var m = 0x7fffffff;
    for (final value in codePoints) {
      if (value >= n && value < m) m = value;
    }
    delta += (m - n) * (handled + 1);
    n = m;
    for (final value in codePoints) {
      if (value < n) {
        delta++;
      } else if (value == n) {
        var q = delta;
        for (var k = base; ; k += base) {
          final t = k <= bias
              ? tMin
              : k >= bias + tMax
              ? tMax
              : k - bias;
          if (q < t) break;
          out.writeCharCode(_punycodeDigit(t + (q - t) % (base - t)));
          q = (q - t) ~/ (base - t);
        }
        out.writeCharCode(_punycodeDigit(q));
        bias = _punycodeAdapt(delta, handled + 1, handled == basic.length);
        delta = 0;
      }
    }
    delta++;
    n++;
    handled++;
  }
  return out.toString();
}

int _punycodeDigit(int value) => value < 26 ? 97 + value : 48 + value - 26;

int _punycodeAdapt(int delta, int points, bool firstTime) {
  const base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700;
  var rest = firstTime ? delta ~/ damp : delta ~/ 2;
  rest += rest ~/ points;
  var k = 0;
  while (rest > ((base - tMin) * tMax) ~/ 2) {
    rest ~/= base - tMin;
    k += base;
  }
  return k + ((base - tMin + 1) * rest) ~/ (rest + skew);
}
