import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'system_proxy.dart';
import 'xray_process.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  // Без этого окно закрывается сразу, не дожидаясь onWindowClose,
  // и xray.exe остаётся сиротой при включённом системном прокси.
  await windowManager.setPreventClose(true);

  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      minimumSize: Size(560, 700),
      title: 'КлиентВПН',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  await SystemProxy.cleanupAfterCrash();
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
  final XrayProcessManager _xray = XrayProcessManager();
  final List<String> _logLines = [];
  final ScrollController _logScroll = ScrollController();

  String? _configPath;
  String? _configName;
  bool _isValid = false;
  bool _isConnected = false;
  bool _isConnecting = false;
  String? _validationError;
  ({String protocol, int port})? _proxy;
  StreamSubscription<String>? _logSub;
  StreamSubscription<bool>? _statusSub;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _loadSavedConfig();
    _logSub = _xray.logs.listen(_addLog);
    _statusSub = _xray.statusChanges.listen((running) async {
      if (!running) {
        await SystemProxy.disable();
        if (mounted) _addLog('Системный прокси отключён (Xray остановлен)');
      }
      if (!mounted) return;
      setState(() {
        _isConnected = running;
        _isConnecting = false;
      });
    });
  }

  @override
  void onWindowClose() async {
    await _shutdown();
    await windowManager.destroy();
  }

  Future<void> _shutdown() async {
    await _xray.stop();
    await SystemProxy.disable();
  }

  Future<void> _loadSavedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString('config_path');
    if (path != null && await File(path).exists()) {
      if (!mounted) return;
      setState(() {
        _configPath = path;
        _configName = path.split(Platform.pathSeparator).last;
      });
      await _validateConfig(path);
    }
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
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      allowMultiple: false,
    );

    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('config_path', path);

    if (!mounted) return;
    setState(() {
      _configPath = path;
      _configName = path.split(Platform.pathSeparator).last;
      _isValid = false;
      _validationError = null;
      _proxy = null;
    });

    await _validateConfig(path);
  }

  Future<void> _validateConfig(String path) async {
    setState(() {
      _isConnecting = true;
      _validationError = null;
    });

    try {
      await _xray.testConfig(path);
      final proxy = await _extractProxy(path);

      if (proxy == null) {
        setState(() {
          _isValid = false;
          _proxy = null;
          _validationError =
              'В конфиге нет inbound с протоколом http или socks — '
              'включить системный прокси нельзя.';
          _isConnecting = false;
        });
        _addLog('Ошибка: не найден http/socks inbound');
        return;
      }

      setState(() {
        _isValid = true;
        _proxy = proxy;
        _isConnecting = false;
      });
      _addLog('Конфиг валиден, прокси: ${proxy.protocol} 127.0.0.1:${proxy.port}');
    } catch (e) {
      setState(() {
        _isValid = false;
        _validationError = e.toString();
        _isConnecting = false;
      });
      _addLog('Ошибка валидации: $e');
    }
  }

  Future<({String protocol, int port})?> _extractProxy(String configPath) async {
    final config = jsonDecode(await File(configPath).readAsString())
        as Map<String, dynamic>;
    final inbounds = config['inbounds'] as List<dynamic>?;
    if (inbounds == null) return null;

    for (final inbound in inbounds) {
      final ib = inbound as Map<String, dynamic>;
      final protocol = ib['protocol'];
      if (protocol != 'http' && protocol != 'socks') continue;

      final port = _parsePort(ib['port']);
      if (port == null) continue;

      return (protocol: protocol as String, port: port);
    }
    return null;
  }

  static int? _parsePort(dynamic raw) => switch (raw) {
        final int value => value,
        final String value => int.tryParse(value.trim()),
        _ => null,
      };

  Future<void> _connect() async {
    final proxy = _proxy;
    if (_configPath == null || !_isValid || proxy == null) return;

    setState(() => _isConnecting = true);
    _addLog('Подключение...');

    try {
      await SystemProxy.enable(
        '127.0.0.1',
        proxy.port,
        socks: proxy.protocol == 'socks',
      );
      _addLog('Системный прокси: ${proxy.protocol} 127.0.0.1:${proxy.port}');

      await _xray.start(_configPath!);
    } catch (e) {
      _addLog('Ошибка подключения: $e');
      await SystemProxy.disable();
      if (!mounted) return;
      setState(() => _isConnecting = false);
    }
  }

  Future<void> _disconnect() async {
    _addLog('Отключение...');
    await _xray.stop();
    await SystemProxy.disable();
    _addLog('Системный прокси отключён');
    if (!mounted) return;
    setState(() {
      _isConnected = false;
      _isConnecting = false;
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _logSub?.cancel();
    _statusSub?.cancel();
    _logScroll.dispose();
    unawaited(_xray.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('КлиентВПН v0.1.0'),
        centerTitle: true,
      ),
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
            if (_configName != null) ...[
              const SizedBox(height: 12),
              Text(
                'Файл: $_configName',
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
        onPressed: (_configPath != null && _isValid && !_isConnecting)
            ? _connect
            : null,
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
            if (_proxy != null && _isConnected) ...[
              const Spacer(),
              Text(
                '${_proxy!.protocol} 127.0.0.1:${_proxy!.port}',
                style: Theme.of(context).textTheme.bodySmall,
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
              child: Text(
                'Лог',
                style: Theme.of(context).textTheme.titleSmall,
              ),
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
