import 'dart:io';

import 'package:flutter/services.dart';

/// Открывает ссылку в системном браузере, не заводя новых зависимостей:
/// на Windows — штатный `rundll32`, на Android — `ACTION_VIEW` через нативный
/// канал туннела. `false` означает «автоматически не получилось»: экран в этом
/// случае предлагает скопировать ссылку.
const MethodChannel tunnelChannel = MethodChannel('client_vpn/tunnel');

Future<bool> openExternalLink(String url) async {
  final trimmed = url.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.isAbsolute || uri.host.isEmpty) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;

  if (Platform.isWindows) {
    try {
      final result = await Process.run(
        'rundll32',
        ['url.dll,FileProtocolHandler', trimmed],
      );
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  if (Platform.isAndroid) {
    try {
      final opened = await tunnelChannel.invokeMethod<bool>(
        'openUrl',
        {'url': trimmed},
      );
      return opened ?? false;
    } on PlatformException {
      return false;
    }
  }

  return false;
}
