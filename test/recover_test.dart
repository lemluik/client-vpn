import 'dart:async';

import 'package:client_vpn/android_core.dart';
import 'package:client_vpn/app_proxy.dart';
import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/settings_store.dart';
import 'package:client_vpn/system_proxy.dart';
import 'package:client_vpn/tun_config.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ядро, которое умеет только отвечать на вопрос о состоянии сервиса.
class RecoveringCore implements VpnCore {
  RecoveringCore(this.statusAfterRecover);

  final bool statusAfterRecover;
  int recoverCalls = 0;

  final StreamController<String> _logs = StreamController<String>.broadcast();
  final StreamController<CoreStatus> _status = StreamController<CoreStatus>.broadcast();

  @override
  Stream<String> get logs => _logs.stream;

  @override
  Stream<CoreStatus> get statusChanges => _status.stream;

  @override
  Future<void> markTunnelFresh() async {}

  @override
  Future<bool> takePendingConnect() async => false;

  @override
  bool get isRunning => statusAfterRecover;

  @override
  String? get endpointLabel => null;

  @override
  Future<void> validate(VpnConfig config) async {}

  @override
  Future<void> start(VpnConfig config) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> recoverAfterCrash() async {
    recoverCalls++;
    _status.add(CoreStatus(statusAfterRecover));
  }
}

Future<AppState> makeState(VpnCore core) async {
  SharedPreferences.setMockInitialValues({});
  return AppState(
    await ProfileStore.open(),
    core,
    settings: await SettingsStore.open(),
    configWriter: (config) async => config,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('восстановление состояния при старте', () {
    test('recover() спрашивает ядро и принимает его статус', () async {
      // Туннель Android переживает закрытие экрана, системный прокси Windows —
      // убийство процесса. Актуальное состояние знает только ядро.
      final core = RecoveringCore(true);
      final state = await makeState(core);
      addTearDown(state.dispose);

      expect(state.state, TunnelState.off);
      await state.recover();

      expect(core.recoverCalls, 1);
      expect(state.state, TunnelState.on);
    });

    test('recover() при снятом туннеле оставляет «Отключено»', () async {
      final core = RecoveringCore(false);
      final state = await makeState(core);
      addTearDown(state.dispose);

      await state.recover();

      expect(core.recoverCalls, 1);
      expect(state.state, TunnelState.off);
    });
  });

  group('исключения системного прокси', () {
    test('<local> добавляется к пустому списку', () {
      expect(SystemProxy.withLocalMarker(null), '<local>');
      expect(SystemProxy.withLocalMarker(''), '<local>');
    });

    test('<local> дописывается к исключениям пользователя', () {
      expect(
        SystemProxy.withLocalMarker('*.corp.local;10.*'),
        '*.corp.local;10.*;<local>',
      );
    });

    test('<local> не дублируется, порядок исключений сохраняется', () {
      expect(
        SystemProxy.withLocalMarker('a.local;<local>;b.local'),
        'a.local;<local>;b.local',
      );
      expect(SystemProxy.withLocalMarker('a.local;<LOCAL>'), 'a.local;<LOCAL>');
    });
  });

  group('килл-свитч', () {
    test('без нашего маркера блокировка ничего не делает', () async {
      // Маркер `proxy.ours` не выставлен: прокси включали не мы, значит и
      // держать его на мёртвом порте нельзя. Кейс обязан завершиться до
      // первой записи в реестр — настройки пользователя не трогаются.
      SharedPreferences.setMockInitialValues({});
      await SystemProxy.lockLeak();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('proxy.ours'), isNull);
    });
  });

  group('Android: запрос статуса сервиса', () {
    const channel = MethodChannel('client_vpn/tunnel');

    /// Мок нативной стороны: отвечает на вызовы, которые делает AndroidCore.
    void mockNative(bool Function(MethodCall call) answer) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => answer(call));
    }

    test('recoverAfterCrash() спрашивает статус и публикует его', () async {
      final calls = <MethodCall>[];
      mockNative((call) {
        calls.add(call);
        return call.method == 'status';
      });
      addTearDown(() => mockNative((_) => false));

      final core = AndroidCore();
      final seen = <CoreStatus>[];
      core.statusChanges.listen(seen.add);
      // Подписка на поток событий выполняется до запроса статуса.
      await Future<void>.delayed(Duration.zero);

      await core.recoverAfterCrash();
      // Событие broadcast-потока доставляется следующим микротаском.
      await Future<void>.delayed(Duration.zero);

      expect(calls.map((call) => call.method), ['status']);
      expect(core.isRunning, isTrue);
      expect(seen.map((s) => s.running).toList(), [true]);
    });

    test('восстановленный туннель возвращает приложению локальный вход', () async {
      // Снятый при закрытии экрана статус значит, что канал жив: точка входа
      // обязана появиться снова, иначе подписка уйдёт напрямую.
      mockNative((call) => call.method == 'status');
      addTearDown(() => mockNative((_) => false));
      addTearDown(() => AppProxy.attach(null));

      await AndroidCore().recoverAfterCrash();

      expect(AppProxy.endpoint, appProxyEndpoint());
      expect(AppProxy.reachesCore, isTrue);
    });

    test('снятый сервис возвращает «Отключено»', () async {
      mockNative((_) => false);
      addTearDown(() => mockNative((_) => false));

      final core = AndroidCore();
      final seen = <CoreStatus>[];
      core.statusChanges.listen(seen.add);
      await Future<void>.delayed(Duration.zero);

      await core.recoverAfterCrash();
      await Future<void>.delayed(Duration.zero);

      expect(core.isRunning, isFalse);
      expect(seen.map((s) => s.running).toList(), [false]);
    });

    test('снятый туннель снимает и локальный вход приложения', () async {
      mockNative((_) => false);
      addTearDown(() => mockNative((_) => false));
      addTearDown(() => AppProxy.attach(null));
      AppProxy.attach((protocol: 'http', port: 10808));

      await AndroidCore().recoverAfterCrash();

      expect(AppProxy.endpoint, isNull);
      expect(AppProxy.reachesCore, isFalse);
    });
  });
}
