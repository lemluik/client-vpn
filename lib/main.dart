import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, SystemNavigator;
import 'package:window_manager/window_manager.dart';

import 'app_state.dart';
import 'auto_update_checker.dart';
import 'close_prompt.dart';
import 'home_screen.dart';
import 'l10n/app_localizations.dart';
import 'path_probe.dart';
import 'settings_store.dart';
import 'traffic.dart';
import 'tray_controller.dart';
import 'windows_guard.dart';

/// Окно и системный прокси существуют только на десктопе: на Android
/// подключение поднимает VpnService, а window_manager там не зарегистрирован.
final bool isDesktop =
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// Мьютекс одиночного экземпляра. Держим ручку до конца процесса: при
/// внешнем убийстве приложения операционная система закрывает её сама.
SingleInstanceLock? _instanceLock;

/// macOS: Cmd+Q и «Завершить» в Dock приходят сюда из AppDelegate.swift,
/// а ответ `allowQuit` разрешает системе завершить приложение.
const MethodChannel _appChannel = MethodChannel('client_vpn/app');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Второй экземпляр не поднимается: два процесса спорят из-за системного
  // прокси и порта локального входа, и подключение рвётся у обоих.
  if (Platform.isWindows) {
    _instanceLock = SingleInstanceLock.tryAcquire();
    if (_instanceLock == null) {
      runApp(const AlreadyRunningApp());
      return;
    }
  }

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
  /// Навигатор нужен запросу закрытия: событие приходит от операционной
  /// системы, и своего контекста у него нет.
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();

  AppTray? _tray;
  AppLocalizations? _l10n;
  bool _trayAttempted = false;
  bool _trayMounted = false;
  bool _quitting = false;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    if (isDesktop) {
      windowManager.addListener(this);
      widget.state.addListener(_updateTrayTooltip);
    }
    if (Platform.isMacOS) {
      _appChannel.setMethodCallHandler((call) async {
        if (call.method == 'quitRequested') await _shutdown();
      });
    }
    widget.state.addListener(_onChange);
    // Первая отрисована: окно видно, пока поднимается туннель.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(widget.state.autoConnectOnLaunch());
    });
  }

  /// Пересборка нужна самому `MaterialApp`: тема живёт в его `themeMode`.
  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.state.removeListener(_onChange);
    if (isDesktop) {
      widget.state.removeListener(_updateTrayTooltip);
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // _asking держит повторные события: крестик на строке названия нажимается
    // и тогда, когда поверх окна уже висит запрос.
    if (_quitting || _asking) return;
    switch (resolveClose(widget.state.closeAction, trayMounted: _trayMounted)) {
      case ResolvedClose.hide:
        await _hideWindow();
      case ResolvedClose.quit:
        await _shutdown();
      case ResolvedClose.ask:
        await _askBeforeClose();
    }
  }

  /// Запрос при закрытии. Отмена оставляет окно открытым: крестик жмут по
  /// привычке, а разрыв подключения одним кликом не отыгрывается.
  Future<void> _askBeforeClose() async {
    final context = _navigator.currentContext;
    if (context == null) return;
    _asking = true;
    final choice = await showClosePrompt(context);
    _asking = false;
    if (choice == null) return;
    if (choice.remember) await widget.state.setCloseAction(choice.action);
    if (choice.action == CloseAction.tray) {
      await _hideWindow();
    } else {
      await _shutdown();
    }
  }

  /// Сворачивание, а не разрыв: подключение продолжает работать, а выход
  /// остаётся пунктом меню трея. Если трей ещё не смонтирован (race condition
  /// с закрытием окна до завершения `_ensureTray`), монтируем сейчас — иначе
  /// окно спрячется без возможности вернуться.
  Future<void> _hideWindow() async {
    if (!_trayMounted && _tray != null && _l10n != null) {
      final mounted = await _tray!.mount(
        tooltip: _tooltipText(_l10n!),
        showLabel: _l10n!.trayShowWindow,
        quitLabel: _l10n!.trayQuit,
      );
      if (mounted) setState(() => _trayMounted = true);
    }
    await windowManager.hide();
  }

  /// Полный выход: снять туннель, убрать трей, отдать мьютекс, уничтожить окно.
  Future<void> _shutdown() async {
    if (_quitting) return;
    _quitting = true;
    await widget.state.disconnect();
    widget.state.dispose();
    await _tray?.unmount();
    _instanceLock?.release();
    if (Platform.isMacOS) await _appChannel.invokeMethod<void>('allowQuit');
    await windowManager.destroy();
  }

  void _ensureTray(AppLocalizations l10n) {
    if (_trayAttempted || !(Platform.isWindows || Platform.isMacOS)) return;
    _trayAttempted = true;
    final tray = AppTray(
      onShowWindow: _showWindow,
      onQuit: () => unawaited(_shutdown()),
    );
    _tray = tray;
    unawaited(
      tray
          .mount(
            tooltip: _tooltipText(l10n),
            showLabel: l10n.trayShowWindow,
            quitLabel: l10n.trayQuit,
          )
          .then((mounted) {
            if (mounted) setState(() => _trayMounted = true);
          }),
    );
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  void _updateTrayTooltip() {
    final l10n = _l10n;
    if (l10n == null) return;
    unawaited(_tray?.setTooltip(_tooltipText(l10n)));
  }

  /// Подсказка трея одной строкой: `szTip` в NOTIFYICONDATA переводов строк
  /// не показывает, поэтому статус, скорость и итог сессии разделяются «·».
  /// `setTitle` на Windows не работает и трей роняет — только `setToolTip`.
  String _tooltipText(AppLocalizations l10n) {
    final base = '${l10n.appTitle} — ${_statusText(l10n)}';
    final traffic = widget.state.traffic;
    if (traffic == null || !widget.state.isConnected) return base;
    return '$base · '
        '${l10n.trafficRate(formatBytes(traffic.upSpeed), formatBytes(traffic.downSpeed))} · '
        '${l10n.trafficSession(formatBytes(traffic.totalUp), formatBytes(traffic.totalDown))}';
  }

  String _statusText(AppLocalizations l10n) => switch (widget.state.state) {
    // Подсказка трея говорит то же, что строка статуса на экране: защита
    // обещается только после подтверждения пути до узла (Д2-25).
    TunnelState.on => switch (widget.state.pathState) {
      PathState.live => l10n.statusProtected,
      PathState.checking => l10n.statusLinking,
      PathState.dead => l10n.statusUnreachable,
      PathState.unknown => l10n.statusConnected,
    },
    TunnelState.connecting => l10n.statusConnecting,
    TunnelState.failure => l10n.statusFailed,
    TunnelState.noLink => l10n.statusNoLink,
    TunnelState.off => l10n.statusOff,
  };

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) => MaterialApp(
        title: 'КлиентВПН',
        navigatorKey: _navigator,
        debugShowCheckedModeBanner: false,
        // Язык берётся с устройства: русская и около-русская локаль дают русский,
        // англоязычная — английский, прочая откатывается на русский как первый.
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        themeMode: widget.state.themeChoice.mode,
        theme: _theme(lightDynamic, Brightness.light),
        darkTheme: _theme(darkDynamic, Brightness.dark),
        home: Builder(
          builder: (context) {
            // Локализация нужна и для меню трея, которое живёт вне дерева
            // виджетов, поэтому экземпляр запоминаем при первом кадре.
            final l10n = AppLocalizations.of(context);
            _l10n = l10n;
            _ensureTray(l10n);
            return Stack(
              children: [
                HomeScreen(state: widget.state),
                // Windows: перед подменой файлов приложение обязано выйти,
                // иначе собственный exe заблокирован процессом.
                AutoUpdateChecker(onQuit: _shutdown),
              ],
            );
          },
        ),
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
        colorScheme:
            dynamic ??
            ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: brightness,
            ),
      );
}

/// Экран-объяснение для второго экземпляра: молча не стартовать нельзя,
/// пользователь решит, что приложение не открывается.
class AlreadyRunningApp extends StatelessWidget {
  const AlreadyRunningApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'КлиентВПН',
      debugShowCheckedModeBanner: false,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Builder(
        builder: (context) {
          final l10n = AppLocalizations.of(context);
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.doorbell_outlined, size: 40),
                    const SizedBox(height: 12),
                    Text(
                      l10n.alreadyRunningTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(l10n.alreadyRunningBody, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: SystemNavigator.pop,
                      child: Text(l10n.alreadyRunningClose),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
