import 'package:flutter/material.dart';

import 'app_state.dart';
import 'per_app_rules.dart';

/// Приложения, которые идут мимо туннеля (R2.3).
///
/// Экран есть только на Android: там исключение применяет `VpnService`, у
/// ядра Xray условия по имени пакета нет (замер 16.10.2026). Выбранный список
/// клиент передаёт системе при подключении, поэтому изменение требует
/// переподключения — экран об этом говорит.
class DirectAppsScreen extends StatefulWidget {
  const DirectAppsScreen({required this.state, super.key});

  final AppState state;

  @override
  State<DirectAppsScreen> createState() => _DirectAppsScreenState();
}

class _DirectAppsScreenState extends State<DirectAppsScreen> {
  static const _channel = PerAppChannel();

  late List<String> _chosen = List.of(widget.state.directApps);

  List<InstalledApp> _apps = const [];
  String _query = '';
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final apps = await _channel.list();
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Список приложений недоступен: $error';
        _loading = false;
      });
    }
  }

  Future<void> _toggle(String package, bool value) async {
    final next = {
      ..._chosen.where((item) => item != package),
      if (value) package,
    }.toList()..sort();
    setState(() => _chosen = next);
    await widget.state.setDirectApps(next);
  }

  @override
  Widget build(BuildContext context) {
    final needle = _query.trim().toLowerCase();
    final shown = _apps
        .where(
          (app) =>
              needle.isEmpty ||
              app.name.toLowerCase().contains(needle) ||
              app.package.toLowerCase().contains(needle),
        )
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Приложения напрямую')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Поиск по названию или пакету',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _chosen.isEmpty
                  ? 'Ни одно приложение не выведено из туннеля.'
                  : 'Без туннеля: ${_chosen.length}. '
                        'Применится после переподключения.',
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator())),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.orange),
              ),
            ),
          if (!_loading && _error == null && shown.isEmpty)
            const Expanded(
              child: Center(
                child: Text(
                  'Ничего не найдено',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ),
          if (!_loading && _error == null)
            Expanded(
              child: ListView(
                children: [
                  for (final app in shown)
                    CheckboxListTile(
                      value: _chosen.contains(app.package),
                      title: Text(app.name),
                      subtitle: Text(
                        app.package,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      onChanged: (value) =>
                          _toggle(app.package, value ?? false),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
