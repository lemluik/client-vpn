import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'vpn_config.dart';
import 'vpn_core.dart';

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
        size: Size(500, 700),
        center: true,
        minimumSize: Size(500, 700),
        title: 'КлиентВПН',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  runApp(const ClientVpnApp());
}

class ClientVpnApp extends StatelessWidget {
  const ClientVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'КлиентВПН',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WindowListener {
  final VpnCore _core = createVpnCore();
  final List<String> _logLines = [];
  final ScrollController _logScroll = ScrollController();

  VpnConfig? _config;
  bool _isValid = false;
  bool _isConnected = false;
  bool _isConnecting = false;
  String? _validationError;
  StreamSubscription<String>? _logSub;
  StreamSubscription<bool>? _statusSub;

  @override
  void initState() {
    super.initState();
    if (isDesktop) {
      windowManager.addListener(this);
      unawaited(_core.recoverAfterCrash());
    }
    _logSub = _core.logs.listen(_addLog);
    _statusSub = _core.statusChanges.listen((running) {
      if (!mounted) return;
      setState(() {
        _isConnected = running;
        _isConnecting = false;
      });
    });
    unawaited(_loadSavedConfig());
  }

  @override
  void onWindowClose() async {
    await _core.stop();
    await windowManager.destroy();
  }

  Future<void> _loadSavedConfig() async {
    final config = await loadSavedVpnConfig();
    if (config == null || !mounted) return;
    setState(() => _config = config);
    await _validateConfig(config);
  }

  void _addLog(String line) {
    if (!mounted) return;
    setState(() {
      _logLines.add(line);
      if (_logLines.length > 200) {
        _logLines.removeRange(0, _logLines.length - 200);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.animateTo(
          _logScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _pickConfig() async {
    final config = await pickVpnConfig();
    if (config == null) return;

    await saveVpnConfig(config);
    if (!mounted) return;
    setState(() {
      _config = config;
      _isValid = false;
      _validationError = null;
    });

    await _validateConfig(config);
  }

  Future<void> _validateConfig(VpnConfig config) async {
    setState(() {
      _isConnecting = true;
      _validationError = null;
    });

    try {
      await _core.validate(config);
      if (!mounted) return;
      setState(() {
        _isValid = true;
        _isConnecting = false;
      });
      _addLog('Конфиг валиден: ${config.name}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isValid = false;
        _validationError = e.toString();
        _isConnecting = false;
      });
      _addLog('Ошибка валидации: $e');
    }
  }

  Future<void> _connect() async {
    final config = _config;
    if (config == null || !_isValid) return;

    setState(() => _isConnecting = true);
    _addLog('Подключение...');

    try {
      await _core.start(config);
    } catch (e) {
      _addLog('Ошибка подключения: $e');
      if (!mounted) return;
      setState(() => _isConnecting = false);
    }
  }

  Future<void> _disconnect() async {
    _addLog('Отключение...');
    await _core.stop();
    if (!mounted) return;
    setState(() {
      _isConnected = false;
      _isConnecting = false;
    });
  }

  @override
  void dispose() {
    if (isDesktop) windowManager.removeListener(this);
    _logSub?.cancel();
    _statusSub?.cancel();
    _logScroll.dispose();
    unawaited(_core.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('КлиентВПН v0.2.0'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildConfigSection(),
            const SizedBox(height: 24),
            _buildConnectButton(),
            const SizedBox(height: 16),
            _buildStatusSection(),
            const SizedBox(height: 24),
            _buildLogSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildConfigSection() {
    final config = _config;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isConnected ? null : _pickConfig,
                    icon: const Icon(Icons.file_open),
                    label: const Text('Выбрать config.json'),
                  ),
                ),
                if (_isValid) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.check_circle, color: Colors.green, size: 28),
                ],
                if (_validationError != null) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.error, color: Colors.red, size: 28),
                ],
              ],
            ),
            if (config != null) ...[
              const SizedBox(height: 12),
              Text(
                'Файл: ${config.name}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
            if (_validationError != null) ...[
              const SizedBox(height: 8),
              Text(
                _validationError!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.red),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildConnectButton() {
    if (_isConnected) {
      return SizedBox(
        height: 56,
        child: FilledButton.tonalIcon(
          onPressed: _disconnect,
          icon: const Icon(Icons.power_settings_new),
          label: const Text('ОТКЛЮЧИТЬ', style: TextStyle(fontSize: 18)),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.red.shade50,
            foregroundColor: Colors.red.shade700,
          ),
        ),
      );
    }

    return SizedBox(
      height: 56,
      child: FilledButton.icon(
        onPressed:
            (_config != null && _isValid && !_isConnecting) ? _connect : null,
        icon: _isConnecting
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.power_settings_new),
        label: Text(
          _isConnecting ? 'ПОДКЛЮЧЕНИЕ...' : 'ПОДКЛЮЧИТЬ',
          style: const TextStyle(fontSize: 18),
        ),
      ),
    );
  }

  Widget _buildStatusSection() {
    final status = _isConnected ? 'Подключён' : 'Отключён';
    final color = _isConnected ? Colors.green : Colors.grey;
    final endpoint = _core.endpointLabel;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.circle, color: color, size: 16),
            const SizedBox(width: 8),
            Text(
              'Статус: $status',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (endpoint != null && _isConnected) ...[
              const Spacer(),
              Flexible(
                child: Text(
                  endpoint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLogSection() {
    return Expanded(
      child: Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('Лог', style: Theme.of(context).textTheme.titleSmall),
            ),
            const Divider(height: 1),
            Expanded(
              child: _logLines.isEmpty
                  ? const Center(child: Text('Пусто'))
                  : ListView.builder(
                      controller: _logScroll,
                      padding: const EdgeInsets.all(8),
                      itemCount: _logLines.length,
                      itemBuilder: (context, i) {
                        final line = _logLines[i];
                        final isError = line.startsWith('[ERR]');
                        return Text(
                          line,
                          style: TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 12,
                            color: isError ? Colors.red : null,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
