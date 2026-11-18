import 'dart:io';

import 'package:client_vpn/app_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('версия сборки приводится к виду для пользователя', () {
    expect(normalizeMetadataVersion('0.4.6+4'), '0.4.6');
    expect(normalizeMetadataVersion('v0.4.6'), '0.4.6');
    expect(normalizeMetadataVersion(' 0.4.6 '), '0.4.6');
    expect(normalizeMetadataVersion('0.4.6.1'), '0.4.6.1');
    expect(normalizeMetadataVersion('без цифр'), '');
    expect(normalizeMetadataVersion(''), '');
  });

  test('запомненное значение доступно синхронным потребителям', () {
    const value = AppMetadata(
      versionName: '0.4.6',
      versionCode: 4,
      applicationId: 'com.clientvpn.client_vpn',
      signerSha256: 'AB',
    );
    AppMetadata.remember(value);
    expect(AppMetadata.cached, same(value));
    expect(AppMetadata.cached!.isKnown, isTrue);

    const unknown = AppMetadata(versionName: '', versionCode: 0);
    AppMetadata.remember(unknown);
    expect(AppMetadata.cached!.isKnown, isFalse);
  });

  test('чтение метаданных не бросает ошибку даже вне приложения', () async {
    final value = await AppMetadata.load();
    expect(value, isA<AppMetadata>());
    expect(AppMetadata.cached, same(value));
    // Тестовый раннер — не сборка клиента: версия может быть неизвестна,
    // и это честный результат, а не падение.
    expect(value.versionCode, greaterThanOrEqualTo(0));
  });

  test('ресурс версии Windows читается у системного файла', () {
    if (!Platform.isWindows) return;
    final info = windowsFixedFileInfo(r'C:\Windows\System32\kernel32.dll');
    expect(info, isNotNull);
    // Windows 10 и 11 обе сообщают старший разряд 10.
    expect((info!.ms >> 16) & 0xFFFF, 10);
    expect(info.ls, greaterThan(0));
  });

  test('файл без ресурса версии и отсутствующий путь дают null', () {
    if (!Platform.isWindows) return;
    final temp = Directory.systemTemp.createTempSync('cvpn-meta');
    addTearDown(() => temp.deleteSync(recursive: true));
    final plain = File('${temp.path}${Platform.pathSeparator}plain.txt')
      ..writeAsStringSync('не исполняемый файл');
    expect(windowsFixedFileInfo(plain.path), isNull);
    expect(
      windowsFixedFileInfo('${temp.path}${Platform.pathSeparator}нет-такого.dll'),
      isNull,
    );
  });
}