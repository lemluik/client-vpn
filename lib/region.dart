import 'share_link.dart';

/// Регион выхода — группа профилей подписки с общим именем узла.
///
/// Список регионов клиент извлекает из содержимого подписки, а не получает
/// готовым полем: узлы называет провайдер, поэтому клиент остаётся
/// универсальным и не знает нашего набора регионов. Порядок строк подписки
/// сохраняется и внутри региона остаётся приоритетом профилей.
class Region {
  const Region({required this.key, required this.label, required this.links});

  /// Идентификатор для хранения: метка в нижнем регистре.
  final String key;

  /// Текст для интерфейса — имя в том виде, в каком его прислал провайдер.
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
    final label = regionLabelOf(link.remark);
    final key = label.toLowerCase();
    final known = positions[key];
    if (known == null) {
      positions[key] = regions.length;
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

/// Метка региона из имени узла: первое слово имени.
///
/// Провайдеры пишут имена как «EU-РФ1», «🇩🇪 Germany 01» или «Кыргызстан 2»,
/// поэтому значки, цифры и разделители в начале отбрасываются, а регион
/// определяется первым набором букв.
String regionLabelOf(String remark) =>
    RegExp(r'\p{L}+', unicode: true).firstMatch(remark)?.group(0) ?? '';
