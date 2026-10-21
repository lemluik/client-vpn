import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'about_screen.dart';
import 'app_state.dart';
import 'failover.dart';
import 'l10n/app_localizations.dart';
import 'profile_store.dart';
import 'routing_presets.dart';
import 'routing_restart.dart';
import 'rules_screen.dart';
import 'settings_store.dart';
import 'split_screen.dart';
import 'update_screen.dart';
import 'update_service.dart';

/// Настройки клиента: профили, оформление, запуск, маршрут и обслуживание.
///
/// Единственная точка входа к этим пунктам — шестерёнка на главном экране:
/// второго списка тех же настроек на первом экране нет, и показывать разные
/// значения одного и того же выбора в двух местах невозможно.
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
            _SectionTitle(l.settingsProfilesSection(_state.profiles.length)),
            if (_state.profiles.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(l.settingsProfilesEmpty),
              )
            else
              ..._state.profiles.map((profile) => _profileTile(l, profile)),
            const _SectionDivider(),
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
            // Трей есть на Windows и в строке меню macOS: на остальном
            // десктопе прятать окно некуда, и настраивать нечего.
            if (Platform.isWindows || Platform.isMacOS) ...[
              const _SectionDivider(),
              _SectionTitle(l.closeWindowSection),
              ...CloseAction.values.map((action) => _closeTile(l, action)),
            ],
            const _SectionDivider(),
            _SectionTitle(l.settingsRoutingSection),
            if (_state.homeRegionKnown)
              _homeRegionTile(l)
            else
              ..._presetTiles(l),
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
            ListTile(
              key: const ValueKey('my-rules'),
              leading: const Icon(Icons.rule_outlined),
              title: Text(l.myRules),
              subtitle: Text(
                _state.manualRules.isEmpty
                    ? l.myRulesEmpty
                    : l.myRulesCount(_state.manualRules.length),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => RulesScreen(state: _state)),
              ),
            ),
            const _SectionDivider(),
            _SectionTitle(l.settingsServiceSection),
            ListTile(
              key: const ValueKey('probe-target'),
              leading: const Icon(Icons.network_check),
              title: Text(l.probeTarget),
              subtitle: Text(_state.probeEndpoint),
              trailing: const Icon(Icons.chevron_right),
              onTap: _editProbeTarget,
            ),
            if (Platform.isAndroid || Platform.isWindows) ...[
              _SectionTitle(l.settingsUpdateSection),
              _AutoUpdateSwitch(),
            ],
            ListTile(
              key: const ValueKey('update-source'),
              leading: const Icon(Icons.system_update_alt),
              title: Text(l.updateTitle),
              subtitle: Text(l.updateSourceSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const UpdateScreen())),
            ),
            if (defaultTargetPlatform == TargetPlatform.android)
              ListTile(
                key: const ValueKey('tile'),
                leading: const Icon(Icons.dashboard_outlined),
                title: Text(l.tileTitle),
                subtitle: Text(l.tileSubtitle),
                onTap: _addTile,
              ),
            ListTile(
              key: const ValueKey('about'),
              leading: const Icon(Icons.info_outline),
              title: Text(l.aboutTitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const AboutScreen())),
            ),
          ],
        ),
      ),
    );
  }

  /// Переключатель «сайты домашнего региона напрямую».
  ///
  /// Это и есть выбор маршрутного пресета: значение живёт в `routing.preset.v1`
  /// и у переключателя, и у списка-замены ниже. Два видимых контролла над одним
  /// значением расходились бы, и экран показывал бы не тот маршрут, который
  /// реально ушёл в ядро, — поэтому показывается ровно один.
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

  /// Выбор пресета списком — замена переключателя, когда домашний регион не
  /// определён и включателю нечего предлагать.
  List<Widget> _presetTiles(AppLocalizations l) => [
    for (final preset in routingPresets)
      ListTile(
        key: ValueKey('preset-${preset.key}'),
        leading: Icon(preset.isOff ? Icons.block : Icons.alt_route),
        title: Text(_presetLabel(l, preset)),
        subtitle: Text(preset.isOff ? l.presetOffSubtitle : l.presetOnSubtitle),
        trailing: Icon(
          preset.key == _state.routingPreset.key
              ? Icons.radio_button_checked
              : Icons.radio_button_off,
        ),
        // Выбранный ряд неактивен: повторный выбор того же маршрута всё равно
        // перервал бы соединения, ничего не меняя.
        onTap: preset.key == _state.routingPreset.key
            ? null
            : () => applyRoutingChange(
                context,
                _state,
                l,
                change: () => _state.setRoutingPreset(preset.key),
                savedNote: l.presetSelected(_presetLabel(l, preset)),
                appliedNote: l.presetApplied(_presetLabel(l, preset)),
              ),
      ),
  ];

  /// Название пресета на языке интерфейса. Модель список не переводит:
  /// она работает до первого кадра, а язык известен только в виджете.
  String _presetLabel(AppLocalizations l, RoutingPreset preset) =>
      switch (preset.key) {
        'ru' => l.presetRu,
        'none' => l.presetOff,
        _ => preset.label,
      };

  /// Точка проб наблюдателя (У-3): значение вводит пользователь, нейтральное
  /// по умолчанию ничего о провайдере не сообщает.
  Future<void> _editProbeTarget() async {
    final l = AppLocalizations.of(context);
    final controller = TextEditingController(text: _state.probeEndpoint);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.probeTarget),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.probeTargetSubtitle),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: defaultProbeEndpoint,
                border: OutlineInputBorder(),
              ),
            ),
          ],
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
    if (value == null) return;

    final error = await _state.setProbeEndpoint(value);
    if (error != null) {
      _notify(error);
      return;
    }
    if (!_state.isConnected) {
      _notify(l.probeApplied);
      return;
    }

    // Значение уже сохранено; переподключение только применяет его к каналу.
    if (await _confirm(l.restartForPresetTitle, l.restartForProbeBody)) {
      await _state.disconnect();
      await _state.connect();
    }
    _notify(l.probeApplied);
  }

  Future<bool> _confirm(String title, String text) async {
    final l = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(text),
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
    return result ?? false;
  }

  /// Ряд выбора поведения крестика. Нужен, чтобы запомненный в запросе выбор
  /// можно было передумать: без этой настройки «запомнить» превратилось бы в
  /// ловушку до очистки данных приложения.
  Widget _closeTile(AppLocalizations l, CloseAction action) {
    final selected = _state.closeAction == action;
    return ListTile(
      key: ValueKey('close-choice-${action.name}'),
      leading: Icon(_closeIcon(action)),
      title: Text(_closeLabel(l, action)),
      // Отметка своя, а не общая галочка: по галочке на этом экране ищут
      // выбранную тему и активный профиль.
      trailing: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
      ),
      onTap: () => _state.setCloseAction(action),
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

  IconData _closeIcon(CloseAction action) => switch (action) {
    CloseAction.ask => Icons.help_outline,
    CloseAction.tray => Icons.minimize,
    CloseAction.quit => Icons.power_settings_new,
  };

  String _closeLabel(AppLocalizations l, CloseAction action) =>
      switch (action) {
        CloseAction.ask => l.closeWindowChoiceAsk,
        CloseAction.tray => l.closeWindowChoiceTray,
        CloseAction.quit => l.closeWindowChoiceQuit,
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

  /// Системный запрос добавления плитки. На старых Android система запрос
  /// не принимает — там показываем текстовую инструкцию.
  Future<void> _addTile() async {
    bool added;
    try {
      added =
          await const MethodChannel(
            'client_vpn/tunnel',
          ).invokeMethod<bool>('addTile') ==
          true;
    } on Exception {
      added = false;
    }
    if (!added && mounted) _notify(AppLocalizations.of(context).tileFallback);
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

class _AutoUpdateSwitch extends StatefulWidget {
  @override
  State<_AutoUpdateSwitch> createState() => _AutoUpdateSwitchState();
}

class _AutoUpdateSwitchState extends State<_AutoUpdateSwitch> {
  bool _enabled = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = UpdateService.instance;
    final enabled = await service.isAutoCheckEnabled();
    if (mounted) {
      setState(() {
        _enabled = enabled;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    if (_loading) {
      return const ListTile(
        leading: CircularProgressIndicator(),
        title: Text('Loading...'),
      );
    }

    return SwitchListTile(
      secondary: const Icon(Icons.system_update_alt),
      title: Text(l.settingsAutoUpdate),
      subtitle: Text(l.settingsAutoUpdateSubtitle),
      value: _enabled,
      onChanged: (value) async {
        final service = UpdateService.instance;
        await service.setAutoCheckEnabled(value);
        setState(() => _enabled = value);
      },
    );
  }
}
