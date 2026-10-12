import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class XrayProcessManager {
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
  String? _configPath;

  Stream<String> get logs => _logController.stream;
  Stream<bool> get statusChanges => _statusController.stream;
  bool get isRunning => _process != null;
  String? get currentConfigPath => _configPath;

  Future<String> findXrayExecutable() async {
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

  Future<String> testConfig(String configPath) async {
    final xrayPath = await findXrayExecutable();
    final result = await Process.run(
      xrayPath,
      ['run', '-test', '-config', configPath],
      workingDirectory: p.dirname(xrayPath),
    );

    final output =
        '${result.stdout.toString().trim()}\n${result.stderr.toString().trim()}';
    if (result.exitCode != 0) {
      throw Exception(
        'Валидация не пройдена (код ${result.exitCode}):\n$output',
      );
    }
    return output;
  }

  Future<void> start(String configPath) async {
    if (_process != null) {
      throw Exception('Xray уже запущен');
    }

    final xrayPath = await findXrayExecutable();
    _configPath = configPath;

    _logController.add('Запуск: ${p.basename(xrayPath)}');
    _logController.add('Конфиг: ${p.basename(configPath)}');

    _process = await Process.start(
      xrayPath,
      ['run', '-config', configPath],
      workingDirectory: p.dirname(xrayPath),
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
      _process!.exitCode.then((code) {
        _logController.add('Xray остановлен (код: $code)');
        _process = null;
        _configPath = null;
        _statusController.add(false);
      }),
    );

    _statusController.add(true);
    _logController.add('Xray запущен (PID: ${_process!.pid})');
  }

  Future<void> stop() async {
    if (_process == null) return;

    _logController.add('Остановка Xray...');
    _process!.kill(ProcessSignal.sigterm);

    try {
      await _process!.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _logController.add('Принудительная остановка...');
      _process!.kill(ProcessSignal.sigkill);
    }

    _process = null;
    _configPath = null;
    _statusController.add(false);
    _logController.add('Xray остановлен');
  }

  Future<void> dispose() async {
    await stop();
    await _logController.close();
    await _statusController.close();
  }
}
