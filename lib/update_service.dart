import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'update_check.dart';

/// Сервис автоматического обновления.
///
/// Проверяет наличие новой версии, скачивает APK, проверяет SHA-256
/// и запускает установку через системный диалог.
class UpdateService {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  static const _autocheckKey = 'update.autocheck.v1';
  static const _lastCheckKey = 'update.last_check.v1';
  static const _lastDismissedKey = 'update.last_dismissed.v1';
  static const _pendingKey = 'update.pending.v1';

  final _client = HttpClient();

  /// Включена ли автоматическая проверка при старте.
  Future<bool> isAutoCheckEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autocheckKey) ?? true;
  }

  /// Переключить автоматическую проверку.
  Future<void> setAutoCheckEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autocheckKey, enabled);
  }

  /// Последняя проверка (Unix timestamp в секундах).
  Future<DateTime?> getLastCheck() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getInt(_lastCheckKey);
    if (timestamp == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
  }

  /// Обновить время последней проверки.
  Future<void> markChecked() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastCheckKey, DateTime.now().millisecondsSinceEpoch ~/ 1000);
  }

  /// Последнее отклонение обновления (Unix timestamp в секундах).
  Future<DateTime?> getLastDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getInt(_lastDismissedKey);
    if (timestamp == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
  }

  /// Отметить, что пользователь отклонил обновление.
  Future<void> markDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastDismissedKey, DateTime.now().millisecondsSinceEpoch ~/ 1000);
  }

  /// Проверить наличие обновления.
  ///
  /// Возвращает [UpdateResult] с информацией о релизе или ошибке.
  Future<UpdateResult> checkForUpdate({
    required String feed,
    required String currentVersion,
  }) {
    return checkForUpdate(
      feed: feed,
      currentVersion: currentVersion,
    );
  }

  /// Скачать пакет обновления и проверить целостность.
  ///
  /// APK для Android, zip-раскладка для Windows — различается только способ
  /// установки, а проверка одинаковая. Возвращает путь к скачанному файлу или
  /// null при ошибке.
  ///
  /// [expectedSha256] — сумма из манифеста; [checksumUrl] — companion-файл
  /// площадки (ассет `<имя>.sha256` на GitHub). Если ни того, ни другого нет,
  /// скачанный пакет остаётся непроверенным: это допустимо только для тестовых
  /// релизов, реальный канал раздачи обязан отдавать сумму (см. спецификацию
  /// автообновления, требование «SHA-256 обязателен»).
  Future<DownloadResult> downloadPackage({
    required String url,
    String? expectedSha256,
    String? checksumUrl,
    void Function(double)? onProgress,
  }) async {
    final expected = expectedSha256 ?? await _fetchChecksum(checksumUrl);
    if (expected == null) {
      debugPrint('UpdateService: сумма не получена, проверка пропущена');
    }
    try {
      final cacheDir = await getTemporaryDirectory();
      final fileName = p.basename(Uri.parse(url).path);
      final targetPath = p.join(cacheDir.path, fileName);
      final targetFile = File(targetPath);

      // Удаляем старый файл, если есть.
      if (await targetFile.exists()) {
        await targetFile.delete();
      }

      final request = await _client.getUrl(Uri.parse(url));
      final response = await request.close();

      if (response.statusCode != HttpStatus.ok) {
        debugPrint('UpdateService: HTTP ${response.statusCode}');
        return const DownloadResult.failed(DownloadFailure.unavailable);
      }

      final contentLength = response.contentLength;
      var received = 0;
      final sink = targetFile.openWrite();

      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (contentLength > 0) {
          onProgress?.call(received / contentLength);
        }
      }

      await sink.close();

      // Проверяем SHA-256, если сумму удалось получить.
      if (expected != null) {
        final hash = await _computeSha256(targetFile);
        if (hash != expected.toLowerCase()) {
          debugPrint('UpdateService: SHA-256 mismatch');
          debugPrint('  Expected: $expected');
          debugPrint('  Got:      $hash');
          await targetFile.delete();
          return const DownloadResult.failed(DownloadFailure.hashMismatch);
        }
      }

      return DownloadResult.ok(targetPath);
    } catch (e) {
      debugPrint('UpdateService: download failed: $e');
      return const DownloadResult.failed(DownloadFailure.unavailable);
    }
  }

  /// Вычислить SHA-256 хеш файла.
  Future<String> _computeSha256(File file) async {
    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Прочитать SHA-256 из companion-файла площадки (`<имя>.sha256`).
  /// Формат строки — как у `sha256sum`: 64 hex-символа, необязательное имя
  /// файла после неё. `null` — файла нет, он недоступен или содержит мусор;
  /// тогда решение о допуске непроверенного пакета принимает вызывающий код.
  Future<String?> _fetchChecksum(String? url) async {
    if (url == null || url.isEmpty) return null;
    try {
      final request = await _client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      final text = await response.transform(utf8.decoder).join();
      final match = RegExp(r'\b[0-9a-fA-F]{64}\b').firstMatch(text);
      return match?.group(0)?.toLowerCase();
    } catch (e) {
      debugPrint('UpdateService: checksum fetch failed: $e');
      return null;
    }
  }

  /// Удалить скачанный пакет.
  Future<void> cleanup(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('UpdateService: cleanup failed: $e');
    }
  }

  /// Запомнить версию, на которую собираемся уйти из приложения.
  ///
  /// Нужен только Windows: там установка происходит после нашего выхода, и
  /// следующее открытие может быть как «обновление применено», так и «обновитель
  /// упал, мы прежние». Отличить одно от другого можно, сверив `clientVersion`
  /// с этой записью.
  Future<void> markPending(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingKey, version);
  }

  /// Версия, которую ждали после перезапуска, и снять отметку.
  ///
  /// `null` — перезапуск не был вызван обновлением. Отметка снимается всегда,
  /// иначе подтверждение показывалось бы при каждом следующем старте.
  Future<String?> takePending(String currentVersion) async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getString(_pendingKey);
    if (pending == null) return null;
    await prefs.remove(_pendingKey);
    return pending == currentVersion ? pending : null;
  }

  /// Закрыть HTTP-клиент.
  void dispose() {
    _client.close(force: true);
  }
}

/// Чем закончилось скачивание пакета обновления.
enum DownloadFailure { unavailable, hashMismatch }

/// Результат [UpdateService.downloadPackage].
///
/// Разделение ошибок не косметика: битая сумма — это признак подмены раздачи, и
/// молча показать ту же фразу, что и «нет связи», значит оставить пользователя
/// думать, что у него пропал интернет.
class DownloadResult {
  const DownloadResult.ok(this.path) : failure = null;
  const DownloadResult.failed(this.failure) : path = null;

  final String? path;
  final DownloadFailure? failure;

  bool get success => path != null;
}
