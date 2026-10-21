import 'package:shared_preferences/shared_preferences.dart';

/// Точка проб по умолчанию: адрес проверки доступности Google.
///
/// Значение нейтральное (У-3): клиент универсальный и работает с подпиской
/// любого провайдера, поэтому наш адрес в код не зашивается. Пользователь может
/// поменять точку в настройках.
const String defaultProbeEndpoint = 'https://www.gstatic.com/generate_204';

/// Тег балансировщика, который клиент строит внутри региона.
const String regionBalancerTag = 'cvpn-lb';

/// Проверяет адрес проб. Возвращает текст ошибки или null.
///
/// Принимаем только `http` и `https` с хостом: в настройках поле заполняет
/// пользователь, а ядро на плохой адрес отвечает только при запуске.
String? probeEndpointError(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return 'Укажите адрес точки проб';
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.isAbsolute || uri.host.isEmpty) {
    return 'Адрес должен начинаться с http:// или https://';
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return 'Адрес должен начинаться с http:// или https://';
  }
  return null;
}

/// Порог прилипания балансировщика, мс (МК-6).
///
/// Число измерено 16.10.2026 на двух живых узлах с этой машины: TCP-рукопожатие
/// 15 проб × 2 раунда — медианы 214 и 293 мс (разница ~79 мс), разброс внутри
/// узла до 52 мс, отдельные всплески до 200 мс. Порог 100 мс больше и медианной
/// разницы, и типового разброса: под шум переключения не происходит, а устойчиво
/// более медленный узел всё же проигрывает.
///
/// На автопереключение порог не влияет: замер 21.10.2026 на стенде `test/stand`
/// показал, что стратегия `leastPing` в ядре 26.3.27 значение `tolerance` не
/// применяет — с порогом 100 000 мс переход на живой узел происходит так же за
/// 5 с. Мёртвый узел выключает наблюдатель, а не порог.
const int regionToleranceMs = 100;

/// Интервал проб наблюдателя.
///
/// Строка, а не число: ядро 26.3.27 разбирает `probeInterval` как длительность и
/// на `10` отвечает `invalid duration` — конфиг не запускается вовсе.
const String regionProbeInterval = '10s';

/// Балансировщик узлов региона — второй уровень автопереключения (МК-6).
///
/// Один узел — балансировщика нет: выбирать не из чего, и завершающее правило
/// остаётся на `outboundTag`. `fallbackTag` не ставим: запасной путь на
/// `freedom` означал бы утечку трафика напрямую при мёртвых узлах.
List<Map<String, dynamic>> regionBalancers(Iterable<String> tags) {
  final list = tags.toList();
  if (list.length < 2) return const [];
  return [
    {
      'tag': regionBalancerTag,
      'selector': list,
      'strategy': {
        'type': 'leastPing',
        'settings': {'tolerance': regionToleranceMs},
      },
    },
  ];
}

/// Наблюдатель для стратегии `leastPing` (МК-4).
///
/// Форма проверена живым отказом на стенде `test/stand` 21.10.2026 на ядре
/// 26.3.27. Без `subjectSelector` наблюдатель не делает ни одной пробы, стратегия
/// не получает задержек и навсегда остаётся на первом узле списка: переход на
/// живой узел не происходит ни в одном режиме отказа. `xray run -test` такой
/// блок принимает — Go молча пропускает незнакомые поля JSON, поэтому прежняя
/// форма `{'target': …}` прошла проверку синтаксиса и не работала.
///
/// Замер с этой формой: переход на живой узел за 5 с во всех трёх режимах отказа
/// (потеря пакетов, немедленный отказ, зависание), после восстановления узла
/// трафик возвращается на него, ухода напрямую при двух мёртвых узлах нет.
Map<String, dynamic> observatoryFor(String endpoint, Iterable<String> tags) => {
  'subjectSelector': tags.toList(),
  'probeURL': endpoint,
  'probeInterval': regionProbeInterval,
  'enableConcurrency': true,
};

/// Хранение точки проб на устройстве (У-3).
///
/// Значение локальное: клиент никуда его не отправляет. Пустая сохранённая
/// строка означает «пользователь не выбирал», тогда работает нейтральная
/// точка по умолчанию.
class ProbeStore {
  const ProbeStore(this._prefs);

  static const _key = 'probe.endpoint.v1';

  final SharedPreferences _prefs;

  String load() {
    final saved = _prefs.getString(_key)?.trim();
    return saved == null || saved.isEmpty || probeEndpointError(saved) != null
        ? defaultProbeEndpoint
        : saved;
  }

  Future<void> save(String endpoint) => _prefs.setString(_key, endpoint);
}
