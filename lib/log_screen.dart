import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'log_mask.dart';

/// Журнал ядра на отдельном экране.
///
/// В клиенте открытый исходный код, и журнал прикладывают к публичным
/// обращениям, поэтому сохраняется он только маскированным: без адресов узлов,
/// идентификаторов и ключей пользователя.
class LogScreen extends StatefulWidget {
  const LogScreen({required this.state, super.key});

  final AppState state;

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final ScrollController _scroll = ScrollController();

  bool _masked = true;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onChange);
    _scroll.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.state.log;
    final shown = _masked ? lines.map(maskSecrets).toList() : lines;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Журнал'),
        actions: [
          IconButton(
            tooltip: _masked ? 'Показать как есть' : 'Скрыть адреса и ключи',
            icon: Icon(_masked ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _masked = !_masked),
          ),
          IconButton(
            tooltip: 'Сохранить маскированным',
            icon: const Icon(Icons.save_alt),
            onPressed: lines.isEmpty ? null : _export,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'В сохранённом файле адреса и ключи заменены на [адрес] и [ключ].',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: shown.isEmpty
                ? const Center(child: Text('Пусто'))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(8),
                    itemCount: shown.length,
                    itemBuilder: (context, index) {
                      final line = shown[index];
                      final isError = line.startsWith('[ERR]');
                      return Text(
                        line,
                        style: TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 12,
                          color: isError ? Colors.red.shade700 : null,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _export() async {
    final text = widget.state.exportLog();
    final bytes = Uint8List.fromList(utf8.encode(text));
    final name = 'journal-${_stamp()}.txt';

    String? message;
    try {
      final target = await FilePicker.saveFile(
        fileName: name,
        bytes: bytes,
        mimeType: 'text/plain',
        dialogTitle: 'Сохранить журнал',
        allowedExtensions: ['txt'],
      );
      if (target == null) return;

      // Не все платформы записывают файл сами — дописываем, если он пуст.
      final file = File.fromUri(target);
      if (!await file.exists() || await file.length() == 0) {
        await file.writeAsBytes(bytes);
      }
      message = 'Сохранено: ${file.path}';
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
