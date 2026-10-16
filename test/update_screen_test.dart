import 'package:client_vpn/about_screen.dart' show clientVersion;
import 'package:client_vpn/l10n/app_localizations.dart';
import 'package:client_vpn/update_check.dart' show defaultUpdateFeed;
import 'package:client_vpn/update_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Экран проверяется без сети: в зоне `TestWidgetsFlutterBinding` настоящий
/// `HttpClient` всегда отвечает 400 и запрос наружу не уходит, поэтому сюда
/// попадает только путь с плохим адресом — он запроса не делает. Ответы
/// источника и сравнение версий тестируются в `update_check_test.dart`.
Widget _app(Locale locale) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const UpdateScreen(),
    );

String _fieldText(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText)).controller.text;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('экран показывает текущую версию и адрес источника по умолчанию',
      (tester) async {
    await tester.pumpWidget(_app(const Locale('ru')));
    await tester.pumpAndSettle();

    expect(find.text('Обновление'), findsWidgets);
    expect(find.text('Версия $clientVersion'), findsOneWidget);
    expect(_fieldText(tester), defaultUpdateFeed);
  });

  testWidgets('плохой адрес отсекается до запроса', (tester) async {
    await tester.pumpWidget(_app(const Locale('ru')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'без схемы');
    await tester.tap(find.text('Проверить обновление'));
    await tester.pump();

    expect(
      find.text('Адрес должен начинаться с http:// или https://'),
      findsOneWidget,
    );
  });

  testWidgets('английская локализация экрана обновления собрана', (tester) async {
    await tester.pumpWidget(_app(const Locale('en')));
    await tester.pumpAndSettle();
    expect(find.text('Check for update'), findsOneWidget);
    expect(find.textContaining('release manifest'), findsOneWidget);
  });
}
