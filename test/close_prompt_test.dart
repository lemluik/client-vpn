import 'dart:async';

import 'package:client_vpn/close_prompt.dart';
import 'package:client_vpn/l10n/app_localizations.dart';
import 'package:client_vpn/settings_store.dart';
import 'package:client_vpn/tray_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ответ запроса закрытия, ставший известным после нажатия кнопки.
class PromptAnswer {
  final Completer<CloseChoice?> _completer = Completer<CloseChoice?>();

  void complete(CloseChoice? choice) {
    if (!_completer.isCompleted) _completer.complete(choice);
  }

  Future<CloseChoice?> get answer => _completer.future;
}

/// Открывает запрос поверх корневой страницы — так же, как событие закрытия
/// окна поднимает его над уже нарисованным приложением.
Future<PromptAnswer> openPrompt(WidgetTester tester) async {
  final prompt = PromptAnswer();

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              unawaited(showClosePrompt(context).then(prompt.complete)),
          child: const Text('открыть запрос'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('открыть запрос'));
  await tester.pumpAndSettle();
  return prompt;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('что делает закрытие окна', () {
    test('без трея выходит при любом выборе', () {
      // Иконки в трее нет: свёрнутое окно никто не найдёт, а туннель
      // продолжал бы работать неизвестно где.
      for (final action in CloseAction.values) {
        expect(resolveClose(action, trayMounted: false), ResolvedClose.quit);
      }
    });

    test('выбор пользователя переводится в действие', () {
      expect(
        resolveClose(CloseAction.tray, trayMounted: true),
        ResolvedClose.hide,
      );
      expect(
        resolveClose(CloseAction.quit, trayMounted: true),
        ResolvedClose.quit,
      );
      expect(
        resolveClose(CloseAction.ask, trayMounted: true),
        ResolvedClose.ask,
      );
    });

    test('неизвестное значение в хранилище — спрашивать', () {
      expect(CloseAction.named(null), CloseAction.ask);
      expect(CloseAction.named('minimize'), CloseAction.ask);
      for (final action in CloseAction.values) {
        expect(CloseAction.named(action.name), action);
      }
    });

    test('запомненный выбор переживает перезапуск', () async {
      final store = await SettingsStore.open();
      expect(store.closeAction, CloseAction.ask);

      await store.setCloseAction(CloseAction.tray);

      expect((await SettingsStore.open()).closeAction, CloseAction.tray);
    });
  });

  group('запрос при закрытии', () {
    testWidgets('предлагает трей, выход и отмену', (tester) async {
      await openPrompt(tester);

      expect(find.text('Закрыть окно?'), findsOneWidget);
      expect(find.byKey(const ValueKey('close-tray')), findsOneWidget);
      expect(find.byKey(const ValueKey('close-quit')), findsOneWidget);
      expect(find.text('Отмена'), findsOneWidget);
    });

    testWidgets('текст объясняет разницу между треем и выходом', (
      tester,
    ) async {
      await openPrompt(tester);

      expect(
        find.textContaining('подключение продолжит работать'),
        findsOneWidget,
      );
      expect(find.text('Запомнить выбор'), findsOneWidget);
    });

    testWidgets('свернуть в трей без галочки ничего не запоминает', (
      tester,
    ) async {
      final prompt = await openPrompt(tester);
      await tester.tap(find.byKey(const ValueKey('close-tray')));
      await tester.pumpAndSettle();

      final choice = await prompt.answer;
      expect(choice?.action, CloseAction.tray);
      expect(choice?.remember, isFalse);
      // Запрос окно не закрыл: корневой экран остался на месте.
      expect(find.text('открыть запрос'), findsOneWidget);
    });

    testWidgets('галочка «запомнить» уходит вместе с ответом', (tester) async {
      final prompt = await openPrompt(tester);
      await tester.tap(find.byKey(const ValueKey('close-remember')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('close-quit')));
      await tester.pumpAndSettle();

      final choice = await prompt.answer;
      expect(choice?.action, CloseAction.quit);
      expect(choice?.remember, isTrue);
    });

    testWidgets('отмена не называет никакого действия', (tester) async {
      final prompt = await openPrompt(tester);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();

      expect(await prompt.answer, isNull);
    });
  });

  group('трей', () {
    /// Записывает вызовы, уходящие в нативный плагин трея.
    Future<List<String>> stubTray({
      Object? Function(MethodCall)? on,
    }) async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('tray_manager'), (
            call,
          ) async {
            calls.add(call.method);
            return on?.call(call);
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('tray_manager'),
              null,
            ),
      );
      return calls;
    }

    Future<bool> mountTray() =>
        AppTray(onShowWindow: () {}, onQuit: () {}).mount(
          tooltip: 'КлиентВПН — отключено',
          showLabel: 'Показать',
          quitLabel: 'Выйти',
        );

    test('подсказка ставится методом, который есть у Windows', () async {
      // Живая сборка 16.10 закрытие окна молча выходила: плагин не знает
      // macOS-ного `setTitle`, бросает MissingPluginException, и трей так и
      // не поднимался. Тест ловит подмену метода на канале.
      final calls = await stubTray();
      expect(await mountTray(), isTrue);

      expect(calls, contains('setToolTip'));
      expect(calls, isNot(contains('setTitle')));
    });

    test('отказ нативного трея не оставляет его наполовину поднятым', () async {
      await stubTray(
        on: (call) =>
            call.method == 'setToolTip' ? throw MissingPluginException() : null,
      );
      expect(await mountTray(), isFalse);
    });
  });
}
