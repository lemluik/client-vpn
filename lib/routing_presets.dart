import 'package:shared_preferences/shared_preferences.dart';

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
  });

  /// Ключ для хранения выбора: `'none'`, `'ru'`.
  final String key;

  /// Название пресета для интерфейса.
  final String label;

  /// Язык устройства, для которого пресет предлагается по умолчанию:
  /// пустая строка — не предлагается.
  final String language;

  /// Правила встают перед завершающим «всё в прокси».
  final List<Map<String, dynamic>> rules;

  bool get isOff => rules.isEmpty;
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
/// своего списка доменов здесь пока нет.
const RoutingPreset ruPreset = RoutingPreset(
  key: 'ru',
  label: 'Россия напрямую',
  language: 'ru',
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
      'domain': [
        'geosite:category-bank-ru',
        'geosite:category-gov-ru',
      ],
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
