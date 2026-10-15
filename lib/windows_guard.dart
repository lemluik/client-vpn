import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Защита Windows-сборки: одиночный экземпляр и Job Object для ядра.
///
/// Оба механизма — чистый Win32 без Flutter: их проверяют обычные тесты на
/// настоящем Windows, а Android к этому файлу не обращается.

typedef _CreateMutexNative = IntPtr Function(IntPtr, Int32, Pointer<Utf16>);
typedef _HandleNative = Int32 Function(IntPtr);
typedef _LastErrorNative = Uint32 Function();
typedef _OpenProcessNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _CreateJobNative = IntPtr Function(IntPtr, Pointer<Utf16>);
typedef _AssignJobNative = Int32 Function(IntPtr, IntPtr);
typedef _SetJobInfoNative =
    Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32);

/// `ERROR_ALREADY_EXISTS`: мьютекс уже существует — экземпляр не единственный.
const int errorAlreadyExists = 183;

/// Права на процесс, которые требует `AssignProcessToJobObject`.
const int _processTerminate = 0x0001;
const int _processSetQuota = 0x0100;

/// Класс информации `JobObjectExtendedLimitInformation`.
///
/// Базовый класс (2) с этим же флагом Windows 11 не принимает:
/// `SetInformationJobObject` отвечает `ERROR_INVALID_PARAMETER` (замер
/// 16.10.2026). Принят расширенный — его структура на x64 занимает 144 байта.
const int _extendedLimitInformation = 9;

/// Флаг `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.
const int _killOnJobClose = 0x00002000;

/// Размер `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` на x64.
const int _limitSize = 144;

/// Смещение поля `LimitFlags` — начало вложенной базовой структуры лимитов.
const int _limitFlagsOffset = 16;

final _Win32? _kernel = Platform.isWindows
    ? _Win32(DynamicLibrary.open('kernel32.dll'))
    : null;

class _Win32 {
  _Win32(DynamicLibrary lib)
    : createMutex = lib
          .lookupFunction<
            _CreateMutexNative,
            int Function(int, int, Pointer<Utf16>)
          >('CreateMutexW'),
      releaseMutex = lib.lookupFunction<_HandleNative, int Function(int)>(
        'ReleaseMutex',
      ),
      closeHandle = lib.lookupFunction<_HandleNative, int Function(int)>(
        'CloseHandle',
      ),
      lastError = lib.lookupFunction<_LastErrorNative, int Function()>(
        'GetLastError',
      ),
      openProcess = lib
          .lookupFunction<_OpenProcessNative, int Function(int, int, int)>(
            'OpenProcess',
          ),
      createJob = lib
          .lookupFunction<_CreateJobNative, int Function(int, Pointer<Utf16>)>(
            'CreateJobObjectW',
          ),
      assignJob = lib.lookupFunction<_AssignJobNative, int Function(int, int)>(
        'AssignProcessToJobObject',
      ),
      setJobInfo = lib
          .lookupFunction<
            _SetJobInfoNative,
            int Function(int, int, Pointer<Void>, int)
          >('SetInformationJobObject');

  final int Function(int, int, Pointer<Utf16>) createMutex;
  final int Function(int) releaseMutex;
  final int Function(int) closeHandle;
  final int Function() lastError;
  final int Function(int, int, int) openProcess;
  final int Function(int, Pointer<Utf16>) createJob;
  final int Function(int, int) assignJob;
  final int Function(int, int, Pointer<Void>, int) setJobInfo;
}

/// Именованный мьютекс: второй экземпляр приложения не поднимется.
///
/// Ручку держим до завершения процесса. При внешнем убийстве процесса
/// операционная система закрывает ручки сама, так что блокировка не остаётся.
final class SingleInstanceLock {
  SingleInstanceLock._(this._kernel32, this._handle, this.name);

  final _Win32 _kernel32;
  final int _handle;
  final String name;

  /// Имя мьютекса одиночного экземпляра. Не привязано к сервису: клиент
  /// универсальный.
  static const defaultName = 'ClientVpn.SingleInstance.v1';

  /// null — если такой мьютекс уже занят, или если платформа не Windows.
  static SingleInstanceLock? tryAcquire([String name = defaultName]) {
    final kernel = _kernel;
    if (kernel == null) return null;
    final namePtr = name.toNativeUtf16();
    try {
      final handle = kernel.createMutex(0, 1, namePtr);
      final error = kernel.lastError();
      if (handle == 0) return null;
      if (error == errorAlreadyExists) {
        kernel.closeHandle(handle);
        return null;
      }
      return SingleInstanceLock._(kernel, handle, name);
    } finally {
      calloc.free(namePtr);
    }
  }

  /// Отдаёт владение и закрывает ручку: ждать процесса-держателя больше не нужно.
  void release() {
    _kernel32.releaseMutex(_handle);
    _kernel32.closeHandle(_handle);
  }
}

/// Job Object с флагом «умереть вместе с держателем».
///
/// Ядро сажается в jobs сразу после запуска. Если приложение убито извне,
/// операционная система закрывает его ручки, последней закрывается ручка jobs,
/// и ядро завершается вместе с ним. Без этого сирота-ядро продолжает работать
/// с включённым системным прокси.
final class CoreKillJob {
  CoreKillJob._(this._kernel32, this._handle, this.killOnCloseArmed);

  final _Win32 _kernel32;
  final int _handle;

  /// Флаг принят ядром Windows. Без него сажать процесс в jobs смысла нет:
  /// защиты это не даёт.
  final bool killOnCloseArmed;

  static CoreKillJob? create() {
    final kernel = _kernel;
    if (kernel == null) return null;
    final handle = kernel.createJob(0, nullptr);
    if (handle == 0) return null;

    final info = calloc.allocate(_limitSize);
    try {
      final words = info.cast<Uint32>().asTypedList(_limitSize ~/ 4);
      words[_limitFlagsOffset ~/ 4] = _killOnJobClose;
      final armed = kernel.setJobInfo(
        handle,
        _extendedLimitInformation,
        info.cast(),
        _limitSize,
      );
      return CoreKillJob._(kernel, handle, armed != 0);
    } finally {
      calloc.free(info);
    }
  }

  /// false — если посадить не удалось (процесс уже в чужом jobs, нет прав,
  /// флаг не принят). Подключение при этом не рвётся: деградация честная,
  /// а не иллюзия защиты.
  bool assign(int pid) {
    if (!killOnCloseArmed || _handle == 0) return false;
    final process = _kernel32.openProcess(
      _processTerminate | _processSetQuota,
      0,
      pid,
    );
    if (process == 0) return false;
    try {
      return _kernel32.assignJob(_handle, process) != 0;
    } finally {
      _kernel32.closeHandle(process);
    }
  }

  /// Закрывает ручку jobs: если она последняя, все процессы в jobs умирают.
  void close() {
    if (_handle == 0) return;
    _kernel32.closeHandle(_handle);
  }
}
