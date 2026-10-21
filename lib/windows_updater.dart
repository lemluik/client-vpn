import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Подмена файлов клиента на Windows.
///
/// Свой exe нельзя перезаписать, пока процесс жив, поэтому установка всегда
/// односторонняя: приложение готовит staging-каталог, запускает отсоединённый
/// скрипт-обновитель и выходит. Скрипт дожидается завершения процесса, подменяет
/// файлы из архива, при ошибке откатывает сохранённые копии и запускает
/// приложение обратно.
///
/// Ничего, чего нет в архиве, не удаляется: `xray.exe` и гео-базы в релизный zip
/// не входят (`desktop_core.dart` ищет их рядом с exe), «чистая» переустановка
/// лишила бы клиента ядра.
///
/// Распаковка — штатным `tar` (bsdtar, Windows 10 1803+ читает zip): отдельной
/// зависимости-архиватора в pubspec нет, и заводить её ради этого этапа нельзя,
/// не пройдя гейт апгрейдов зависимостей.
class WindowsUpdater {
  const WindowsUpdater({
    required this.staging,
    required this.target,
    required this.workRoot,
  });

  static const exeName = 'client_vpn.exe';

  /// Каталог с `client_vpn.exe` внутри распакованного архива.
  final Directory staging;

  /// Каталог установленного приложения — тот, где лежит наш exe.
  final Directory target;

  /// Служебный каталог: скрипт, резервная копия, журнал.
  final Directory workRoot;

  /// Имя подкаталога версии в workRoot. `/` в номере не проходит в имена
  /// каталогов Windows, остальные символы релизный тег не отдаёт.
  static String stagingDirName(String version) =>
      'v${version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_')}';

  /// Распаковать [archivePath] и подготовить установщик.
  ///
  /// `null` — распаковка не удалась, `tar` нет в системе или архив не похож на
  /// сборку клиента. Прошлый staging вычищается: остатки неудачного раза попали бы
  /// в новую установку.
  static Future<WindowsUpdater?> stage({
    required String archivePath,
    required String version,
    required Directory workRoot,
  }) async {
    final staging = Directory(
      p.join(workRoot.path, 'client_vpn_update', stagingDirName(version)),
    );
    try {
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      final result = await Process.run(
        'tar',
        ['-xf', archivePath, '-C', staging.path],
      );
      if (result.exitCode != 0) {
        debugPrint('WindowsUpdater: tar exit ${result.exitCode}: ${result.stderr}');
        return null;
      }
      final packageRoot = await _packageRoot(staging);
      if (packageRoot == null) {
        debugPrint('WindowsUpdater: в архиве нет $exeName');
        return null;
      }
      return WindowsUpdater(
        staging: packageRoot,
        target: File(Platform.resolvedExecutable).parent,
        workRoot: Directory(p.join(workRoot.path, 'client_vpn_update')),
      );
    } on ProcessException catch (e) {
      debugPrint('WindowsUpdater: tar недоступен: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('WindowsUpdater: staging failed: $e');
      return null;
    }
  }

  /// Архив раскладывается файлами в корне, но ручной релиз может обернуть сборку
  /// одной папкой — ищем exe и там, и там.
  static Future<Directory?> _packageRoot(Directory staging) async {
    if (await File(p.join(staging.path, exeName)).exists()) return staging;
    for (final entity in await staging.list().toList()) {
      if (entity is Directory &&
          await File(p.join(entity.path, exeName)).exists()) {
        return entity;
      }
    }
    return null;
  }

  /// Каталог установки для текущего процесса.
  static Directory installDir() => File(Platform.resolvedExecutable).parent;

  /// Можно ли подменять файлы в каталоге установки.
  ///
  /// Проверяется записью пробника, а не разбором ACL: portable-раскладка в
  /// `%LOCALAPPDATA%` проходит, та же папка внутри Program Files — нет. Повышать
  /// привилегии без ведома пользователя нельзя: UAC «из ниоткуда» выглядит как
  /// взлом, а не как обновление.
  static Future<bool> canWriteTarget() async {
    final probe = File(p.join(installDir().path, '.cvpn-write-probe.tmp'));
    try {
      await probe.writeAsString('probe', flush: true);
      await probe.delete();
      return true;
    } catch (e) {
      debugPrint('WindowsUpdater: каталог установки недоступен на запись: $e');
      return false;
    }
  }

  /// Пишет скрипт-обновитель и запускает его отсоединённым процессом.
  ///
  /// Вызывать непосредственно перед выходом приложения: обновитель ждёт завершения
  /// процесса клиента и только потом подменяет exe. Скрипт отрывается от процесса
  /// через `cmd /c start`: `ProcessStartMode.detached` для `powershell.exe` не
  /// работает — процесс создаётся и молча умирает, не успевает прочитать скрипт
  /// (замер 20.10.2026: `detached` и `detachedWithStdio` не пишут журнал вообще,
  /// `cmd start /b` доводит подмену до конца).
  ///
  /// Журнал — `client_vpn_update\update.log`: по нему приёмка отличает
  /// «обновление установилось» от «приложение просто закрылось».
  Future<void> spawnInstaller({required int processId, required String version}) async {
    final script = File(p.join(workRoot.path, 'update.ps1'));
    await script.writeAsString(_scriptBody, flush: true);
    await Process.start(
      'cmd.exe',
      [
        '/c',
        'start',
        '""',
        '/b',
        'powershell.exe',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-ProcId',
        '$processId',
        '-Staging',
        staging.path,
        '-Target',
        target.path,
        '-Backup',
        p.join(workRoot.path, 'backup'),
        '-LogPath',
        logFile.path,
        '-Version',
        version,
      ],
      mode: ProcessStartMode.detached,
    );
  }

  /// Журнал последней попытки установки: `null`, если обновитель не запускался.
  File get logFile => File(p.join(workRoot.path, 'update.log'));

  /// Пути приходят параметрами, а не вшиванием в текст: кириллица и пробелы в
  /// пути не ломают скрипт и не превращаются в исполняемый код.
  static const _scriptBody = r'''
param(
  [Parameter(Mandatory = $true)][int]$ProcId,
  [Parameter(Mandatory = $true)][string]$Staging,
  [Parameter(Mandatory = $true)][string]$Target,
  [Parameter(Mandatory = $true)][string]$Backup,
  [Parameter(Mandatory = $true)][string]$LogPath,
  [Parameter(Mandatory = $true)][string]$Version
)

$ErrorActionPreference = 'Stop'
function Log($msg) {
  Add-Content -LiteralPath $LogPath -Value ('{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg)
}

Set-Content -LiteralPath $LogPath -Value ('--- update to ' + $Version)
New-Item -ItemType Directory -Force -Path $Backup | Out-Null

# Own exe can only be overwritten after the process has exited.
$deadline = (Get-Date).AddSeconds(30)
while (Get-Process -Id $ProcId -ErrorAction SilentlyContinue) {
  if ((Get-Date) -gt $deadline) { Log 'application did not exit in 30 s'; break }
  Start-Sleep -Milliseconds 200
}
Start-Sleep -Milliseconds 500

$exe = Join-Path $Target 'client_vpn.exe'
$swapped = @()
try {
  foreach ($file in (Get-ChildItem -LiteralPath $Staging -File -Recurse)) {
    $rel = $file.FullName.Substring($Staging.Length).TrimStart('\')
    $dest = Join-Path $Target $rel
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) {
      New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }
    if (Test-Path -LiteralPath $dest) {
      $saved = Join-Path $Backup $rel
      $savedDir = Split-Path -Parent $saved
      if (-not (Test-Path -LiteralPath $savedDir)) {
        New-Item -ItemType Directory -Force -Path $savedDir | Out-Null
      }
      Copy-Item -LiteralPath $dest -Destination $saved -Force
      $swapped += , @($dest, $saved)
    }
    $ok = $false
    for ($try = 1; $try -le 10; $try++) {
      try { Copy-Item -LiteralPath $file.FullName -Destination $dest -Force; $ok = $true; break }
      catch {
        Log ('retry ' + $try + ' ' + $rel + ': ' + $_.Exception.Message)
        Start-Sleep -Milliseconds 400
      }
    }
    if (-not $ok) { throw ('cannot write ' + $rel) }
  }
  Log ('swapped ' + $swapped.Count + ' file(s)')
}
catch {
  Log ('failed: ' + $_.Exception.Message + '; rolling back')
  foreach ($pair in $swapped) {
    try { Copy-Item -LiteralPath $pair[1] -Destination $pair[0] -Force }
    catch { Log ('rollback lost ' + $pair[0]) }
  }
  if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe | Out-Null }
  exit 1
}

Remove-Item -LiteralPath $Backup -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction SilentlyContinue
Start-Process -FilePath $exe | Out-Null
Log ('relaunched ' + $exe)
exit 0
''';
}
