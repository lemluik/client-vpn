import 'dart:convert';

/// Протоколы ссылок, которые клиент умеет превращать в конфиг ядра.
enum LinkProtocol { vless, trojan, vmess }

/// Ошибка разбора ссылки. Текст предназначен для показа пользователю,
/// поэтому в нём не бывает ни идентификатора, ни пароля из ссылки.
class LinkFormatException extends FormatException {
  LinkFormatException(super.message);
}

/// Схема известна рынку, но нашему разбору не поддерживается.
/// При массовом импорте такая ссылка пропускается, а не рвёт весь список.
class UnsupportedLinkException extends LinkFormatException {
  UnsupportedLinkException(super.message, {this.scheme = 'неизвестно'});

  final String scheme;
}

/// Транспорт, для которого мы умеем собрать настройки в конфиге ядра.
const Set<String> supportedNetworks = {'tcp', 'ws', 'grpc', 'http'};

/// Допустимые значения `flow`. Устаревшие `xtls-rprx-direct` и `xtls-rprx-origin`
/// ядро 26.3.27 не принимает, поэтому отсекаем их на разборе, а не в момент сбоя.
const Set<String> supportedFlows = {
  '',
  'xtls-rprx-vision',
  'xtls-rprx-vision-udp443',
};

/// Ссылка-профиль от любого провайдера: `vless://`, `trojan://`, `vmess://`.
///
/// Значения нормализованы, но [source] хранит исходный текст: экспорт подписки
/// обязан возвращать ссылку в том же виде, в каком её выдал провайдер.
class ShareLink {
  const ShareLink({
    required this.protocol,
    required this.name,
    required this.address,
    required this.port,
    required this.id,
    required this.security,
    required this.network,
    required this.source,
    this.remark = '',
    this.alterId = 0,
    this.encryption = '',
    this.flow = '',
    this.sni,
    this.fingerprint,
    this.publicKey,
    this.shortId,
    this.host,
    this.path,
    this.serviceName,
    this.alpn = const [],
    this.allowInsecure = false,
    this.packetEncoding,
  });

  final LinkProtocol protocol;

  /// Имя профиля — из якоря ссылки или из поля `ps` у `vmess://`.
  final String name;

  /// Имя, которое прислал провайдер. Пусто, если имени не было и [name]
  /// заменён адресом: такие профили нельзя группировать по региону.
  final String remark;

  final String address;
  final int port;

  /// Идентификатор пользователя: UUID у vless и vmess, пароль у trojan.
  final String id;

  /// `none`, `tls` или `reality`.
  final String security;

  /// `tcp`, `ws`, `grpc` или `http`.
  final String network;

  /// `alterId` у vmess; у остальных протоколов всегда 0.
  final int alterId;

  /// Шифрование полезной нагрузки: `none` у vless, значение `scy` у vmess.
  final String encryption;

  final String flow;
  final String? sni;
  final String? fingerprint;

  /// Открытый ключ Reality (`pbk`).
  final String? publicKey;

  /// Короткий идентификатор Reality (`sid`).
  final String? shortId;

  /// Заголовок `Host` для ws и http.
  final String? host;
  final String? path;

  /// Имя службы gRPC.
  final String? serviceName;

  final List<String> alpn;
  final bool allowInsecure;
  final String? packetEncoding;

  /// Исходный текст ссылки — для экспорта без потерь.
  final String source;

  /// Исходящее соединение Xray для этой ссылки.
  ///
  /// Тег нужен для маршрутизации: завершающее правило конфига ссылается
  /// на тег первого исходящего, а не на его порядок в списке.
  Map<String, dynamic> toOutbound({String? tag}) {
    final outbound = switch (protocol) {
      LinkProtocol.vless => {
          'protocol': 'vless',
          'settings': {
            'vnext': [
              _vnext({
                'id': id,
                'encryption': encryption.isEmpty ? 'none' : encryption,
                if (flow.isNotEmpty) 'flow': flow,
                if (packetEncoding != null) 'packetEncoding': packetEncoding,
              }),
            ],
          },
        },
      LinkProtocol.vmess => {
          'protocol': 'vmess',
          'settings': {
            'vnext': [
              _vnext({
                'id': id,
                'alterId': alterId,
                'security': encryption.isEmpty ? 'auto' : encryption,
              }),
            ],
          },
        },
      LinkProtocol.trojan => {
          'protocol': 'trojan',
          'settings': {
            'servers': [
              _serverEntry({
                'password': id,
                'level': 0,
                if (flow.isNotEmpty) 'flow': flow,
              }),
            ],
          },
        },
    };

    return {
      ...outbound,
      'streamSettings': _streamSettings(),
      if (tag != null) 'tag': tag,
    };
  }

  /// Сервер vless и vmess: данные пользователя вложены в `users`.
  Map<String, dynamic> _vnext(Map<String, dynamic> user) => {
        'address': address,
        'port': port,
        'users': [user],
      };

  /// Сервер trojan: данные пользователя лежат прямо в описании сервера.
  Map<String, dynamic> _serverEntry(Map<String, dynamic> user) => {
        'address': address,
        'port': port,
        ...user,
      };

  Map<String, dynamic> _streamSettings() => {
        'network': network,
        'security': security,
        if (security == 'reality')
          'realitySettings': {
            if (sni != null) 'serverName': sni,
            'fingerprint': fingerprint ?? 'chrome',
            if (publicKey != null) 'publicKey': publicKey,
            'shortId': shortId ?? '',
          }
        else if (security == 'tls')
          'tlsSettings': {
            if (sni != null) 'serverName': sni,
            if (alpn.isNotEmpty) 'alpn': alpn,
            if (fingerprint != null) 'fingerprint': fingerprint,
            'allowInsecure': allowInsecure,
          },
        if (network == 'ws')
          'wsSettings': {
            if (path != null) 'path': path,
            if (host != null) 'headers': {'Host': host},
          }
        else if (network == 'grpc')
          'grpcSettings': {
            if (serviceName != null) 'serviceName': serviceName,
          }
        else if (network == 'http')
          'httpSettings': {
            if (path != null) 'path': path,
            if (host != null) 'host': [host],
          },
      };
}

/// Ссылка, которую массовый импорт пропустил.
///
/// Значения ключа здесь нет намеренно: список пропусков уходит в журнал
/// и в публичные обращения, а ссылки содержат секреты.
class SkippedLink {
  const SkippedLink({
    required this.line,
    required this.scheme,
    required this.reason,
  });

  /// Номер строки в исходном тексте — по нему пользователь найдёт профиль.
  final int line;
  final String scheme;
  final String reason;
}

/// Итог массового разбора: что приняли и что пропустили.
class LinkParseResult {
  const LinkParseResult({required this.links, required this.skipped});

  final List<ShareLink> links;
  final List<SkippedLink> skipped;

  bool get isEmpty => links.isEmpty;
}

/// Разбирает одну ссылку провайдера.
///
/// Бросает [UnsupportedLinkException] для чужой схемы и [LinkFormatException]
/// для нашей схемы с повреждёнными значениями; в обоих случаях текст пригоден
/// для показа пользователю.
ShareLink parseShareLink(String raw) {
  final text = raw.trim();
  if (text.isEmpty) throw LinkFormatException('Пустая ссылка');

  final scheme = schemeOf(text);
  if (scheme == 'vmess') return _parseVmess(text);

  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException {
    throw LinkFormatException('Ссылка $scheme не читается');
  }

  return switch (scheme) {
    'vless' => _parseInline(uri, LinkProtocol.vless, text),
    'trojan' => _parseInline(uri, LinkProtocol.trojan, text),
    _ => throw UnsupportedLinkException(
        'Протокол $scheme не поддерживается',
        scheme: scheme,
      ),
  };
}

/// Схема ссылки в нижнем регистре. Для текста без схемы — `неизвестно`.
String schemeOf(String text) {
  final match = RegExp(r'^([A-Za-z][A-Za-z0-9+.\-]*)://').firstMatch(text);
  return match == null ? 'неизвестно' : match.group(1)!.toLowerCase();
}

/// `vless://` и `trojan://`: идентификатор в authority, параметры в запросе.
ShareLink _parseInline(Uri uri, LinkProtocol protocol, String source) {
  final id = _decodeComponent(uri.userInfo);
  if (id.isEmpty) {
    throw LinkFormatException('В ссылке нет идентификатора пользователя');
  }

  final params = uri.queryParameters;
  final address = _addressOf(uri);
  final security = _securityOf(params, protocol);
  final flow = params['flow'] ?? '';
  if (!supportedFlows.contains(flow)) {
    throw LinkFormatException('Неподдерживаемое значение flow');
  }

  final publicKey = _firstOf(params, ['pbk', 'publicKey']);
  if (security == 'reality' && (publicKey == null || publicKey.isEmpty)) {
    throw LinkFormatException('Для Reality не задан открытый ключ (pbk)');
  }

  final host = _firstOf(params, ['host']);
  final name = _decodeComponent(uri.fragment);

  return ShareLink(
    protocol: protocol,
    name: name.isNotEmpty ? name : address,
    remark: name,
    address: address,
    port: _portOf(uri),
    id: id,
    security: security,
    network: _networkOf(params),
    encryption: params['encryption'] ?? '',
    flow: flow,
    sni: _sniOf(params, security, host, address),
    fingerprint: _firstOf(params, ['fp', 'fingerprint']),
    publicKey: publicKey,
    shortId: _firstOf(params, ['sid', 'shortId']),
    host: host,
    path: _firstOf(params, ['path']),
    serviceName: _firstOf(params, ['serviceName']),
    alpn: _splitAlpn(_firstOf(params, ['alpn']) ?? ''),
    allowInsecure: _insecureOf(params),
    packetEncoding: _packetEncodingOf(params),
    source: source,
  );
}

/// `vmess://`: после схемы идёт base64 с JSON-описанием профиля.
ShareLink _parseVmess(String source) {
  final encoded = source.substring('vmess://'.length).trim();

  final dynamic data;
  try {
    data = jsonDecode(utf8.decode(decodeBase64Loose(encoded)));
  } on FormatException {
    throw LinkFormatException('Описание vmess не читается');
  }
  if (data is! Map) throw LinkFormatException('Описание vmess не читается');

  String field(String key) => switch (data[key]) {
        final String value => value.trim(),
        final num value => value.toString(),
        _ => '',
      };

  final address = _stripBrackets(field('add'));
  if (address.isEmpty) throw LinkFormatException('В ссылке vmess нет адреса');
  final id = field('id');
  if (id.isEmpty) {
    throw LinkFormatException('В ссылке vmess нет идентификатора пользователя');
  }

  final security = switch (field('tls')) {
    'tls' => 'tls',
    'reality' => 'reality',
    _ => 'none',
  };
  final network = _normalizeNetwork(field('net'));
  final flow = field('flow');
  if (!supportedFlows.contains(flow)) {
    throw LinkFormatException('Неподдерживаемое значение flow');
  }

  final publicKey = field('pbk');
  if (security == 'reality' && publicKey.isEmpty) {
    throw LinkFormatException('Для Reality не задан открытый ключ (pbk)');
  }

  final port = int.tryParse(field('port')) ?? 443;
  if (port < 1 || port > 65535) {
    throw LinkFormatException('Порт вне диапазона 1…65535');
  }

  final host = field('host');
  final path = field('path');
  final sni = switch (_nonEmpty(field('sni'))) {
    final String value => value,
    null => security == 'none' ? null : (_nonEmpty(host) ?? address),
  };

  // В ссылках vmess имя службы gRPC провайдеры часто пишут в `path`.
  final declaredService = _nonEmpty(field('serviceName'));
  final serviceName =
      declaredService ?? (network == 'grpc' ? _nonEmpty(path) : null);

  return ShareLink(
    protocol: LinkProtocol.vmess,
    name: _nonEmpty(field('ps')) ?? address,
    remark: _nonEmpty(field('ps')) ?? '',
    address: address,
    port: port,
    id: id,
    security: security,
    network: network,
    alterId: int.tryParse(field('aid')) ?? 0,
    encryption: field('scy'),
    flow: flow,
    sni: sni,
    fingerprint: _nonEmpty(field('fp')),
    publicKey: _nonEmpty(publicKey),
    shortId: _nonEmpty(field('sid')),
    host: _nonEmpty(host),
    path: _nonEmpty(path),
    serviceName: serviceName,
    alpn: _splitAlpn(field('alpn')),
    packetEncoding: _nonEmpty(field('packetEncoding')),
    source: source,
  );
}

String _stripBrackets(String host) {
  if (host.startsWith('[') && host.endsWith(']')) {
    return host.substring(1, host.length - 1);
  }
  return host;
}

String _addressOf(Uri uri) {
  final address = _stripBrackets(uri.host);
  if (address.isEmpty) throw LinkFormatException('В ссылке нет адреса сервера');
  return address;
}

/// Порт по умолчанию 443: провайдеры иногда его опускают, а `Uri.port`
/// для неизвестной схемы возвращает 0.
int _portOf(Uri uri) {
  final port = uri.hasPort ? uri.port : 443;
  if (port < 1 || port > 65535) {
    throw LinkFormatException('Порт вне диапазона 1…65535');
  }
  return port;
}

/// `Uri.userInfo` и `Uri.fragment` возвращаются в percent-кодировке, а имена
/// профилей и пароли приходят нерусскими символами и спецзнаками. Декодируем
/// сами; при повреждённых процентах оставляем исходное значение.
String _decodeComponent(String raw) {
  if (!raw.contains('%')) return raw;
  try {
    return Uri.decodeComponent(raw);
  } on FormatException {
    return raw;
  }
}

String? _firstOf(Map<String, String> params, List<String> keys) {
  for (final key in keys) {
    final value = _nonEmpty(params[key]);
    if (value != null) return value;
  }
  return null;
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _networkOf(Map<String, String> params) =>
    _normalizeNetwork(_firstOf(params, ['type', 'network']) ?? 'tcp');

String _normalizeNetwork(String raw) {
  final network = switch (raw.trim().toLowerCase()) {
    // Провайдеры пишут «нет транспорта» по-разному: none, raw или пустой type.
    '' || 'tcp' || 'none' || 'raw' => 'tcp',
    'h2' => 'http',
    final String value => value,
  };
  if (!supportedNetworks.contains(network)) {
    throw LinkFormatException('Транспорт $network не поддерживается');
  }
  return network;
}

String _securityOf(Map<String, String> params, LinkProtocol protocol) {
  final fallback = protocol == LinkProtocol.trojan ? 'tls' : 'none';
  final security = (_firstOf(params, ['security']) ?? fallback).toLowerCase();
  if (security == 'xtls') {
    throw LinkFormatException(
      'Транспорт XTLS устарел: нужен профиль Reality или TLS',
    );
  }
  if (security != 'none' && security != 'tls' && security != 'reality') {
    throw LinkFormatException('Неподдерживаемый тип защиты');
  }
  return security;
}

/// Имя сервера для TLS и Reality. Провайдеры часто его опускают — тогда берём
/// `host` транспорта или сам адрес: без `serverName` ядро не сверит сертификат.
String? _sniOf(
  Map<String, String> params,
  String security,
  String? host,
  String address,
) {
  final sni = _firstOf(params, ['sni', 'tlsServerName']);
  if (sni != null) return sni;
  if (security == 'none') return null;
  return host ?? address;
}

List<String> _splitAlpn(String raw) => raw
    .split(',')
    .map((value) => value.trim())
    .where((value) => value.isNotEmpty)
    .toList();

bool _insecureOf(Map<String, String> params) {
  final value = _firstOf(params, ['allowInsecure', 'insecure']);
  return value == '1' || value == 'true';
}

String? _packetEncodingOf(Map<String, String> params) =>
    switch (_firstOf(params, ['packetEncoding'])) {
      'xudp' || 'packet' => _firstOf(params, ['packetEncoding']),
      'true' || '1' => 'xudp',
      _ => null,
    };

/// Декодирует base64, прощая пропущенные знаки равенства и алфавит base64url.
/// Бросает [FormatException], если текст не является base64.
List<int> decodeBase64Loose(String value) {
  var text = value.replaceAll(RegExp(r'\s'), '');
  text = text.replaceAll('-', '+').replaceAll('_', '/');
  text += '=' * ((4 - text.length % 4) % 4);
  return base64.decode(text);
}

/// Разбирает всё, что пришло списком: подписка, буфер обмена, текст из бота.
///
/// Ссылки разделяются любым пробельным символом. Повреждённая строка
/// не отменяет остальные — она попадает в [LinkParseResult.skipped]
/// с номером строки и причиной.
LinkParseResult parseLinks(String text) {
  final links = <ShareLink>[];
  final skipped = <SkippedLink>[];

  for (final (index, line) in text.split('\n').indexed) {
    for (final chunk in line.trim().split(RegExp(r'\s+'))) {
      if (chunk.isEmpty) continue;
      try {
        links.add(parseShareLink(chunk));
      } on UnsupportedLinkException catch (e) {
        skipped.add(
          SkippedLink(line: index + 1, scheme: e.scheme, reason: e.message),
        );
      } on FormatException catch (e) {
        skipped.add(
          SkippedLink(
            line: index + 1,
            scheme: schemeOf(chunk),
            reason: e.message,
          ),
        );
      }
    }
  }

  return LinkParseResult(links: links, skipped: skipped);
}
