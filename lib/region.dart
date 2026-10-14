import 'share_link.dart';

/// Регион выхода — группа профилей подписки с общим именем узла.
///
/// Список регионов клиент извлекает из содержимого подписки, а не получает
/// готовым полем: узлы называет провайдер, поэтому клиент остаётся
/// универсальным и не знает нашего набора регионов. Порядок строк подписки
/// сохраняется и внутри региона остаётся приоритетом профилей.
class Region {
  const Region({required this.key, required this.label, required this.links});

    /// Идентификатор для хранения: название региона в нижнем регистре,
  /// без значка флага и порядкового номера узла.
  final String key;

  /// Текст для интерфейса: значок флага и полное название, как их прислал
  /// провайдер.
  final String label;

  /// Профили региона в порядке приоритета.
  final List<ShareLink> links;
}

/// Метка и подпись группы для профилей, которым провайдер не дал имени.
const String unnamedRegionKey = '';
const String unnamedRegionLabel = 'Без имени';

/// Регион с меткой [key]. Null, если ключ пуст или такого региона в списке нет.
Region? regionByKey(List<Region> regions, String? key) {
  if (key == null || key.isEmpty) return null;
  for (final region in regions) {
    if (region.key == key) return region;
  }
  return null;
}

/// Группирует профили по регионам. Порядок регионов — по первому появлению
/// в подписке, так что регион по умолчанию всегда первый.
List<Region> regionsOf(Iterable<ShareLink> links) {
  final positions = <String, int>{};
  final regions = <Region>[];

  for (final link in links) {
    final key = regionNameOf(link.remark).toLowerCase();
    final known = positions[key];
    if (known == null) {
      positions[key] = regions.length;
      final label = regionLabelOf(link.remark);
      regions.add(
        Region(
          key: key,
          label: label.isEmpty ? unnamedRegionLabel : label,
          links: [link],
        ),
      );
    } else {
      regions[known].links.add(link);
    }
  }

  return regions;
}

/// Название региона из имени узла: первое слово, без значка флага.
///
/// Провайдеры пишут имена как «DE-Relay 1», «🇩🇪 Germany 01» или «🇪🇺 Европа 2»,
/// поэтому порядковые номера и разделители в название не попадают, а регион
/// определяется первым набором букв — кириллица и латиница одинаково.
String regionNameOf(String remark) =>
    RegExp(r'\p{L}+', unicode: true).firstMatch(remark)?.group(0) ?? '';

/// Значок флага из имени узла: идущие подряд пары букв региональных
/// индикаторов. Пустая строка, если флага в имени нет.
String regionFlagOf(String remark) =>
    RegExp(r'(?:[\u{1F1E6}-\u{1F1FF}]{2})+', unicode: true)
            .firstMatch(remark)
            ?.group(0) ??
        '';

/// Полная метка региона для интерфейса: флаг и название.
///
/// Название без флага — то же самое, что [regionNameOf]; пустое имя региона
/// не даёт метки совсем.
String regionLabelOf(String remark) {
  final name = regionNameOf(remark);
  if (name.isEmpty) return '';
  final flag = regionFlagOf(remark);
  return flag.isEmpty ? name : '$flag $name';
}
