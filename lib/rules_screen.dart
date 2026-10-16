import 'dart:io';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'direct_apps_screen.dart';
import 'manual_rules.dart';
import 'profile_config.dart';
import 'profile_store.dart';

/// Правила маршрутизации, которые составил пользователь.
///
/// Порядок для ядра: сначала пресет страны, затем правила этого экрана сверху
/// вниз, затем завершающее «всё через подключение». Ядро берёт первое
/// совпадение, поэтому правило выше списка сильнее.
///
/// Профиль, загруженный файлом `config.json`, клиент не переписывает: в нём
/// свои правила, и экран это честно показывает.
class RulesScreen extends StatelessWidget {
  const RulesScreen({required this.state, super.key});

  final AppState state;

  static const String note =
      'Правила клиента не действуют на подключение, загруженное файлом '
      'config.json: там свои правила маршрутизации.';

  @override
  Widget build(BuildContext context) {
    // Экран слушает состояние: список правил обязан перерисоваться сразу после
    // сохранения, а не только при следующем открытии.
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => _page(context),
    );
  }

  Widget _page(BuildContext context) {
    final rules = state.manualRules;
    final fileProfile = state.activeProfile?.kind == ProfileKind.file;

    return Scaffold(
      appBar: AppBar(title: const Text('Мои правила')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add-rule',
        onPressed: () => _edit(context, null),
        icon: const Icon(Icons.add),
        label: const Text('Новое правило'),
      ),
      body: ListView(
        children: [
          if (Platform.isAndroid)
            ListTile(
              leading: const Icon(Icons.phone_android),
              title: const Text('Приложения напрямую'),
              subtitle: Text(
                state.directApps.isEmpty
                    ? 'Все приложения идут через туннель'
                    : 'Без туннеля: ${state.directApps.length}',
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DirectAppsScreen(state: state),
                ),
              ),
            ),
          if (Platform.isAndroid) const Divider(),
          if (rules.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 32, 24, 16),
              child: Text(
                'Правил пока нет. Правило говорит ядру: трафик, который '
                'подходит под условия, идёт напрямую или через подключение.',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          if (fileProfile)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Text(note, style: TextStyle(color: Colors.orange)),
            ),
          for (final (index, rule) in rules.indexed)
            _RuleTile(
              rule: rule,
              // Правило можно перенести выше или ниже: порядок и есть
              // приоритет.
              canMoveUp: index > 0,
              canMoveDown: index < rules.length - 1,
              onChanged: (next) => _replace(context, rules, index, next),
              onMoved: (delta) => _move(context, rules, index, delta),
              onDeleted: () => _delete(context, rules, rule),
              onEdit: () => _edit(context, rule),
            ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, ManualRule? rule) async {
    final saved = await Navigator.of(context).push<ManualRule>(
      MaterialPageRoute(builder: (_) => RuleEditorScreen(existing: rule)),
    );
    if (saved == null || !context.mounted) return;
    final rules = List.of(state.manualRules);
    final index = rules.indexWhere((item) => item.id == saved.id);
    if (index >= 0) {
      rules[index] = saved;
    } else {
      rules.add(saved);
    }
    await _apply(context, rules);
  }

  void _replace(
    BuildContext context,
    List<ManualRule> rules,
    int index,
    ManualRule next,
  ) {
    final updated = List.of(rules)..[index] = next;
    _apply(context, updated);
  }

  void _move(
    BuildContext context,
    List<ManualRule> rules,
    int index,
    int delta,
  ) {
    final target = index + delta;
    if (target < 0 || target >= rules.length) return;
    final updated = List.of(rules);
    final moved = updated.removeAt(index);
    updated.insert(target, moved);
    _apply(context, updated);
  }

  Future<void> _delete(
    BuildContext context,
    List<ManualRule> rules,
    ManualRule rule,
  ) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Удалить «${rule.title}»?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (sure != true || !context.mounted) return;
    await _apply(context, [
      for (final item in rules)
        if (item.id != rule.id) item,
    ]);
  }

  Future<void> _apply(BuildContext context, List<ManualRule> rules) async {
    final wasConnected = state.isConnected;
    await state.setManualRules(rules);
    if (!wasConnected || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Правила применятся после переподключения')),
    );
  }
}

/// Строка списка: название, условия, направление, выключатель и порядок.
class _RuleTile extends StatelessWidget {
  const _RuleTile({
    required this.rule,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onChanged,
    required this.onMoved,
    required this.onDeleted,
    required this.onEdit,
  });

  final ManualRule rule;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<ManualRule> onChanged;
  final ValueChanged<int> onMoved;
  final VoidCallback onDeleted;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final error = rule.validate();

    return ListTile(
      onTap: onEdit,
      title: Text(rule.title.isEmpty ? 'Без названия' : rule.title),
      subtitle: Text(
        error != null
            ? _validationText(error)
            : '${rule.directionLabel}\n${rule.summary}',
        style: TextStyle(
          color: error != null ? Colors.orange : null,
          fontSize: 13,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: canMoveUp ? () => onMoved(-1) : null,
            icon: const Icon(Icons.arrow_upward),
            tooltip: 'Выше',
          ),
          IconButton(
            onPressed: canMoveDown ? () => onMoved(1) : null,
            icon: const Icon(Icons.arrow_downward),
            tooltip: 'Ниже',
          ),
          IconButton(
            onPressed: onDeleted,
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Удалить',
          ),
          Switch(
            value: rule.enabled,
            onChanged: (value) => onChanged(
              ManualRule(
                id: rule.id,
                title: rule.title,
                outbound: rule.outbound,
                conditions: rule.conditions,
                enabled: value,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Форма одного правила.
///
/// Показаны только те условия, которые принимает ядро (замер 16.10.2026 на
/// Xray-core 26.3.27): поля sing-box — имена приложений и процессов,
/// внешние наборы правил — здесь не предлагались бы: ядро их отвергает.
class RuleEditorScreen extends StatefulWidget {
  const RuleEditorScreen({this.existing, super.key});

  final ManualRule? existing;

  @override
  State<RuleEditorScreen> createState() => _RuleEditorScreenState();
}

class _RuleEditorScreenState extends State<RuleEditorScreen> {
  late final TextEditingController _title = TextEditingController(
    text: widget.existing?.title ?? '',
  );

  late final Map<RuleField, TextEditingController> _fields = {
    for (final field in RuleField.values)
      field: TextEditingController(
        text: widget.existing == null
            ? ''
            : (widget.existing!.conditions[field] ?? const []).join(
                field.single ? '' : '\n',
              ),
      ),
  };

  late String _outbound = widget.existing?.outbound ?? directTag;

  String? _error;

  @override
  void dispose() {
    _title.dispose();
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Map<RuleField, List<String>> _conditions() {
    final conditions = <RuleField, List<String>>{};
    for (final entry in _fields.entries) {
      final text = entry.value.text.trim();
      if (text.isEmpty) continue;
      conditions[entry.key] = entry.key.single
          ? [text]
          : [
              for (final part in text.split(RegExp(r'[\n,]')))
                if (part.trim().isNotEmpty) part.trim(),
            ];
    }
    return conditions;
  }

  void _save() {
    final rule = ManualRule(
      id: widget.existing?.id ?? ManualRule.newId(),
      title: _title.text.trim(),
      outbound: _outbound,
      conditions: _conditions(),
      enabled: widget.existing?.enabled ?? true,
    );
    final error = rule.validate();
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(rule);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Новое правило' : 'Правило'),
        actions: [
          TextButton(
            key: const ValueKey('rule-save'),
            onPressed: _save,
            child: const Text('Сохранить'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _validationText(_error!),
                style: const TextStyle(color: Colors.orange),
              ),
            ),
          TextField(
            key: const ValueKey('rule-title'),
            controller: _title,
            decoration: const InputDecoration(
              labelText: 'Название',
              hintText: 'Например: банк напрямую',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          RadioGroup<String>(
            groupValue: _outbound,
            onChanged: (value) =>
                setState(() => _outbound = value ?? _outbound),
            child: const Column(
              children: [
                RadioListTile<String>(
                  value: directTag,
                  title: Text('идёт напрямую'),
                ),
                RadioListTile<String>(
                  value: proxyTag,
                  title: Text('идёт через подключение'),
                ),
              ],
            ),
          ),
          const Divider(height: 32),
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Условия. Достаточно любого одного; правило срабатывает на '
              'совпадение. Значения — по строке, geo-коды из баз ядра: '
              'geosite:…, geoip:…',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ),
          for (final field in RuleField.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                key: ValueKey('rule-field-${field.key}'),
                controller: _fields[field],
                minLines: field.single ? 1 : null,
                maxLines: field.single ? 1 : 3,
                decoration: InputDecoration(
                  labelText: field.title,
                  hintText: field.hint,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Текст ошибки вразумительно для пользователя.
String _validationText(String code) => switch (code) {
  'ruleTitleRequired' => 'Правилу нужно название',
  'ruleNeedsCondition' =>
    'Ядро не принимает правило без условия: заполните хотя бы одно поле',
  'ruleEmptyValue' => 'В списке значений есть пустая строка',
  'ruleBadPort' => 'Порт — число от 1 до 65535 или диапазон вида 8000-9000',
  _ => 'Правило составлено неверно',
};
