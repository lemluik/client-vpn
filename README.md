<p align="center">
  <h1 align="center">КлиентВПН</h1>
  <p align="center">
    Open-source VPN-клиент на базе Xray-core (VLESS+Reality) для Windows и Android
  </p>
  <p align="center">
    <a href="LICENSE">
      <img src="https://img.shields.io/badge/license-MPL--2.0-blue.svg" alt="License: MPL-2.0">
    </a>
    <a href="https://github.com/lemluik/client-vpn/releases">
      <img src="https://img.shields.io/github/v/release/lemluik/client-vpn" alt="Release">
    </a>
    <img src="https://img.shields.io/badge/platform-Windows%2010%2F11%20%C2%B7%20Android%20arm64-blue" alt="Platform: Windows and Android">
    <img src="https://img.shields.io/badge/xray-26.3.27-green" alt="Xray: 26.3.27">
    <a href="https://github.com/XTLS/Xray-core">
      <img src="https://img.shields.io/badge/powered%20by-Xray--core%20(MPL--2.0)-orange" alt="Powered by Xray-core">
    </a>
  </p>
</p>

---

## О проекте

КлиентВПН — минималистичный VPN-клиент, который управляет Xray-core как подпроцессом. Поддерживает VLESS+Reality, работает на Windows (системный прокси) и на Android (туннель VpnService), делает автоматический откат при сбое.

**Архитектура:** Flutter UI → общий слой `VpnCore` → ядро Xray-core как подпроцесс → VLESS+Reality → сервер → интернет. На десктопе ядро поднимает локальный прокси, и клиент переключает на него системные настройки через реестр Windows; на Android клиент передаёт ядру файловый дескриптор туннеля VpnService и работает без FFI и без Go-обёртки.

## Скриншоты

> [!NOTE]
> Скриншоты будут добавлены после первого тестирования

<!-- Замените на реальные скриншоты:
<p align="center">
  <img src="docs/screenshots/main-disconnected.png" width="400" alt="Disconnected state">
  <img src="docs/screenshots/main-connected.png" width="400" alt="Connected state">
</p>
-->

## Возможности

- ✅ Импорт конфигурации Xray-core (config.json)
- ✅ Подключение через VLESS+Reality
- ✅ Windows: системный прокси (inbound `http` или `socks` на localhost)
- ✅ Android: туннель VpnService (TUN) — весь трафик уходит на сервер
- ✅ Ядро Xray-core 26.3.27 собрано внутри APK, скачивать его отдельно не нужно
- ✅ Валидация конфига перед подключением (`xray -test`)
- ✅ Проверка SHA-256 у `xray.exe` перед каждым запуском — подменённый бинарник не запускается
- ✅ Сохранение и восстановление ваших прежних настроек системного прокси
- ✅ Откат прокси при остановке Xray, закрытии окна и после сбоя
- ✅ Лог работы в реальном времени

### Ограничения текущей версии

- ⚠️ iOS / macOS / Linux — в планах R3
- ⚠️ Windows: только system proxy (без TUN) — часть трафика может идти мимо
- ⚠️ Android: только arm64-v8a (официальный релиз Xray-core для Android не содержит других бинарников)
- ⚠️ Android: APK подписан отладочным ключом — обновление поверх релиза другим ключом потребует переустановки
- ⚠️ Один профиль (один config.json)
- ⚠️ Нет автообновления

## Установка

### Из релиза (рекомендуется)

**Windows**

1. Скачайте `ClientVPN-v0.1.0-Windows-x64.zip` из [Releases](https://github.com/lemluik/client-vpn/releases)
2. Распакуйте в любую папку
3. Запустите `client_vpn.exe`

> [!TIP]
> Если антивирус блокирует `xray.exe` — добавьте папку с приложением в исключения.

**Android**

1. Скачайте `ClientVPN-v0.2.0-Android-arm64-v8a.apk` из [Releases](https://github.com/lemluik/client-vpn/releases)
2. Установите файл (Android запросит разрешение на установку из неизвестных источников)
3. Откройте приложение и выберите config.json — ядро уже внутри APK

> [!NOTE]
> При первом подключении система запросит разрешение на создание VPN-туннеля.

## Использование

1. Нажмите **«Выбрать config.json»** и выберите файл конфигурации Xray
2. Дождитесь зелёной галочки ✓ (валидация пройдена)
3. Нажмите **«ПОДКЛЮЧИТЬ»**
4. Проверьте подключение: откройте https://ifconfig.co — должен показаться IP вашего сервера

Для отключения нажмите **«ОТКЛЮЧИТЬ»**.

## Сборка из исходников

### Требования

- [Flutter SDK](https://docs.flutter.dev/get-started/install/windows) (stable, ≥3.6.0)
- [Visual Studio 2022](https://visualstudio.microsoft.com/) с workload **«Разработка классических приложений на C++»** — для сборки под Windows
- Android SDK + NDK — только для сборки под Android (`flutter doctor` показывает принятые лицензии)
- [Git](https://git-scm.com/)

### Шаги

```powershell
# 1. Клонируйте репозиторий
git clone https://github.com/lemluik/client-vpn.git
cd client-vpn

# 2. Создайте Flutter-проект (или используйте существующий)
flutter create --org com.clientvpn --platforms=windows,android .

# 3. Скачайте Xray-core v26.3.27
# Вариант A: скрипт (Git Bash)
bash scripts/download_xray.sh

# Вариант B: вручную
# https://github.com/XTLS/Xray-core/releases/tag/v26.3.27
# Скачайте Xray-windows-64.zip, распакуйте xray.exe в assets/xray/

# 4. Добавьте в windows/runner/CMakeLists.txt перед закрывающим ):
#
#    add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
#      COMMAND ${CMAKE_COMMAND} -E copy_directory
#      "${CMAKE_SOURCE_DIR}/../assets/xray"
#      "$<TARGET_FILE_DIR:${BINARY_NAME}>/xray"
#    )

# 5. Установите зависимости
flutter pub get

# 6. Соберите
flutter build windows
```

Готовый exe: `build\windows\x64\runner\Release\client_vpn.exe`

### Сборка Android

Нужен Android SDK (принятые лицензии, `compileSdk` и build-tools по версии Flutter). Ядро в git не лежит — его скачивает скрипт с проверкой SHA-256:

```powershell
# 1. Ядро Xray-core v26.3.27 под arm64-v8a в jniLibs
bash scripts/download_xray_android.sh

# 2. Зависимости и сборка
flutter pub get
flutter build apk --release
```

Готовый файл: `build\app\outputs\flutter-apk\app-release.apk` (только arm64-v8a, ядро уже внутри архива).

> [!WARNING]
> В `android/app/build.gradle.kts` релизная сборка подписана отладочным ключом. Перед публикацией в магазин или для обновлений поверх другой подписи настройте собственный ключ.

### Проверка окружения

```powershell
flutter doctor
```

Убедитесь, что «Visual Studio» показывает зелёную галочку. Если нет — установите Visual Studio 2022 Community с workload «Разработка классических приложений на C++».

## Архитектура

```
┌─────────────────────────────────────────┐
│         Flutter UI (Dart)               │
│  lib/main.dart — один экран             │
├─────────────────────────────────────────┤
│           lib/vpn_core.dart             │
│      общий интерфейс ядра (abstract)    │
├──────────────────┬──────────────────────┤
│ desktop_core.dart│   android_core.dart   │
│ локальный прокси │  MethodChannel →      │
│ + реестр Windows │  TunnelService (Kotlin)│
├──────────────────┴──────────────────────┤
│  Process.start/kill  ·  VpnService TUN  │
├─────────────────────────────────────────┤
│  xray.exe / libxray.so (подпроцесс)     │
│  Xray-core 26.3.27 (MPL-2.0)            │
├─────────────────────────────────────────┤
│  VLESS+Reality → ваш сервер → интернет  │
└─────────────────────────────────────────┘
```

**Ключевые решения:**
- **Ядро как подпроцесс** — не FFI, не Go-обёртка. На десктопе `Process.start()`, на Android — тот же бинарник под именем `libxray.so`, потому что Android 10+ разрешает исполнять файлы только из каталога распакованных нативных библиотек.
- **Туннель на Android через унаследованный дескриптор** — libcore закрывает в дочернем процессе все дескрипторы, кроме стандартных, поэтому дескриптор туннеля передаётся как stdin, а ядро берёт его из переменной окружения `xray.tun.fd`.
- **System proxy через `reg`** — не win32 FFI. Команда `reg add` к HKCU\...\Internet Settings.
- **Валидация через `xray -test`** — штатная команда Xray, не своя логика.

### Структура проекта

```
client-vpn/
├── lib/
│   ├── main.dart              # UI (один экран)
│   ├── vpn_core.dart          # общий для платформ интерфейс ядра
│   ├── vpn_config.dart        # выбор, проверка и хранение config.json
│   ├── desktop_core.dart      # Windows/macOS/Linux: прокси + системные настройки
│   ├── android_core.dart      # Android: туннель через VpnService
│   ├── tun_config.dart        # сборка конфига с туннельным inbound
│   ├── proxy_config.dart      # разбор локальных inbound
│   └── system_proxy.dart      # системный прокси (реестр)
├── android/
│   └── app/src/main/kotlin/…/ # MainActivity, TunnelService, TunnelBus
├── assets/
│   └── xray/
│       └── xray.exe           # ядро для десктопа (не в git, скачивается отдельно)
├── scripts/
│   ├── download_xray.sh          # Xray-core для Windows + сверка SHA-256
│   └── download_xray_android.sh  # Xray-core для Android в jniLibs + сверка SHA-256
├── test/
│   ├── proxy_config_test.dart    # разбор локальных inbound
│   └── tun_config_test.dart      # сборка туннельного конфига
├── .github/
│   ├── ISSUE_TEMPLATE/        # шаблоны issues
│   └── dependabot.yml         # обновления зависимостей
├── analysis_options.yaml      # Dart lint rules
├── pubspec.yaml               # Flutter dependencies
├── LICENSE                    # MPL-2.0
├── NOTICE                     # Лицензии сторонних компонентов
├── README.md                  # Этот файл
├── CONTRIBUTING.md            # Как контрибьютить
├── CODE_OF_CONDUCT.md         # Кодекс поведения
├── SECURITY.md                # Политика безопасности
├── CHANGELOG.md               # История версий
└── .editorconfig              # Единый стиль файлов
```

## Известные проблемы

| Проблема | Решение |
|----------|---------|
| Антивирус блокирует xray.exe | Добавьте папку с приложением в исключения |
| System proxy не перехватывает весь трафик (Windows) | Ожидаемое ограничение: TUN на десктопе в планах. На Android трафик идёт через туннель VpnService |
| Прокси остался после crash | Клиент откатит его при следующем запуске, если прокси совпадает с установленным приложением. Вручную: `reg add "HKCU\...\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f` |
| xray.exe не найден | Скачайте его: `bash scripts/download_xray.sh`. Он попадёт в `assets/xray/`. После сборки проверьте `build\...\xray\xray.exe` |
| «Проверка целостности xray.exe не пройдена» | Бинарник повреждён или не соответствует закреплённой версии 26.3.27. Перекачайте: `bash scripts/download_xray.sh` |
| Подключение отклонено: «нет inbound http или socks» | Клиенту нужен локальный inbound в config.json, чтобы включить системный прокси. Добавьте inbound с протоколом `http` или `socks` |
| Android: «в конфиге нет прокси-исходящего соединения» | Для туннеля нужен outbound, который действительно уводит трафик на сервер (`vless`, `vmess`, `trojan`, `shadowsocks`, `socks`, `http`, `wireguard`). `freedom` и `blackhole` прокси не дают |
| Android: приложение не ставится на устройство | Сборка собрана только под arm64-v8a — на 32-битных устройствах установка невозможна |
| Android: ядро не запускается | `libxray.so` обязан быть в `android/app/src/main/jniLibs/arm64-v8a/` до сборки: `bash scripts/download_xray_android.sh` |

## Дорожная карта

- [x] **R1** — Windows MVP (system proxy, один профиль)
- [x] **R2** — Android (VpnService + TUN), ядро внутри APK, общий слой ядра для двух платформ
- [ ] **R2.1** — TUN на Windows (wintun), несколько профилей
- [ ] **R3** — iOS/macOS, Linux, автообновление, sing-box конвертер

## Безопасность

- Не храните config.json в публичных местах и в папках облачной синхронизации — он содержит приватные ключи. На десктопе клиент хранит только *путь* к файлу; на Android содержимое конфига сохраняется в приватной памяти приложения, потому что по content URI файл напрямую не открыть
- Целостность `xray.exe` проверяется автоматически: скрипт скачивания сверяет SHA-256 архива и бинарника с зашитыми эталонами, а приложение повторно проверяет SHA-256 перед каждым запуском и отказывается стартовать с подменённым файлом
- Клиент сохраняет ваши прежние настройки системного прокси и возвращает их при отключении; аварийный откат трогает прокси только если он в точности совпадает с установленным этим приложением
- Телеметрии, проверки обновлений и аналитики в клиенте нет
- См. [SECURITY.md](SECURITY.md) для сообщения об уязвимостях

## Лицензия

**MPL-2.0** — см. [LICENSE](LICENSE). Лицензия совпадает с лицензией ядра Xray-core, поэтому
копилефт остаётся файл-уровневым: публикуются изменённые MPL-файлы, а остальной код можно
использовать и в закрытых сборках.

Xray-core распространяется под **MPL-2.0** (Copyright XTLS/Xray-core authors), бинарники ядра
мы не изменяем. Полный список сторонних компонентов с версиями и текстами уведомлений —
в [NOTICE](NOTICE).

## Участие

Приветствуется! См. [CONTRIBUTING.md](CONTRIBUTING.md) и [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

---

<p align="center">
  Сделано с помощью <a href="https://flutter.dev">Flutter</a> и <a href="https://github.com/XTLS/Xray-core">Xray-core</a>
</p>
