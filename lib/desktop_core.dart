import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'proxy_config.dart';
import 'system_proxy.dart';
import 'vpn_config.dart';
import 'vpn_core.dart';

/// Ядро на десктопе: процесс xray с локальным http/socks inbound
/// плюс системный прокси, который на этот inbound переключается.
class DesktopCore implements VpnCore {
  /// Эталонная версия Xray-core, под которую собран клиент.
  static const version = '26.3.27';

  /// SHA2-256 официального xray.exe из Xray-windows-64.zip v26.3.27.
  /// Сверяется перед каждым запуском: подменённый бинарник выполнен не будет.
  static const _expectedSha256 =
      '15c2d007954ac53ba69b80ec91242786b3c0b71d52649165b4ca1d5cc96ef8f1';

  Process? _process;
  final StreamController<String> _logController =
      StreamController<String>.broadcast();
  final StreamController<bool> _statusController =
      StreamController<bool>.broadcast();

  ProxyEndpoint? _proxy;

  @override
  Stream<String> get logs => _logController.stream;

  @override
  Stream<bool> get statusChanges => _statusController.stream;

  @override
  bool get isRunning => _process != null;

  @override
  String? get endpointLabel {
    final proxy = _proxy;
    if (proxy == null) return null;
    return '${proxy.protocol} 127.0.0.1:${proxy.port}';
  }

  Future<String> _findXrayExecutable() async {
    final exeDir = p.dirname(Platform.resolvedExecutable);

    for (final candidate in [
      File(p.join(exeDir, 'xray', 'xray.exe')),
      File(p.join(exeDir, 'xray.exe')),
      File('assets/xray/xray.exe'),
    ]) {
      if (await candidate.exists()) {
        await _verifyChecksum(candidate);
        return candidate.absolute.path;
      }
    }

    throw Exception(
      'xray.exe не найден. Скачайте его: bash scripts/download_xray.sh',
    );
  }

  Future<void> _verifyChecksum(File file) async {
    final actual = '${await sha256.bind(file.openRead()).first}';
    if (actual != _expectedSha256) {
      throw Exception('Проверка целостности xray.exe не пройдена.\n'
          'Ожидался SHA2-256 $_expectedSha256\n'
          'Получен  SHA2-256 $actual\n'
          'Файл повреждён или подменён — запуск отменён. '
          'Перекачайте бинарник: bash scripts/download_xray.sh');
    }
  }

  /// Каталог geo-баз: `geoip.dat`/`geosite.dat` лежат рядом с бинарником.
  /// Передаётся ядру явно, потому что поиск по рабочему каталогу не работает,
  /// когда конфиг читается из временной папки профиля.
  static Map<String, String> _coreEnvironment(String xrayPath) => {
        'XRAY_LOCATION_ASSET': p.dirname(xrayPath),
      };

  @override
  Future<void> validate(VpnConfig config) async {
    final path = config.path;
    if (path == null) {
      throw Exception('На этой платформе конфиг нужно выбрать файлом.');
    }

    final xrayPath = await _findXrayExecutable();
    final result = await Process.run(
      xrayPath,
      ['run', '-test', '-config', path],
      workingDirectory: p.dirname(xrayPath),
      environment: _coreEnvironment(xrayPath),
    );

    if (result.exitCode != 0) {
      final out = '${result.stdout}'.trim();
      final err = '${result.stderr}'.trim();
      throw Exception(
        'Валидация не пройдена (код ${result.exitCode}):\n$out\n$err'
        '${_geoHint('$out$err')}',
      );
    }

    final proxy = parseProxyInbound(config.json);
    if (proxy == null) {
      throw Exception(
        'В конфиге нет inbound с протоколом http или socks — '
        'включить системный прокси нельзя.',
      );
    }
    _proxy = proxy;
  }

  /// Правила `geoip:`/`geosite:` не работают без geo-баз: ядро сообщает об этом
  /// по-английски и без указания, где взять файлы.
  static String _geoHint(String output) =>
      output.contains('geosite.dat') || output.contains('geoip.dat')
          ? '\nGeo-базы не установлены — выполните: bash scripts/download_xray.sh'
          : '';

  @override
  Future<void> start(VpnConfig config) async {
    final proxy = _proxy;
    if (_process != null) {
      throw Exception('Xray уже запущен');
    }
    if (proxy == null) {
      throw Exception('Конфиг не проверен');
    }
    final path = config.path!;

    await _awaitFreePort(proxy.port);

    await SystemProxy.enable(
      '127.0.0.1',
      proxy.port,
      socks: proxy.protocol == 'socks',
    );
    _logController.add(
      'Системный прокси: ${proxy.protocol} 127.0.0.1:${proxy.port}',
    );

    try {
      await _spawn(path);
    } catch (e) {
      await SystemProxy.disable();
      rethrow;
    }
  }

  /// Порт локального inbound освобождается не в тот момент, когда ядро
  /// завершилось: новое ядро, запущенное сразу после остановки старого,
  /// падало с «bind: Only one usage of each socket address». Ждём освобождения
  /// и говорим о занятом порте прямо, а не через сообщение ядра.
  Future<void> _awaitFreePort(int port) async {
    for (var attempt = 1; attempt <= 10; attempt++) {
      ServerSocket? probe;
      try {
        probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        return;
      } on SocketException {
        _logController.add(
          'Порт 127.0.0.1:$port ещё занят, жду освобождения ($attempt/10)',
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } finally {
        await probe?.close();
      }
    }

    throw Exception(
      'Порт 127.0.0.1:$port занят другим приложением. '
      'Освободите порт или выберите профиль с другим портом.',
    );
  }

  Future<void> _spawn(String configPath) async {
    final xrayPath = await _findXrayExecutable();

    _logController.add('Запуск: ${p.basename(xrayPath)}');
    _logController.add('Конфиг: ${p.basename(configPath)}');

    _process = await Process.start(
      xrayPath,
      ['run', '-config', configPath],
      workingDirectory: p.dirname(xrayPath),
      environment: _coreEnvironment(xrayPath),
    );

    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.isNotEmpty) _logController.add(line);
    });

    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.isNotEmpty) _logController.add('[ERR] $line');
    });

    unawaited(
      _process!.exitCode.then((code) async {
        _logController.add('Xray остановлен (код: $code)');
        _process = null;
        await SystemProxy.disable();
        _logController.add('Системный прокси отключён (Xray остановлен)');
        _statusController.add(false);
      }),
    );

    _statusController.add(true);
    _logController.add('Xray запущен (PID: ${_process!.pid})');
  }

  @override
  Future<void> stop() async {
    if (_process == null) {
      await SystemProxy.disable();
      _statusController.add(false);
      return;
    }

    _logController.add('Остановка Xray...');
    _process!.kill(ProcessSignal.sigterm);

    try {
      await _process!.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _logController.add('Принудительная остановка...');
      _process!.kill(ProcessSignal.sigkill);
      // Без ожидания выхода процесс мог остаться держателем порта, и следующее
      // ядро не смогло бы на него встать.
      try {
        await _process!.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        _logController.add('Xray не завершился, порт может остаться занятым');
      }
    }

    _process = null;
    await SystemProxy.disable();
    _statusController.add(false);
    _logController.add('Xray остановлен, системный прокси отключён');
  }

  @override
  Future<void> recoverAfterCrash() => SystemProxy.cleanupAfterCrash();

  @override
  Future<void> dispose() async {
    await stop();
    await _logController.close();
    await _statusController.close();
  }
}
