import 'package:client_vpn/l10n/app_localizations.dart';
import 'package:client_vpn/update_check.dart';
import 'package:client_vpn/update_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

const release = ReleaseInfo(
  version: '0.4.2',
  notes: 'Тестовое обновление',
  links: {'windows': 'https://example.test/app.zip'},
);

/// Диалог живёт в `showDialog`, поэтому проверка одна: нажатие закрывает ровно
/// сам диалог и возвращает свой результат — маршрут под ним остаётся.
Future<void> _pump(WidgetTester tester, CompleterBox box) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('ru'),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async {
              box.value = await UpdateDialog.show(
                context,
                release: release,
                isCritical: false,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

class CompleterBox {
  bool? value;
}

void main() {
  testWidgets('«Обновить» закрывает диалог и оставляет экран', (tester) async {
    final box = CompleterBox();
    await _pump(tester, box);

    await tester.tap(find.text('Обновить'));
    await tester.pumpAndSettle();

    expect(box.value, isTrue);
    expect(find.byType(UpdateDialog), findsNothing);
    // Единственный pop: главный экран с кнопкой на месте.
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('«Позже» — false, «Отключить автопроверку» — null',
      (tester) async {
    for (final (label, expected) in [
      ('Позже', false),
      ('Отключить автопроверку', null),
    ]) {
      final box = CompleterBox();
      await _pump(tester, box);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(box.value, expected, reason: label);
      expect(find.text('open'), findsOneWidget, reason: label);
    }
  });

  testWidgets('критическое обновление — одна кнопка и без «Позже»',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('ru'),
      home: Scaffold(
        body: UpdateDialog(
          release: release,
          isCritical: true,
          onUpdate: () {},
          onLater: () {},
        ),
      ),
    ));
    expect(find.text('Обновить'), findsOneWidget);
    expect(find.text('Позже'), findsNothing);
    expect(find.text('Отключить автопроверку'), findsNothing);
    expect(find.text('Критическое обновление'), findsOneWidget);
  });
}
