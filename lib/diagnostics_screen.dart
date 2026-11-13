import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'diagnostics.dart';

/// Режим «Проверить соединение»: короткий понятный результат и кнопка
/// «Поделиться диагностикой».
///
/// Как и журнал, экран служебный и говорит по-русски напрямую. Отчёт собирается
/// из структурных полей и маскируется: адресов узлов, ключей, токенов, ссылок
/// подписки и персональных данных в нём нет. Автоматическая отправка выключена —
/// файл уходит только по нажатию пользователя.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({required this.state, super.key});

  final AppState state;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _state.addListener(_onChange);
  }

  @override
  void dispose() {
    _state.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final report = _state.diagnostics;
    final running = _state.isDiagnosticsRunning;
    // Выключенный VPN: проверка измеряет путь через туннель, без туннеля
    // получился бы пустой отчёт за 0 мс. Вместо кнопок проверки — понятное
    // предложение подключиться.
    final off = _state.state == TunnelState.off && !running;

    return Scaffold(
      appBar: AppBar(title: const Text('Проверить соединение')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            if (running) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
              const Text('Проверяем соединение…'),
              const SizedBox(height: 16),
            ],
            if (report != null) ...[
              _VerdictCard(report: report),
              const SizedBox(height: 16),
            ],
            if (off) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        Icons.power_settings_new,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'VPN выключен. Проверка измеряет соединение через '
                          'туннель — сначала подключитесь.',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _connectAndCheck,
                icon: const Icon(Icons.power_settings_new),
                label: const Text('Подключить и проверить'),
              ),
            ] else ...[
              FilledButton.icon(
                onPressed: running ? null : _runCurrent,
                icon: const Icon(Icons.network_check),
                label: const Text('Проверить соединение'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: running ? null : _runAllEntries,
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Проверить все входы'),
              ),
            ],
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: (report == null || running) ? null : _share,
              icon: const Icon(Icons.share_outlined),
              label: const Text('Поделиться диагностикой'),
            ),
            const SizedBox(height: 8),
            if (!off)
              Text(
                'Проверка всех входов по очереди переключает туннель — соединение '
                'кратко прервётся. Исходный вход вернётся автоматически.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (!off) const SizedBox(height: 4),
            Text(
              'В отчёте нет адресов узлов, ключей и ссылок подписки. '
              'Автоматическая отправка выключена.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (report != null) ...[
              const SizedBox(height: 16),
              _Details(report: report),
            ],
          ],
        ),
      ),
    );
  }

  /// Предложение при выключенном VPN: одно нажатие поднимает туннель и сразу
  /// запускает проверку — пользователю не нужно помнить порядок действий.
  Future<void> _connectAndCheck() async {
    await _state.connect();
    await _state.runDiagnostics();
  }

  Future<void> _runCurrent() => _state.runDiagnostics();

  /// Активный тест переключения — только по нажатию и с предупреждением о кратком
  /// перерыве: смена входа рвёт установленные соединения.
  Future<void> _runAllEntries() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Проверить все входы'),
        content: const Text(
          'Клиент по очереди переключит вход и проверит каждый через реальный '
          'туннель. Соединение кратко прервётся на время переключения. '
          'Исходный вход вернётся автоматически.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Проверить'),
          ),
        ],
      ),
    );
    if (go != true) return;
    await _state.runDiagnostics(switchEntries: true);
  }

  /// Сохранение отчёта в файл — тот же путь, что у журнала: без автоматической
  /// отправки, файл уходит только по нажатию пользователя.
  Future<void> _share() async {
    final report = _state.diagnostics;
    if (report == null) return;
    final bytes = Uint8List.fromList(utf8.encode(report.toShareText()));
    final name = 'diagnostika-${_stamp()}.txt';

    String? message;
    try {
      final target = await FilePicker.saveFile(
        fileName: name,
        bytes: bytes,
        mimeType: 'text/plain',
        dialogTitle: 'Сохранить диагностику',
        allowedExtensions: ['txt'],
      );
      if (target == null) return;
      if (Platform.isAndroid) {
        // Плагин сам записывает байты через SAF и возвращает путь документа
        // (content://), который dart:io File открыть не может. Файл уже лежит
        // в выбранной пользователем папку — повторно не пишем, иначе получили
        // бы ложную ошибку при успешно сохранённом отчёте.
        message = 'Отчёт сохранён: $name. Отправьте файл через мессенджер или почту.';
      } else {
        final file = File.fromUri(target);
        if (!await file.exists() || await file.length() == 0) {
          await file.writeAsBytes(bytes);
        }
        message = 'Сохранено: ${file.path}';
      }
    } catch (error) {
      message = 'Сохранить не удалось: $error';
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _stamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}';
  }
}

/// Короткий понятный результат: цвет и значок по итогу проверки.
class _VerdictCard extends StatelessWidget {
  const _VerdictCard({required this.report});

  final DiagnosticsReport report;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (icon, color, container) = switch (report.verdict) {
      DiagVerdict.works => (
        Icons.verified_user_outlined,
        Colors.green.shade700,
        colors.secondaryContainer,
      ),
      DiagVerdict.failureConfirmed => (
        Icons.cloud_off,
        colors.onErrorContainer,
        colors.errorContainer,
      ),
      DiagVerdict.unknown => (
        Icons.help_outline,
        colors.onSurfaceVariant,
        colors.surfaceContainerHighest,
      ),
    };

    return Card(
      color: container,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                report.summary(),
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Подробности отчёта: этапы и входы. Только структурные поля — без адресов и
/// ключей; контрольные адреса названы метками, входы — именем региона.
class _Details extends StatelessWidget {
  const _Details({required this.report});

  final DiagnosticsReport report;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Подробности', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Text(
          'Приложение ${report.facts.appVersion} · ядро ${report.facts.coreVersion}',
          style: style,
        ),
        Text(
          '${report.facts.platform} ${report.facts.osVersion} · сеть ${report.facts.networkType}',
          style: style,
        ),
        const SizedBox(height: 8),
        for (final stage in report.stages)
          Text(
            '${stageName(stage.stage)}: ${stage.ok ? 'ок' : 'отказ'} — ${stage.detail}',
            style: style,
          ),
        for (final entry in report.entries) ...[
          const SizedBox(height: 4),
          Text(
            'Настроенный вход «${entry.entry.label}»: ${verdictName(entry.verdict)}',
            style: style,
          ),
          Text(
            '  фактический маршрут: ${entry.actualRoute ?? 'не установлен'}',
            style: style,
          ),
          for (final control in entry.controls.entries)
            Text(
              '  контрольный адрес ${control.key}: ${control.value ?? 'нет ответа'}',
              style: style,
            ),
          if (entry.recovery != null)
            Text(
              '  восстановление: ${entry.recovery!.inMilliseconds} мс',
              style: style,
            ),
          if (entry.note.isNotEmpty) Text('  ${entry.note}', style: style),
        ],
      ],
    );
  }
}