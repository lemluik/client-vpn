<p align="center">
  <h1 align="center">КлиентВПН</h1>
  <p align="center">
    Open-source VPN-клиент на базе Xray-core (VLESS+Reality) для Windows
  </p>
  <p align="center">
    <a href="LICENSE">
      <img src="https://img.shields.io/badge/license-GPL--3.0-blue.svg" alt="License: GPL-3.0">
    </a>
    <a href="https://github.com/lemluik/client-vpn/releases">
      <img src="https://img.shields.io/github/v/release/lemluik/client-vpn" alt="Release">
    </a>
    <img src="https://img.shields.io/badge/platform-Windows%2010%2F11-blue" alt="Platform: Windows">
    <img src="https://img.shields.io/badge/xray-26.3.27-green" alt="Xray: 26.3.27">
    <a href="https://github.com/XTLS/Xray-core">
      <img src="https://img.shields.io/badge/powered%20by-Xray--core%20(MPL--2.0)-orange" alt="Powered by Xray-core">
    </a>
  </p>
</p>

---

## О проекте

КлиентВПН — минималистичный VPN-клиент для Windows, который управляет Xray-core как подпроцессом. Поддерживает VLESS+Reality, системный прокси и автоматический откат при сбое.

**Архитектура:** Flutter UI → xray.exe (подпроцесс) → VLESS+Reality → сервер → интернет. Никакого FFI, Go или TUN — только system proxy через реестр Windows.

## Скриншоты

> [!NOTE]
> Скриншоты будут добавлены после первого тестирования

<!-- Замените на реальные скриншоты:
<p align="center">
  <img src="docs/screenshots/main-disconnected.png" width="400" alt="Disconnected state">
  <img src="docs/screenshots/main-connected.png" width="400" alt="Connected state">
</p>
-->

## Возможности (R1)

- ✅ Импорт конфигурации Xray-core (config.json)
- ✅ Подключение через VLESS+Reality
- ✅ Системный прокси (inbound `http` или `socks` на localhost)
- ✅ Валидация конфига перед подключением (`xray -test`)
- ✅ Проверка SHA-256 у `xray.exe` перед каждым запуском — подменённый бинарник не запускается
- ✅ Сохранение и восстановление ваших прежних настроек системного прокси
- ✅ Откат прокси при остановке Xray, закрытии окна и после сбоя
- ✅ Лог работы в реальном времени

### Ограничения R1

- ⚠️ Только Windows (Android/iOS/macOS/Linux — в планах R2)
- ⚠️ Только system proxy (без TUN) — часть трафика может идти мимо
- ⚠️ Один профиль (один config.json)
- ⚠️ Нет автообновления

## Установка

### Из релиза (рекомендуется)

1. Скачайте `ClientVPN-v0.1.0-Windows-x64.zip` из [Releases](https://github.com/lemluik/client-vpn/releases)
2. Распакуйте в любую папку
3. Запустите `client_vpn.exe`

> [!TIP]
> Если антивирус блокирует `xray.exe` — добавьте папку с приложением в исключения.

## Использование

1. Нажмите **«Выбрать config.json»** и выберите файл конфигурации Xray
2. Дождитесь зелёной галочки ✓ (валидация пройдена)
3. Нажмите **«ПОДКЛЮЧИТЬ»**
4. Проверьте подключение: откройте https://ifconfig.co — должен показаться IP вашего сервера

Для отключения нажмите **«ОТКЛЮЧИТЬ»**.

## Сборка из исходников

### Требования

- [Flutter SDK](https://docs.flutter.dev/get-started/install/windows) (stable, ≥3.6.0)
- [Visual Studio 2022](https://visualstudio.microsoft.com/) с workload **«Разработка классических приложений на C++»**
- [Git](https://git-scm.com/)

### Шаги

```powershell
# 1. Клонируйте репозиторий
git clone https://github.com/lemluik/client-vpn.git
cd client-vpn

# 2. Создайте Flutter-проект (или используйте существующий)
flutter create --org com.clientvpn --platforms=windows .

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
│  XrayProcessManager    SystemProxy      │
│  lib/xray_process.dart lib/system_proxy │
├─────────────────────────────────────────┤
│  Process.start/kill    reg (реестр)     │
├─────────────────────────────────────────┤
│  xray.exe (подпроцесс)                  │
│  Xray-core 26.3.27 (MPL-2.0)           │
├─────────────────────────────────────────┤
│  VLESS+Reality → ваш сервер → интернет │
└─────────────────────────────────────────┘
```

**Ключевые решения:**
- **xray.exe как подпроцесс** — не FFI, не Go-обёртка. Просто `Process.start()`.
- **System proxy через `reg`** — не win32 FFI. Команда `reg add` к HKCU\...\Internet Settings.
- **Валидация через `xray -test`** — штатная команда Xray, не своя логика.

### Структура проекта

```
client-vpn/
├── lib/
│   ├── main.dart              # UI (один экран)
│   ├── xray_process.dart      # Управление xray.exe
│   └── system_proxy.dart      # Системный прокси (реестр)
├── assets/
│   └── xray/
│       └── xray.exe           # Бинарник (не в git, скачивается отдельно)
├── scripts/
│   └── download_xray.sh       # Скрипт скачивания Xray-core
├── .github/
│   └── ISSUE_TEMPLATE/        # Шаблоны issues
├── analysis_options.yaml      # Dart lint rules
├── pubspec.yaml               # Flutter dependencies
├── LICENSE                    # GPL-3.0
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
| System proxy не перехватывает весь трафик | Ожидаемое ограничение R1 (не TUN). TUN в R2 |
| Прокси остался после crash | Клиент откатит его при следующем запуске, если прокси совпадает с установленным приложением. Вручную: `reg add "HKCU\...\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f` |
| xray.exe не найден | Скачайте его: `bash scripts/download_xray.sh`. Он попадёт в `assets/xray/`. После сборки проверьте `build\...\xray\xray.exe` |
| «Проверка целостности xray.exe не пройдена» | Бинарник повреждён или не соответствует закреплённой версии 26.3.27. Перекачайте: `bash scripts/download_xray.sh` |
| Подключение отклонено: «нет inbound http или socks» | Клиенту нужен локальный inbound в config.json, чтобы включить системный прокси. Добавьте inbound с протоколом `http` или `socks` |

## Дорожная карта

- [x] **R1** — Windows MVP (system proxy, один профиль)
- [ ] **R2** — TUN mode (wintun), Android (VpnService), несколько профилей
- [ ] **R3** — iOS/macOS, Linux, автообновление, sing-box конвертер

## Безопасность

- Не храните config.json в публичных местах и в папках облачной синхронизации — он содержит приватные ключи. Клиент хранит только *путь* к файлу, не его содержимое
- Целостность `xray.exe` проверяется автоматически: скрипт скачивания сверяет SHA-256 архива и бинарника с зашитыми эталонами, а приложение повторно проверяет SHA-256 перед каждым запуском и отказывается стартовать с подменённым файлом
- Клиент сохраняет ваши прежние настройки системного прокси и возвращает их при отключении; аварийный откат трогает прокси только если он в точности совпадает с установленным этим приложением
- Телеметрии, проверки обновлений и аналитики в клиенте нет
- См. [SECURITY.md](SECURITY.md) для сообщения об уязвимостях

## Лицензия

**GPL-3.0** — см. [LICENSE](LICENSE)

Xray-core распространяется под **MPL-2.0** (Copyright XTLS/Xray-core authors).

## Участие

Приветствуется! См. [CONTRIBUTING.md](CONTRIBUTING.md) и [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

---

<p align="center">
  Сделано с помощью <a href="https://flutter.dev">Flutter</a> и <a href="https://github.com/XTLS/Xray-core">Xray-core</a>
</p>
