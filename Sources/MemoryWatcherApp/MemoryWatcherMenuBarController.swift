import AppKit
import MemoryWatcherCore

@MainActor
final class MemoryWatcherMenuBarController: NSObject, NSMenuDelegate {
  private let statusItem: NSStatusItem
  private let menu = NSMenu()
  private let currentUsageItem = NSMenuItem()
  private let pressureItem = NSMenuItem()
  private let historyItem = NSMenuItem()
  private let loginItem = NSMenuItem()
  private let quitItem = NSMenuItem()
  private let toggleHistory: () -> Void
  private let historyWindowIsVisible: () -> Bool
  private let setLoginEnabled: (Bool) -> Void
  private let quitApplication: () -> Void
  private var lastUsageValue: String?
  private var lastPressureLevel: MemoryPressureLevel?
  private var lastLoginStatus: LoginItemRegistrationStatus?
  private(set) var renderedUpdateCount: UInt64 = 0

  init(
    toggleHistory: @escaping () -> Void,
    historyWindowIsVisible: @escaping () -> Bool,
    setLoginEnabled: @escaping (Bool) -> Void,
    quitApplication: @escaping () -> Void
  ) {
    self.toggleHistory = toggleHistory
    self.historyWindowIsVisible = historyWindowIsVisible
    self.setLoginEnabled = setLoginEnabled
    self.quitApplication = quitApplication
    statusItem = NSStatusBar.system.statusItem(
      withLength: NSStatusItem.variableLength
    )
    super.init()
    configureStatusItem()
    configureMenu()
  }

  var isInstalled: Bool {
    statusItem.isVisible && statusItem.button != nil
  }

  var statusTitle: String {
    statusItem.button?.title ?? ""
  }

  var hasRequiredCommands: Bool {
    historyItem.target != nil
      && loginItem.target != nil
      && quitItem.target != nil
  }

  func update(
    memoryUsedBytes: UInt64?,
    pressureLevel: MemoryPressureLevel,
    loginStatus: LoginItemRegistrationStatus
  ) {
    let value = memoryUsedBytes.map(Self.formatGigabytes) ?? "— GB"
    guard
      value != lastUsageValue
        || pressureLevel != lastPressureLevel
        || loginStatus != lastLoginStatus
    else {
      return
    }
    statusItem.button?.title = value
    currentUsageItem.title = "現在の使用量（推定）: \(value)"
    pressureItem.title = "Pressure: \(pressureLevel.rawValue)"
    loginItem.state =
      loginStatus == .enabled || loginStatus == .requiresApproval
      ? .on
      : .off
    loginItem.toolTip =
      loginStatus == .requiresApproval
      ? "システム設定での許可が必要です"
      : nil
    lastUsageValue = value
    lastPressureLevel = pressureLevel
    lastLoginStatus = loginStatus
    renderedUpdateCount &+= 1
    updateHistoryCommandTitle()
  }

  func performPrimaryActionForTesting() {
    toggleHistory()
    updateHistoryCommandTitle()
  }

  @discardableResult
  func performStatusButtonClickForTesting() -> Bool {
    guard let button = statusItem.button else {
      return false
    }
    button.performClick(nil)
    return true
  }

  func menuWillOpen(_ menu: NSMenu) {
    updateHistoryCommandTitle()
  }

  private func configureStatusItem() {
    guard let button = statusItem.button else {
      return
    }
    let image = NSImage(
      systemSymbolName: "memorychip",
      accessibilityDescription: "Memory Watcher"
    )
    image?.isTemplate = true
    button.image = image
    button.imagePosition = .imageLeading
    button.title = "— GB"
    button.target = self
    button.action = #selector(statusItemPressed(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    button.toolTip = "クリック: 履歴を開閉 / 右クリック: メニュー"
    button.setAccessibilityLabel("Memory Watcher")
    button.setAccessibilityHelp("履歴を開閉します。右クリックで設定を表示します。")
  }

  private func configureMenu() {
    menu.delegate = self

    currentUsageItem.isEnabled = false
    pressureItem.isEnabled = false
    menu.addItem(currentUsageItem)
    menu.addItem(pressureItem)
    menu.addItem(.separator())

    historyItem.title = "履歴を開く"
    historyItem.target = self
    historyItem.action = #selector(toggleHistoryFromMenu(_:))
    menu.addItem(historyItem)

    loginItem.title = "ログイン時に起動"
    loginItem.target = self
    loginItem.action = #selector(toggleLoginItem(_:))
    menu.addItem(loginItem)
    menu.addItem(.separator())

    quitItem.title = "Memory Watcherを終了"
    quitItem.target = self
    quitItem.action = #selector(quit(_:))
    menu.addItem(quitItem)
  }

  @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
    if NSApp.currentEvent?.type == .rightMouseUp {
      statusItem.menu = menu
      sender.performClick(nil)
      statusItem.menu = nil
      return
    }
    performPrimaryActionForTesting()
  }

  @objc private func toggleHistoryFromMenu(_ sender: NSMenuItem) {
    performPrimaryActionForTesting()
  }

  @objc private func toggleLoginItem(_ sender: NSMenuItem) {
    setLoginEnabled(sender.state != .on)
  }

  @objc private func quit(_ sender: NSMenuItem) {
    quitApplication()
  }

  private func updateHistoryCommandTitle() {
    historyItem.title =
      historyWindowIsVisible() ? "履歴を閉じる" : "履歴を開く"
  }

  private static func formatGigabytes(_ bytes: UInt64) -> String {
    "\((Double(bytes) / 1_000_000_000).formatted(.number.precision(.fractionLength(2)))) GB"
  }
}
