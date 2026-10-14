/// Маскирование журнала перед отправкой наружу.
///
/// Клиент открытый: журнал прикладывается к публичным обращениям, поэтому из
/// него убираются адреса узлов, идентификаторы и ключи пользователя. Служебные
/// отметки и обратный адрес сохраняются — без них журнал бесполезен.
library;

final _linkPattern = RegExp(r'[A-Za-z][A-Za-z0-9+.\-]*://\S+');
final _uuidPattern = RegExp(
  r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
);
final _longSecretPattern =
    RegExp(r'(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/=_-]{32,}');
final _ipv4Pattern = RegExp(r'(?<![\d.])(\d{1,3}\.){3}\d{1,3}(?![\d.])');
final _ipv6Pattern = RegExp(
  r'(?<![0-9A-Fa-f:])([0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f:.]{2,}(?![0-9A-Fa-f:])',
);

/// Обратный адрес и «адрес не задан» не являются тайной и нужны для диагностики.
const Set<String> visibleAddresses = {'127.0.0.1', '0.0.0.0', '::1'};

const String maskedAddress = '[адрес]';
const String maskedKey = '[ключ]';
const String maskedId = '[идентификатор]';
const String maskedLink = '[ссылка]';

/// Убирает из одной строки журнала всё, что относится к пользователю и узлам.
String maskSecrets(String line) {
  var result = line.replaceAll(_linkPattern, maskedLink);
  result = result.replaceAll(_uuidPattern, maskedId);
  result = result.replaceAllMapped(_ipv6Pattern, (match) {
    final value = match.group(0)!;
    if (visibleAddresses.contains(value)) return value;
    return _looksLikeAddress(value) ? maskedAddress : value;
  });
  result = result.replaceAllMapped(_ipv4Pattern, (match) {
    final value = match.group(0)!;
    return visibleAddresses.contains(value) ? value : maskedAddress;
  });
  return result.replaceAll(_longSecretPattern, maskedKey);
}

/// Журнал целиком — в таком виде он уходит в файл обращения.
String maskLog(Iterable<String> lines) => lines.map(maskSecrets).join('\n');

/// Отличает адрес от отметки времени: в журнале ядра встречается `12:30:45`,
/// и такая строка не должна превращаться в «адрес скрыт».
bool _looksLikeAddress(String value) {
  if (value.contains('::')) return true;
  if (value.split(':').length - 1 >= 3) return true;
  return RegExp(r'[a-fA-F]').hasMatch(value);
}
