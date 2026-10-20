import Cocoa
import FlutterMacOS
import ServiceManagement

@main
class AppDelegate: FlutterAppDelegate {
  /// AppKit treats a window hidden to the menu bar (`orderOut`) as the last
  /// window closed: with `true`, Minimize quit the app right away. Quitting
  /// stays with Dart: the close prompt, the Quit menu item and Cmd+Q.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Cmd+Q, Quit in the Dock and system logout bypass Dart. Without this only
  /// the watchdog would stop the core, and the system proxy would stay on a
  /// dead port: no internet until the next launch. So quitting goes to Dart
  /// first; it disconnects and then allows termination itself.
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    return AppChannels.shared.shouldTerminate() ? .terminateNow : .terminateCancel
  }

  /// Clicking the Dock icon brings back a window hidden to the menu bar.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      mainFlutterWindow?.makeKeyAndOrderFront(self)
      NSApp.activate(ignoringOtherApps: true)
    }
    return true
  }

  /// `vless://`, `trojan://` and `vmess://` links from browsers and messengers.
  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      AppChannels.shared.open(link: url.absoluteString)
    }
  }
}

/// Channels to Dart: same names and methods as on Android, so the shared code
/// does not need to tell the platforms apart.
final class AppChannels {
  static let shared = AppChannels()

  private var app: FlutterMethodChannel?
  private var deepLink: FlutterMethodChannel?

  /// A cold-start link waits until Dart subscribes (`takePending`).
  private var pendingLink: String?
  private var dartTookLinks = false

  /// Dart has disconnected and allowed the app to quit.
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

  /// true: terminate right away. Otherwise the request goes to Dart; if it
  /// does not answer within 5 seconds (hung), the app terminates anyway: a
  /// quit that does not work is worse than an orphan the watchdog will stop.
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

  /// Autostart is a system Login Item (SMAppService, macOS 13+).
  /// The state is read from the system: the user may have turned it off there.
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
