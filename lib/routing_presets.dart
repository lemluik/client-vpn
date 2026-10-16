import 'package:shared_preferences/shared_preferences.dart';

import 'manual_rules.dart';
import 'profile_config.dart';

/// Пресет маршрутизации: готовые правила «часть трафика идёт напрямую».
///
/// Клиент универсальный, поэтому пресет не привязан к нашему сервису: это
/// только коды из geo-баз ядра и направление `freedom`. Пользователь выбирает
/// пресет сам, выбор хранится на устройстве и никуда не отправляется.
class RoutingPreset {
  const RoutingPreset({
    required this.key,
    required this.label,
    required this.rules,
    this.language = '',
    this.homeDomains = const [],
  });

  /// Ключ для хранения выбора: `'none'`, `'ru'`.
  final String key;

  /// Название пресета для интерфейса.
  final String label;

  /// Язык устройства, для которого пресет предлагается по умолчанию:
  /// пустая строка — не предлагается.
  final String language;

  /// Правила, общие для всей страны: адреса и домены из geo-баз ядра.
  final List<Map<String, dynamic>> rules;

  /// Доменные зоны домашнего региона без ведущей точки: `('ru', 'su', 'рф')`.
  ///
  /// Это данные пресета, а не перечень в коде сборщика: новый регион приносит
  /// свои зоны. Пишутся в том виде, в каком их видит пользователь, а в правило
  /// ядра уходят в punycode (см. [idnAsciiLabel]).
  ///
  /// Форма записи выбрана замером на ядре 26.3.27 (`xray run`, живая запись
  /// доступа, 16.10.2026):
  /// - зона без точки (`ru`) ядро читает как подстроку: `ru.example.com`
  ///   попадает в правило, хотя это не зона `.ru`;
  /// - зона с ведущей точкой (`.ru`) — суффикс домена: совпадает `www.cbr.ru`
  ///   и `cbr.ru`, а `ru.example.com` остаётся в туннеле;
  /// - `full:` совпадает только с ровно этим именем, то есть зону не закрывает;
  /// - `regexp:\.ru$` работает так же, как ведущая точка, но дороже;
  /// - `keyword:` запрещён тем же замером: ловит подстроку.
  ///
  /// Кириллическую зону ядро получает **только** в punycode: браузер присылает
  /// `xn--p1ai`, а имя хоста в кириллице SOCKS-вход отвергает как «invalid
  /// domain name». Запись `.рф` в поле `domain` в этой сборке не просто не
  /// работает — она рвёт запуск: паника `index out of range` в
  /// `common/strmatcher`, и на `run`, и на `run -test` (замер 16.10.2026).
  final List<String> homeDomains;

  bool get isOff => rules.isEmpty && homeDomains.isEmpty;

  /// Есть ли у пресета зоны: на них держится переключатель «сайты домашнего
  /// региона напрямую».
  bool get hasHomeDomains => homeDomains.isNotEmpty;

  /// Зоны для интерфейса: как их написал автор пресета.
  String get homeDomainsLabel => homeDomains.join(', ');

  /// Правила пресета целиком, с зонным правилом домашнего региона.
  ///
  /// Зоны идут отдельным правилом, а не дописываются в перечень geo-кодов:
  /// geo-кода для целой зоны в базах ядра нет (замер 15.10.2026:
  /// `code not found in geosite.dat: RU`). Зона, которую не удалось перевести
  /// в punycode, в правило не идёт: кириллическая запись обрушивает запуск
  /// ядра, а молча пропущенная зона — только покрытие.
  List<Map<String, dynamic>> get effectiveRules {
    if (homeDomains.isEmpty) return rules;
    final matchers = [
      for (final zone in homeDomains)
        if (idnAsciiLabel(zone.toLowerCase()) case final String ascii)
          '.$ascii',
    ];
    if (matchers.isEmpty) return rules;
    return [
      ...rules,
      {'type': 'field', 'domain': matchers, 'outboundTag': directTag},
    ];
  }

  /// Правила пресета плюс правила пользователя — в том порядке, который
  /// отдаётся ядру.
  ///
  /// Пресет идёт перед правилами «напрямую»: он описывает страну целиком, а
  /// правило пользователя — уточнение, обычно более узкое. Ядро берёт первое
  /// совпадение, поэтому порядок сверху вниз и есть приоритет.
  ///
  /// Правила «в туннель» стоят перед пресетом. Иначе исключение вида
  /// `example.ru` в туннель перекрывалось бы зонным правилом `.ru`, и пользователь
  /// не мог бы вернуть свой же адрес в туннель.
  List<Map<String, dynamic>> rulesWith(List<ManualRule> manual) {
    final tunnel = <Map<String, dynamic>>[];
    final direct = <Map<String, dynamic>>[];
    for (final rule in manual) {
      if (!rule.enabled || rule.validate() != null) continue;
      (rule.outbound == proxyTag ? tunnel : direct).add(rule.toXrayRule());
    }
    return [...tunnel, ...effectiveRules, ...direct];
  }
}

/// «Россия напрямую»: адреса РФ и домены отечественных сервисов.
///
/// Единого кода `geosite:ru` в geo-базах 26.3.27 нет (замер 15.10.2026: ядро
/// отвечает `code not found in geosite.dat: RU`), поэтому перечень собран из
/// отдельных кодов брендов. При `domainStrategy: AsIs`, который клиент ставит
/// принудительно, правило по IP срабатывает только на адрес в буквальном виде:
/// домены закрывает перечень `geosite:`.
///
/// Банки и госуслуги взяты кодами `category-bank-ru` и `category-gov-ru` из тех
/// же geo-баз (замер 16.10.2026 по `geosite.dat` сборки ядра 26.3.27: 19 и 128
/// доменов; в банковском перечне есть `sberbank.ru`, `vtb.ru`, `alfabank.ru`,
/// `tbank.ru`, но нет `tinkoff.ru`, `sbol.ru`, `vtbrussia.ru`, `mossport.ru`).
/// Чем пополнять пробелы и кто это обновляет — нерешённый вопрос Р-27, поэтому
/// своего списка доменов здесь нет: пробел закрывает правило по зонам
/// (`homeDomains`) — оно берёт в стране всё, а не перечень ведущихся сервисов.
///
/// Адресное правило `geoip:ru` на домен не действует при `domainStrategy: AsIs`
/// (замер 16.10.2026): домен ещё не разрешён, сравнивать ядру не с чем. Именно
/// поэтому зоны пишутся отдельным доменным правилом, а не надеются на geoip.
const RoutingPreset ruPreset = RoutingPreset(
  key: 'ru',
  label: 'Россия напрямую',
  language: 'ru',
  homeDomains: ['ru', 'su', 'рф'],
  rules: [
    {
      'type': 'field',
      'ip': ['geoip:ru'],
      'outboundTag': directTag,
    },
    {
      'type': 'field',
      'domain': [
        'geosite:yandex',
        'geosite:vk',
        'geosite:mailru',
        'geosite:ok',
        'geosite:rutube',
        'geosite:kinopoisk',
        'geosite:avito',
        'geosite:ozon',
        'geosite:wildberries',
        'geosite:x5',
      ],
      'outboundTag': directTag,
    },
    {
      // Банки и госуслуги берутся кодами из geo-баз ядра, а не списком, который
      // кто-то ведёт в этом репозитории: у чужого перечня есть период обновления
      // и своя ответственность за устаревание (см. вопрос Р-27).
      'type': 'field',
      'domain': ['geosite:category-bank-ru', 'geosite:category-gov-ru'],
      'outboundTag': directTag,
    },
    {
      'type': 'field',
      'ip': ['geoip:private'],
      'outboundTag': directTag,
    },
  ],
);

/// Без пресета: весь трафик идёт через подключение.
const RoutingPreset offPreset = RoutingPreset(
  key: 'none',
  label: 'Выключено',
  rules: [],
);

/// Все доступные пресеты. Новый пресет страны — только с кодами, которые
/// проверены на geo-базах этой сборки ядра.
const List<RoutingPreset> routingPresets = [offPreset, ruPreset];

/// Пресет по ключу; неизвестный ключ — выключенный пресет.
RoutingPreset presetByKey(Object? key) {
  for (final preset in routingPresets) {
    if (preset.key == key) return preset;
  }
  return offPreset;
}

/// Пресет, предлагаемый по умолчанию для языка устройства.
///
/// Определение идёт от локали системы: это локальный факт, клиент ничего не
/// запрашивает в сети и никуда не сообщает.
RoutingPreset defaultPresetFor(String languageCode) {
  final code = languageCode.toLowerCase();
  for (final preset in routingPresets) {
    if (preset.language.isNotEmpty && code.startsWith(preset.language)) {
      return preset;
    }
  }
  return offPreset;
}

/// Хранение выбранного пресета на устройстве.
class PresetStore {
  const PresetStore(this._prefs);

  static const _key = 'routing.preset.v1';

  final SharedPreferences _prefs;

  /// Сохранённый выбор, а если выбора ещё не было — пресет по языку устройства.
  RoutingPreset load(String languageCode) {
    final saved = _prefs.getString(_key);
    if (saved == null) return defaultPresetFor(languageCode);
    return presetByKey(saved);
  }

  Future<void> save(String key) => _prefs.setString(_key, key);
}
