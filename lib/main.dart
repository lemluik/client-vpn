import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app_state.dart';
import 'home_screen.dart';

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
    widget.state.addListener(_onChange);
    // Первая отрисована: окно видно, пока поднимается туннель.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(widget.state.autoConnectOnLaunch());
    });
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.state.removeListener(_onChange);
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
    return MaterialApp(
      title: 'КлиентВПН',
      debugShowCheckedModeBanner: false,
      themeMode: widget.state.themeChoice.mode,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: HomeScreen(state: widget.state),
    );
  }
}
