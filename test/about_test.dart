import 'dart:io';

import 'package:client_vpn/about_screen.dart';
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
  test('версия на экране «О программе» совпадает с pubspec.yaml', () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    // 0.3.0 и 0.3.0+5 — одна и та же сборка для пользователя
    expect(clientVersion, line.substring('version:'.length).trim().split('+').first);
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

  testWidgets('экран показывает версию, лицензию и заявление о сборе данных',
      (tester) async {
    await tester.pumpWidget(_app(const Locale('ru')));
    expect(find.text('О программе'), findsOneWidget);
    expect(find.text('Версия $clientVersion'), findsOneWidget);
    expect(find.text('Mozilla Public License 2.0'), findsOneWidget);
    expect(find.textContaining('не собирает статистику'), findsOneWidget);
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
