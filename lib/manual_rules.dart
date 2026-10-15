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

  /// Название направления для интерфейса.
  String get directionLabel =>
      outbound == directTag ? 'напрямую' : 'через подключение';

  /// Краткое описание условий для списка правил.
  String get summary => [
    for (final entry in conditions.entries)
      '${entry.key.title}: ${entry.value.join(', ')}',
  ].join(' · ');

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
