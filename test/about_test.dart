import 'dart:io';

import 'package:client_vpn/about_screen.dart';
import 'package:client_vpn/app_metadata.dart';
import 'package:client_vpn/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Locale locale) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const AboutScreen(),
    );

void main() {
  test('версия в коде не зашита: экран читает метаданные сборки', () {
    final source = File('lib/about_screen.dart').readAsStringSync();
    expect(source, isNot(contains('clientVersion')));
    expect(source, contains('AppMetadata'));
    // Жёсткая строка версии в любом файле lib снова разойдётся с pubspec.
    final hardcoded = RegExp(r"const String \w*[Vv]ersion\w* = '\d+\.\d+");
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      expect(hardcoded.hasMatch(file.readAsStringSync()), isFalse,
          reason: 'жёстко заданная версия: ${file.path}');
    }
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    expect(line.substring('version:'.length).trim(), matches(r'^\d+\.\d+\.\d+\+\d+$'));
  });

  test('LICENSE и NOTICE лежат в бандле сборки', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- LICENSE'));
    expect(pubspec, contains('- NOTICE'));
    for (final name in ['LICENSE', 'NOTICE']) {
      final text = File(name).readAsStringSync();
      expect(text.length, greaterThan(200), reason: name);
    }
    expect(File('LICENSE').readAsStringSync(), contains('Mozilla Public License'));
  });

  testWidgets('экран показывает версию из метаданных, лицензию и заявление о сборе данных',
      (tester) async {
    AppMetadata.remember(const AppMetadata(
      versionName: '0.4.6',
      versionCode: 4,
      applicationId: 'com.clientvpn.client_vpn',
    ));
    await tester.pumpWidget(_app(const Locale('ru')));
    expect(find.text('О программе'), findsOneWidget);
    expect(find.text('Версия 0.4.6'), findsOneWidget);
    expect(find.text('Mozilla Public License 2.0'), findsOneWidget);
    expect(find.textContaining('не собирает статистику'), findsOneWidget);
  });

  testWidgets('нечитаемые метаданные не подменяются выдуманной версией',
      (tester) async {
    AppMetadata.remember(const AppMetadata(versionName: '', versionCode: 0));
    await tester.pumpWidget(_app(const Locale('ru')));
    expect(find.text('Версия не определена'), findsOneWidget);
  });

  testWidgets('NOTICE открывается целиком', (tester) async {
    await tester.pumpWidget(_app(const Locale('ru')));
    await tester.tap(find.text('Уведомления о зависимостях'));
    await tester.pumpAndSettle();
    expect(find.text('Уведомления о зависимостях'), findsWidgets);
    // текст файла грузится из бандла: в нём есть строка про Xray-core
    final notice = File('NOTICE').readAsStringSync();
    final firstLine = notice
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty)
        .trim();
    await tester.pump();
    expect(find.textContaining(firstLine, findRichText: true), findsWidgets);
  });

  testWidgets('английская локализация экрана собрана', (tester) async {
    await tester.pumpWidget(_app(const Locale('en')));
    expect(find.text('About'), findsOneWidget);
    expect(find.textContaining('collects no statistics'), findsOneWidget);
  });
}
