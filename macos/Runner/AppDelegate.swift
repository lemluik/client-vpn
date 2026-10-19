import Cocoa
import FlutterMacOS
import ServiceManagement

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Cmd+Q, «Завершить» в Dock и выход системы идут мимо Dart. Без этого ядро
  /// снял бы только сторож, а системный прокси остался бы на мёртвом порту:
  /// интернет пропал бы до следующего запуска. Поэтому выход сначала уходит
  /// в Dart — он отключается и сам разрешает завершение.
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    return AppChannels.shared.shouldTerminate() ? .terminateNow : .terminateCancel
  }

  /// Клик по значку в Dock возвращает окно, спрятанное в строку меню.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      mainFlutterWindow?.makeKeyAndOrderFront(self)
      NSApp.activate(ignoringOtherApps: true)
    }
    return true
  }

  /// Ссылки `vless://`, `trojan://`, `vmess://` из браузера и мессенджеров.
  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      AppChannels.shared.open(link: url.absoluteString)
    }
  }
}

/// Каналы с Dart: те же имена и методы, что у Android, поэтому общий код
/// платформу не различает.
final class AppChannels {
  static let shared = AppChannels()

  private var app: FlutterMethodChannel?
  private var deepLink: FlutterMethodChannel?

  /// Ссылка холодного старта ждёт, пока Dart подпишется (`takePending`).
  private var pendingLink: String?
  private var dartTookLinks = false

  /// Dart отключился и разрешил выход.
  private var quitAllowed = false
  private var quitRequested = false

  func attach(messenger: FlutterBinaryMessenger) {
    let app = FlutterMethodChannel(name: "client_vpn/app", binaryMessenger: messenger)
    app.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "isAutoStart":
        result(AppChannels.isAutoStart())
      case "setAutoStart":
        do {
          try AppChannels.setAutoStart(call.arguments as? Bool ?? false)
          result(nil)
        } catch {
          result(FlutterError(code: "autostart", message: error.localizedDescription, details: nil))
        }
      case "allowQuit":
        self?.quitAllowed = true
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.app = app

    let deepLink = FlutterMethodChannel(name: "client_vpn/deep_link", binaryMessenger: messenger)
    deepLink.setMethodCallHandler { [weak self] call, result in
      guard call.method == "takePending", let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.dartTookLinks = true
      result(self.pendingLink)
      self.pendingLink = nil
    }
    self.deepLink = deepLink
  }

  func open(link: String) {
    if dartTookLinks, let channel = deepLink {
      channel.invokeMethod("link", arguments: link)
    } else {
      pendingLink = link
    }
  }

  /// true — можно завершаться сразу. Иначе просьба ушла в Dart; если он не
  /// ответил за 5 секунд (завис), приложение всё равно завершается: выход,
  /// который не работает, хуже сироты, которую снимет сторож.
  func shouldTerminate() -> Bool {
    guard !quitAllowed, let app = app else { return true }
    if quitRequested { return false }
    quitRequested = true
    app.invokeMethod("quitRequested", arguments: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      self?.quitAllowed = true
      NSApp.terminate(nil)
    }
    return false
  }

  /// Автозапуск — «Объекты входа» системы (SMAppService, macOS 13+).
  /// Состояние читается у системы: пользователь мог выключить его там.
  static func isAutoStart() -> Bool {
    if #available(macOS 13.0, *) {
      return SMAppService.mainApp.status == .enabled
    }
    return false
  }

  static func setAutoStart(_ value: Bool) throws {
    guard #available(macOS 13.0, *) else {
      throw NSError(domain: "client_vpn", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Автозапуск поддерживается с macOS 13",
      ])
    }
    if value {
      try SMAppService.mainApp.register()
    } else if SMAppService.mainApp.status == .enabled {
      try SMAppService.mainApp.unregister()
    }
  }
}
