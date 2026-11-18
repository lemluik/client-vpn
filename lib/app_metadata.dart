import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Установленная версия, код сборки и подпись — из метаданных приложения.
///
/// Строка версии в коде отставала от сборки: дерево 0.4.5 называло себя 0.4.4,
/// поэтому проверка обновления сравнивала не то, что установлено. Метаданные
/// читает сама платформа: Android — PackageManager, Windows — ресурс версии
/// исполняемого файла, macOS — Info.plist. Значение недоступно — проверка
/// обновления сообщает об этом, а не подставляет выдуманную версию.
class AppMetadata {
  const AppMetadata({
    required this.versionName,
    required this.versionCode,
    this.applicationId,
    this.signerSha256,
  });

  /// Версия для пользователя: `0.4.6`, без кода сборки.
  final String versionName;

  /// Код сборки: Android versionCode, Windows четвёртый разряд FILEVERSION,
  /// macOS CFBundleVersion. Ноль — платформа код не сообщила.
  final int versionCode;

  /// Идентификатор приложения: Android packageName, macOS bundle id.
  /// На Windows идентификатора пакета нет — null.
  final String? applicationId;

  /// SHA-256 сертификата подписи APK (Android). На остальных платформах null:
  /// там установщик не сверяет подпись с уже установленной сборкой.
  final String? signerSha256;

  bool get isKnown => versionName.isNotEmpty;

  static const MethodChannel _channel = MethodChannel('client_vpn/app');

  static AppMetadata? _cached;

  /// Последнее прочитанное значение. Синхронные потребители (диагностика,
  /// запросы выдачи) берут его, чтобы не ждать чтения посреди кадра.
  static AppMetadata? get cached => _cached;

  /// Запомнить прочитанное значение. Вызывается при старте приложения; тесты
  /// задают им известную сборку вместо метаданных тестового раннера.
  static void remember(AppMetadata value) => _cached = value;

  /// Чтение метаданных текущей платформы. Ошибки не бросаются наружу:
  /// недоступные метаданные — это [isKnown] == false, а не падение экрана.
  static Future<AppMetadata> load() async {
    final value = await _read();
    _cached = value;
    return value;
  }

  static Future<AppMetadata> _read() async {
    try {
      if (Platform.isAndroid) return await _android();
      if (Platform.isWindows) return _windows(Platform.resolvedExecutable);
      if (Platform.isMacOS) return await _macos(Platform.resolvedExecutable);
    } catch (_) {
      // Метаданные не прочитались: версия неизвестна, приложение работает.
    }
    return const AppMetadata(versionName: '', versionCode: 0);
  }

  static Future<AppMetadata> _android() async {
    final answer = await _channel.invokeMethod<Map<Object?, Object?>>('metadata');
    if (answer == null) return const AppMetadata(versionName: '', versionCode: 0);
    final name = answer['versionName'];
    final code = answer['versionCode'];
    final id = answer['packageName'];
    final signer = answer['signerSha256'];
    return AppMetadata(
      versionName: name is String ? normalizeMetadataVersion(name) : '',
      versionCode: code is int ? code : (code is num ? code.toInt() : 0),
      applicationId: id is String && id.isNotEmpty ? id : null,
      signerSha256: signer is String && signer.isNotEmpty
          ? signer.toLowerCase()
          : null,
    );
  }

  /// Windows: ресурс версии исполняемого файла. Сборка Flutter подставляет в
  /// него `version:` из pubspec.yaml (FLUTTER_VERSION_* в Runner.rc), поэтому
  /// четвёртый разряд FILEVERSION — код сборки, первые три — версия.
  static AppMetadata _windows(String executable) {
    final info = windowsFixedFileInfo(executable);
    if (info == null) return const AppMetadata(versionName: '', versionCode: 0);
    final major = (info.ms >> 16) & 0xFFFF;
    final minor = info.ms & 0xFFFF;
    final patch = (info.ls >> 16) & 0xFFFF;
    final build = info.ls & 0xFFFF;
    return AppMetadata(
      versionName: '$major.$minor.$patch',
      versionCode: build,
    );
  }

  static Future<AppMetadata> _macos(String executable) async {
    // …/ClientVPN.app/Contents/MacOS/ClientVPN → …/Contents/Info
    final contents = p.dirname(p.dirname(executable));
    final plist = p.join(contents, 'Info');
    final name = await _defaults(plist, 'CFBundleShortVersionString');
    final build = await _defaults(plist, 'CFBundleVersion');
    final id = await _defaults(plist, 'CFBundleIdentifier');
    return AppMetadata(
      versionName: name == null ? '' : normalizeMetadataVersion(name),
      versionCode: int.tryParse(build ?? '') ?? 0,
      applicationId: id,
    );
  }

  static Future<String?> _defaults(String plist, String key) async {
    final result = await Process.run('defaults', ['read', plist, key]);
    if (result.exitCode != 0) return null;
    final text = (result.stdout as String).trim();
    return text.isEmpty ? null : text;
  }
}

/// `0.4.6+4` и `v0.4.6` приводятся к `0.4.6`: код сборки живёт отдельным полем.
String normalizeMetadataVersion(String raw) {
  final match = RegExp(r'\d+(?:\.\d+){1,3}').firstMatch(raw.trim());
  return match == null ? '' : match.group(0)!;
}

typedef _SizeNative = Uint32 Function(Pointer<Utf16>, Pointer<Uint32>);
typedef _SizeDart = int Function(Pointer<Utf16>, Pointer<Uint32>);
typedef _InfoNative = Int32 Function(
    Pointer<Utf16>, Uint32, Uint32, Pointer<Void>);
typedef _InfoDart = int Function(Pointer<Utf16>, int, int, Pointer<Void>);
typedef _QueryNative = Int32 Function(
    Pointer<Void>, Pointer<Utf16>, Pointer<Pointer<Void>>, Pointer<Uint32>);
typedef _QueryDart = int Function(
    Pointer<Void>, Pointer<Utf16>, Pointer<Pointer<Void>>, Pointer<Uint32>);

/// Разряды FILEVERSION из ресурса версии файла: `ms` — старшие два разряда,
/// `ls` — младшие два. null — ресурса нет или он не похож на VS_FIXEDFILEINFO.
///
/// Отдельная функция, а не часть чтения метаданных: её проверяют на настоящем
/// Windows по системному файлу с известным ресурсом версии.
({int ms, int ls})? windowsFixedFileInfo(String path) {
  if (!Platform.isWindows) return null;
  final lib = DynamicLibrary.open('version.dll');
  final sizeOf = lib.lookupFunction<_SizeNative, _SizeDart>(
      'GetFileVersionInfoSizeW');
  final getInfo = lib.lookupFunction<_InfoNative, _InfoDart>(
      'GetFileVersionInfoW');
  final query = lib.lookupFunction<_QueryNative, _QueryDart>(
      'VerQueryValueW');

  final name = path.toNativeUtf16();
  final handle = calloc<Uint32>();
  final block = calloc<Pointer<Void>>();
  final blockLen = calloc<Uint32>();
  Pointer<Uint8>? buffer;
  try {
    final size = sizeOf(name, handle);
    if (size == 0) return null;
    buffer = calloc<Uint8>(size);
    if (getInfo(name, handle.value, size, buffer.cast()) == 0) return null;
    final root = '\\'.toNativeUtf16();
    final ok = query(buffer.cast(), root, block, blockLen);
    calloc.free(root);
    if (ok == 0 || blockLen.value < 16) return null;
    final words = block.value.cast<Uint32>();
    // dwSignature VS_FIXEDFILEINFO.
    if (words[0] != 0xFEEF04BD) return null;
    return (ms: words[2], ls: words[3]);
  } finally {
    if (buffer != null) calloc.free(buffer);
    calloc.free(blockLen);
    calloc.free(block);
    calloc.free(handle);
    calloc.free(name);
  }
}