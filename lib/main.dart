import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app_state.dart';
import 'home_screen.dart';
import 'l10n/app_localizations.dart';

/// Окно и системный прокси существуют только на десктопе: на Android
/// подключение поднимает VpnService, а window_manager там не зарегистрирован.
final bool isDesktop =
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (isDesktop) {
    await windowManager.ensureInitialized();

    // Без этого окно закрывается сразу, не дожидаясь onWindowClose,
    // и ядро остаётся сиротой при включённом системном прокси.
    await windowManager.setPreventClose(true);

    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(500, 760),
        center: true,
        minimumSize: Size(420, 620),
        title: 'КлиентВПН',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  final state = await AppState.create();
  runApp(ClientVpnApp(state: state));

  // Восстановление идёт уже после первого кадра: снятие системного прокси,
  // опрос сервиса Android и подписки по интервалу не должны задерживать
  // запуск интерфейса.
  unawaited(state.recover());
}

class ClientVpnApp extends StatefulWidget {
  const ClientVpnApp({required this.state, super.key});

  final AppState state;

  @override
  State<ClientVpnApp> createState() => _ClientVpnAppState();
}

class _ClientVpnAppState extends State<ClientVpnApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    if (isDesktop) windowManager.addListener(this);
  }

  @override
  void dispose() {
    if (isDesktop) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    await widget.state.disconnect();
    widget.state.dispose();
    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) => MaterialApp(
        title: 'КлиентВПН',
        debugShowCheckedModeBanner: false,
        // Язык берётся с устройства: русская и около-русская локаль дают русский,
        // англоязычная — английский, прочая откатывается на русский как первый.
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: _theme(lightDynamic, Brightness.light),
        darkTheme: _theme(darkDynamic, Brightness.dark),
        home: HomeScreen(state: widget.state),
      ),
    );
  }

  /// Палитра берётся из цветов системы: Android 12+ отдаёт собственную схему,
  /// десктоп — акцентный цвет. До ответа системы и на устройствах без такой
  /// палитры остаётся посевной синий, поэтому интерфейс никогда не бывает
  /// бесцветным.
  static ThemeData _theme(ColorScheme? dynamic, Brightness brightness) =>
      ThemeData(
        useMaterial3: true,
        colorScheme: dynamic ??
            ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: brightness,
            ),
      );
}
