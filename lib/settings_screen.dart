import 'package:flutter/material.dart';

import 'app_state.dart';
import 'profile_store.dart';
import 'settings_store.dart';

/// Настройки клиента: оформление, запуск вместе с системой и профили.
///
/// Набор как у большинства VPN-клиентов, чтобы не пришлось искать привычное.
/// Значения применяются сразу — отдельной кнопки «Сохранить» здесь нет.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({required this.state, super.key});

  final AppState state;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _state.addListener(_onChange);
    // Флаг автозапуска живёт в системе: открываем экран — перечитываем.
    _state.refreshAutostart();
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
          children: [
            const _SectionTitle('Оформление'),
            ...ThemeChoice.values.map(
              (choice) => ListTile(
                leading: Icon(_themeIcon(choice)),
                title: Text(choice.label),
                trailing: _state.themeChoice == choice
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => _state.setTheme(choice),
              ),
            ),
            const _SectionDivider(),
            const _SectionTitle('Запуск'),
            if (_state.autostartSupported)
              SwitchListTile(
                secondary: const Icon(Icons.play_circle_outline),
                title: const Text('Автозапуск с системой'),
                subtitle: const Text('Клиент откроется сам после входа в систему'),
                value: _state.autoStart,
                onChanged: (value) async {
                  await _state.setAutoStart(value);
                  _notify(value
                      ? 'Клиент будет запускаться с системой'
                      : 'Автозапуск выключен');
                },
              ),
            SwitchListTile(
              secondary: const Icon(Icons.bolt),
              title: const Text('Автоподключение при запуске'),
              subtitle: Text(_autoConnectHint()),
              value: _state.autoConnect,
              onChanged: _state.settings.lastProfileId == null &&
                      !_state.autoConnect
                  ? null
                  : (value) => _state.setAutoConnect(value),
            ),
            const _SectionDivider(),
            _SectionTitle('Профили (${_state.profiles.length})'),
            if (_state.profiles.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text('Подключений пока нет — добавьте их на главном экране.'),
              )
            else
              ..._state.profiles.map(_profileTile),
          ],
        ),
      ),
    );
  }

  String _autoConnectHint() {
    final id = _state.settings.lastProfileId;
    if (id == null) return 'Станет доступно после первого успешного подключения';
    final name = _state.profiles
        .map((profile) => profile.id == id ? profile.name : null)
        .firstWhere((name) => name != null, orElse: () => null);
    return name == null
        ? 'Подключение больше не найдено'
        : 'Поднимаем то же подключение: $name';
  }

  Widget _profileTile(StoredProfile profile) {
    final active = _state.activeProfile?.id == profile.id;
    return ListTile(
      leading: Icon(_profileIcon(profile)),
      title: Text(profile.name),
      subtitle: Text(_profileKindLabel(profile)),
      trailing: active
          ? const Icon(Icons.check)
          : PopupMenuButton<String>(
              tooltip: 'Действия',
              onSelected: (action) async {
                if (action == 'rename') await _rename(profile);
                if (action == 'remove') await _remove(profile);
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'rename', child: Text('Переименовать')),
                PopupMenuItem(value: 'remove', child: Text('Удалить')),
              ],
            ),
      onTap: active ? null : () => _state.select(profile.id),
    );
  }

  IconData _themeIcon(ThemeChoice choice) => switch (choice) {
        ThemeChoice.system => Icons.brightness_auto_outlined,
        ThemeChoice.light => Icons.light_mode_outlined,
        ThemeChoice.dark => Icons.dark_mode_outlined,
      };

  IconData _profileIcon(StoredProfile profile) =>
      switch (profile.kind) {
        ProfileKind.links => Icons.key_outlined,
        ProfileKind.subscription => Icons.rss_feed,
        ProfileKind.file => Icons.description_outlined,
      };

  String _profileKindLabel(StoredProfile profile) {
    final provider = _state.providers
        .map((item) => item.id == profile.providerId ? item.name : null)
        .firstWhere((name) => name != null, orElse: () => null);
    return switch (profile.kind) {
      ProfileKind.links => provider ?? 'Ссылки',
      ProfileKind.subscription => provider ?? 'Подписка',
      ProfileKind.file => 'Файл config.json',
    };
  }

  Future<void> _rename(StoredProfile profile) async {
    final controller = TextEditingController(text: profile.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Имя подключения'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await _state.rename(profile.id, name);
  }

  Future<void> _remove(StoredProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Удалить «${profile.name}»?'),
        content: const Text(
          'Подключение и сохранённый кэш подписки будут удалены.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Продолжить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _state.remove(profile.id);
  }

  void _notify(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          color: colors.primary,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _SectionDivider extends StatelessWidget {
  const _SectionDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Divider(height: 1),
    );
  }
}
