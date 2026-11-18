import 'package:client_vpn/app_metadata.dart';
import 'package:client_vpn/l10n/app_localizations.dart';
import 'package:client_vpn/services/service_config.dart';
import 'package:client_vpn/update_check.dart'
    show defaultUpdateFeed, resolveUpdateSource;
import 'package:client_vpn/update_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Экран проверяется без сети: в зоне `TestWidgetsFlutterBinding` настоящий
/// `HttpClient` всегда отвечает 400 и запрос наружу не уходит, поэтому сюда
/// попадает только путь с плохим адресом — он запроса не делает. Ответы
/// источника и сравнение версий тестируются в `update_check_test.dart` и
/// `update_gate_test.dart`.
///
/// Ожидания берутся из конфигурации сборки, а не из зашитых строк: в открытом
/// дереве приватного слоя нет и источник — публичный репозиторий, в закрытом —
/// своя точка. Тест обязан проходить в обоих деревьях.
Widget _app(Locale locale) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const UpdateScreen(),
    );

String _fieldText(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText)).controller.text;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // rootBundle кэширует future загрузки ассета. Созданный в зоне прошлого
    // теста, в следующем он не завершается: экран висит на чтении конфигурации
    // до таймаута. Сброс кэша делает загрузку своей в каждом тесте.
    rootBundle.clear();
    AppMetadata.remember(const AppMetadata(
      versionName: '0.4.6',
      versionCode: 4,
      applicationId: 'com.clientvpn.client_vpn',
    ));
  });

  testWidgets('экран показывает версию из метаданных и адрес источника сборки',
      (tester) async {
    final source = resolveUpdateSource(config: await ServiceConfig.load());
    await tester.pumpWidget(_app(const Locale('ru')));
    await tester.pumpAndSettle();

    expect(find.text('Обновление'), findsWidgets);
    expect(find.text('Версия 0.4.6'), findsOneWidget);
    expect(_fieldText(tester), source.feed);
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
    final config = await ServiceConfig.load();
    final own = config.updateChannel == 'closed';
    await tester.pumpWidget(_app(const Locale('en')));
    await tester.pumpAndSettle();
    expect(find.text('Check for update'), findsOneWidget);
    expect(
      find.textContaining(own ? 'own distribution point' : 'release manifest'),
      findsOneWidget,
    );
  });

  testWidgets('нечитаемые метаданные показываются честно, а не выдуманной версией',
      (tester) async {
    AppMetadata.remember(const AppMetadata(versionName: '', versionCode: 0));
    await tester.pumpWidget(_app(const Locale('ru')));
    await tester.pumpAndSettle();
    expect(find.text('Версия не определена'), findsOneWidget);
    expect(find.textContaining('Версия 0.'), findsNothing);
  });

  test('адрес по умолчанию остаётся публичным каналом открытой сборки', () {
    expect(defaultUpdateFeed, startsWith('https://api.github.com/'));
    expect(resolveUpdateSource().channel, 'public');
  });
}