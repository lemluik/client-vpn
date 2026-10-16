import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'l10n/app_localizations.dart';
import 'profile_store.dart';
import 'routing_restart.dart';
import 'settings_store.dart';
import 'split_screen.dart';

/// Настройки клиента: оформление, запуск вместе с системой, маршрут и профили.
///
/// Набор как у большинства VPN-клиентов, чтобы не пришлось искать привычное.
/// Значения применяются сразу — отдельной кнопки «Сохранить» здесь нет, кроме
/// смены маршрута: она поднимает туннель заново и спрашивает разрешение.
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
    final l = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsScreenTitle), centerTitle: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
          children: [
            _SectionTitle(l.settingsThemeSection),
            ...ThemeChoice.values.map(
              (choice) => ListTile(
                leading: Icon(_themeIcon(choice)),
                title: Text(_themeLabel(l, choice)),
                trailing: _state.themeChoice == choice
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => _state.setTheme(choice),
              ),
            ),
            const _SectionDivider(),
            _SectionTitle(l.settingsLaunchSection),
            if (_state.autostartSupported)
              SwitchListTile(
                secondary: const Icon(Icons.play_circle_outline),
                title: Text(l.settingsAutoStart),
                subtitle: Text(
                  defaultTargetPlatform == TargetPlatform.android
                      ? l.settingsAutoStartAndroid
                      : l.settingsAutoStartDesktop,
                ),
                value: _state.autoStart,
                onChanged: (value) async {
                  await _state.setAutoStart(value);
                  _notify(
                    value ? l.settingsAutoStartOn : l.settingsAutoStartOff,
                  );
                },
              ),
            SwitchListTile(
              secondary: const Icon(Icons.bolt),
              title: Text(l.settingsAutoConnect),
              subtitle: Text(_autoConnectHint(l)),
              value: _state.autoConnect,
              onChanged:
                  _state.settings.lastProfileId == null && !_state.autoConnect
                  ? null
                  : (value) => _state.setAutoConnect(value),
            ),
            const _SectionDivider(),
            _SectionTitle(l.settingsRoutingSection),
            _homeRegionTile(l),
            ListTile(
              leading: const Icon(Icons.list_alt),
              title: Text(l.splitExceptions),
              subtitle: Text(
                _state.splitDirectHosts.isEmpty &&
                        _state.splitTunnelHosts.isEmpty
                    ? l.splitExceptionsEmpty
                    : l.splitExceptionsCount(
                        _state.splitDirectHosts.length,
                        _state.splitTunnelHosts.length,
                      ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => SplitScreen(state: _state)),
              ),
            ),
            const _SectionDivider(),
            _SectionTitle(l.settingsProfilesSection(_state.profiles.length)),
            if (_state.profiles.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(l.settingsProfilesEmpty),
              )
            else
              ..._state.profiles.map((profile) => _profileTile(l, profile)),
          ],
        ),
      ),
    );
  }

  /// Переключатель «сайты домашнего региона напрямую».
  ///
  /// Управляет тем же выбранным пресетом, что и лист «Дополнительно»: два
  /// хранимых значения разошлись бы, и экран показывал бы не тот маршрут,
  /// который реально ушёл в ядро.
  Widget _homeRegionTile(AppLocalizations l) {
    final known = _state.homeRegionKnown;

    return SwitchListTile(
      key: const ValueKey('home-region-direct'),
      secondary: const Icon(Icons.public),
      title: Text(l.splitHomeDirect),
      subtitle: Text(
        known
            ? l.splitHomeDirectZones(_state.homePreset.homeDomainsLabel)
            : l.splitHomeDirectUnknown,
      ),
      value: known && _state.homeRegionDirect,
      onChanged: known
          ? (value) => applyRoutingChange(
              context,
              _state,
              l,
              change: () => _state.setHomeRegionDirect(value),
              savedNote: l.splitSaved,
              appliedNote: l.splitApplied,
            )
          : null,
    );
  }

  String _autoConnectHint(AppLocalizations l) {
    final id = _state.settings.lastProfileId;
    if (id == null) return l.settingsAutoConnectPending;
    final name = _state.profiles
        .map((profile) => profile.id == id ? profile.name : null)
        .firstWhere((name) => name != null, orElse: () => null);
    return name == null
        ? l.settingsAutoConnectMissing
        : l.settingsAutoConnectProfile(name);
  }

  Widget _profileTile(AppLocalizations l, StoredProfile profile) {
    final active = _state.activeProfile?.id == profile.id;
    return ListTile(
      leading: Icon(_profileIcon(profile)),
      title: Text(profile.name),
      subtitle: Text(_profileKindLabel(l, profile)),
      trailing: active
          ? const Icon(Icons.check)
          : PopupMenuButton<String>(
              tooltip: l.tooltipActions,
              onSelected: (action) async {
                if (action == 'rename') await _rename(l, profile);
                if (action == 'remove') await _remove(l, profile);
              },
              itemBuilder: (context) => [
                PopupMenuItem(value: 'rename', child: Text(l.menuRename)),
                PopupMenuItem(value: 'remove', child: Text(l.menuDelete)),
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

  String _themeLabel(AppLocalizations l, ThemeChoice choice) =>
      switch (choice) {
        ThemeChoice.system => l.themeSystem,
        ThemeChoice.light => l.themeLight,
        ThemeChoice.dark => l.themeDark,
      };

  IconData _profileIcon(StoredProfile profile) => switch (profile.kind) {
    ProfileKind.links => Icons.key_outlined,
    ProfileKind.subscription => Icons.rss_feed,
    ProfileKind.file => Icons.description_outlined,
  };

  String _profileKindLabel(AppLocalizations l, StoredProfile profile) {
    final provider = _state.providers
        .map((item) => item.id == profile.providerId ? item.name : null)
        .firstWhere((name) => name != null, orElse: () => null);
    return switch (profile.kind) {
      ProfileKind.links => provider ?? l.profileKindLinks,
      ProfileKind.subscription => provider ?? l.profileKindSubscription,
      ProfileKind.file => l.profileKindFile,
    };
  }

  Future<void> _rename(AppLocalizations l, StoredProfile profile) async {
    final controller = TextEditingController(text: profile.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.renameTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.buttonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(l.buttonSave),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await _state.rename(profile.id, name);
  }

  Future<void> _remove(AppLocalizations l, StoredProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.removeProfileTitle(profile.name)),
        content: Text(l.removeProfileBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.buttonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.buttonContinue),
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
