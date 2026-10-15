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

/// Балансировщик узлов региона — второй уровень автопереключения (МК-6).
///
/// Один узел — балансировщика нет: выбирать не из чего, и завершающее правило
/// остаётся на `outboundTag`. Порог прилипания (`strategy.settings.tolerance`)
/// не задаём: число нужно измерить на стенде с двумя живыми узлами, а не
/// выдумывать. `fallbackTag` тоже не ставим: запасной путь на `freedom`
/// означал бы утечку трафика напрямую при мёртвых узлах.
List<Map<String, dynamic>> regionBalancers(Iterable<String> tags) {
  final list = tags.toList();
  if (list.length < 2) return const [];
  return [
    {
      'tag': regionBalancerTag,
      'selector': list,
      'strategy': {'type': 'leastPing'},
    },
  ];
}

/// Наблюдатель для стратегии `leastPing` (МК-4).
///
/// Форма блока замерена на ядре 26.3.27 16.10.2026: `xray run -test` принимает
/// `observatory` с одним полем `target`, а без него явная стратегия не проходит
/// (`core: not all dependencies are resolved`). Частоты и таймауты не ставим —
/// берём значения по умолчанию ядра.
Map<String, dynamic> observatoryFor(String endpoint) => {'target': endpoint};

/// Наблюдатель для стратегии `leastLoad` (МК-4).
///
/// Замер 16.10.2026: пустой `burstObservatory` ядро отвергает
/// (`BurstObservatory requires a valid ...`), минимальный принятый блок —
/// `pingConfig.targets`.
Map<String, dynamic> burstObservatoryFor(String endpoint) => {
  'pingConfig': {
    'targets': [endpoint],
  },
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
