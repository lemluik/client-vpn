import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

/// Отсоединённая подпись манифеста обновлений (Р-92).
///
/// Подпись — сырые 64 байта Ed25519 над точными байтами манифеста, файл
/// `manifest.json.sig` рядом с `manifest.json`. Публичный ключ закрепляется в
/// приватном слое сборки (32 байта, base64): без него закрытый канал не
/// проверяется, а не «проверяется как получится».
///
/// Любая ошибка разбора — отказ, а не пропуск проверки: молча принять
/// неподписанный манифест значит разрешить подмену раздачи.
bool verifyManifestSignature({
  required List<int> manifestBytes,
  required List<int> signature,
  required String publicKeyBase64,
}) {
  if (signature.length != ed.SignatureSize) return false;
  final List<int> keyBytes;
  try {
    keyBytes = base64.decode(publicKeyBase64.trim());
  } on FormatException {
    return false;
  }
  if (keyBytes.length != ed.PublicKeySize) return false;
  try {
    return ed.verify(
      ed.PublicKey(keyBytes),
      Uint8List.fromList(manifestBytes),
      Uint8List.fromList(signature),
    );
  } catch (_) {
    return false;
  }
}

/// Адрес файла подписи: тот же путь с суффиксом `.sig`.
String signatureUrlFor(String feed) {
  final uri = Uri.parse(feed.trim());
  return uri.replace(path: '${uri.path}.sig').toString();
}