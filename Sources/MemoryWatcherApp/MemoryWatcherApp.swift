import AppKit
import Foundation
import MemoryWatcherCore
import SwiftUI

@MainActor
private final class MemoryWatcherApplicationCoordinator: NSObject,
  NSApplicationDelegate, NSWindowDelegate
{
  private let arguments = Array(CommandLine.arguments.dropFirst())
  private let viewModel = MonitoringViewModel()
  private var database: MemoryWatcherDatabase?
  private var engine: MemoryMonitoringEngine?
  private var window: NSWindow?
  private var menuBarController: MemoryWatcherMenuBarController?
  private var temporaryDirectory: URL?
  private var historyReferenceDate: Date?
  private var historyScreenStartedAt: Date?

  private var isHistoryUITest: Bool {
    arguments == ["--history-ui-smoke-test"]
      || arguments == ["--history-ui-preview"]
  }

  private var isMenuBarTest: Bool {
    arguments == ["--menu-bar-smoke-test"]
      || arguments == ["--menu-bar-preview"]
  }

  private var shouldShowHistoryWindowOnLaunch: Bool {
    arguments == ["--smoke-test"]
      || arguments == ["--lifecycle-smoke-test"]
      || arguments == ["--login-item-smoke-test"]
      || isHistoryUITest
      || arguments == ["--menu-bar-preview"]
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    configureWindow()
    configureMenuBar()
    configureMonitoring()
    observeSystemLifecycle()

    if shouldShowHistoryWindowOnLaunch {
      showHistoryWindow()
    }

    if arguments == ["--smoke-test"] {
      runFoundationSmokeTest()
    } else if arguments == ["--lifecycle-smoke-test"] {
      runLifecycleSmokeTest()
    } else if arguments == ["--login-item-smoke-test"] {
      runLoginItemSmokeTest()
    } else if arguments == ["--history-ui-smoke-test"] {
      runHistoryUISmokeTest()
    } else if arguments == ["--menu-bar-smoke-test"] {
      runMenuBarSmokeTest()
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    viewModel.refreshLoginItemStatus()
    refreshMenuBar()
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    false
  }

  func applicationWillTerminate(_ notification: Notification) {
    engine?.stop()
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    NotificationCenter.default.removeObserver(self)
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
  }

  private func configureMonitoring() {
    do {
      let databaseURL = try monitoringDatabaseURL()
      let database = try MemoryWatcherDatabase(url: databaseURL)
      if isHistoryUITest {
        let now = Date()
        try HistoryUISmokeFixture.populate(database: database, now: now)
        historyReferenceDate = now
      }
      let engine = MemoryMonitoringEngine(database: database) { [weak self] event in
        Task { @MainActor [weak self] in
          self?.handleMonitoringEvent(event)
        }
      }
      try engine.start()
      self.database = database
      self.engine = engine
      viewModel.updateRunState(engine.state)
      let startedAt = Date()
      viewModel.configureHistory(
        database: database,
        initialPeriod: isHistoryUITest ? .threeDays : .twentyFourHours,
        now: historyReferenceDate ?? Date()
      )
      historyScreenStartedAt = startedAt
      refreshMenuBar()
    } catch {
      viewModel.reportStartupFailure(error)
      refreshMenuBar()
    }
  }

  private func monitoringDatabaseURL() throws -> URL {
    guard
      arguments == ["--smoke-test"]
        || arguments == ["--lifecycle-smoke-test"]
        || arguments == ["--login-item-smoke-test"]
        || isHistoryUITest
        || isMenuBarTest
    else {
      return try MemoryWatcherDatabase.defaultURL()
    }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    temporaryDirectory = directory
    return directory.appendingPathComponent("smoke.sqlite3")
  }

  private func configureWindow() {
    let contentView = NSHostingView(
      rootView: FoundationView(viewModel: viewModel)
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 900),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.center()
    window.contentView = contentView
    window.title = "Memory Watcher"
    window.isReleasedWhenClosed = false
    window.delegate = self
    self.window = window
  }

  private func configureMenuBar() {
    menuBarController = MemoryWatcherMenuBarController(
      toggleHistory: { [weak self] in
        self?.toggleHistoryWindow()
      },
      historyWindowIsVisible: { [weak self] in
        self?.window?.isVisible ?? false
      },
      setLoginEnabled: { [weak self] enabled in
        self?.viewModel.setLoginItemEnabled(enabled)
        self?.refreshMenuBar()
      },
      quitApplication: {
        NSApplication.shared.terminate(nil)
      }
    )
    refreshMenuBar()
  }

  private func handleMonitoringEvent(_ event: MemoryMonitoringEvent) {
    viewModel.receive(event)
    refreshMenuBar()
  }

  private func refreshMenuBar() {
    menuBarController?.update(
      memoryUsedBytes: viewModel.lastMemoryUsedBytes,
      pressureLevel: viewModel.pressureLevel,
      loginStatus: viewModel.loginItemStatus
    )
  }

  private func showHistoryWindow() {
    guard let window else {
      return
    }
    viewModel.history.setWindowVisible(true)
    NSApplication.shared.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
  }

  private func toggleHistoryWindow() {
    guard let window else {
      return
    }
    if window.isVisible {
      viewModel.history.setWindowVisible(false)
      window.orderOut(nil)
    } else {
      showHistoryWindow()
    }
  }

  func windowWillClose(_ notification: Notification) {
    viewModel.history.setWindowVisible(false)
  }

  private func observeSystemLifecycle() {
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    workspaceCenter.addObserver(
      self,
      selector: #selector(workspaceWillSleep(_:)),
      name: NSWorkspace.willSleepNotification,
      object: nil
    )
    workspaceCenter.addObserver(
      self,
      selector: #selector(workspaceDidWake(_:)),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(systemClockDidChange(_:)),
      name: Notification.Name.NSSystemClockDidChange,
      object: nil
    )
  }

  @objc private func workspaceWillSleep(_ notification: Notification) {
    engine?.prepareForSleep()
    updateRunState()
  }

  @objc private func workspaceDidWake(_ notification: Notification) {
    engine?.resumeAfterWake()
    updateRunState()
  }

  @objc private func systemClockDidChange(_ notification: Notification) {
    engine?.recordSystemClockChange()
  }

  private func updateRunState() {
    if let engine {
      viewModel.updateRunState(engine.state)
    }
  }

  private func runFoundationSmokeTest() {
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window else {
        return
      }
      let bundleIdentifier = Bundle.main.bundleIdentifier ?? "UNKNOWN"
      let historyWindowCount = NSApplication.shared.windows.filter {
        $0.title == "Memory Watcher" && $0.styleMask.contains(.titled)
      }.count
      let status =
        bundleIdentifier == "com.oneroad.memorywatcher"
          && historyWindowCount == 1
          && window.isVisible
          && self.engine?.state == .running
          && (try? self.database?.sampleCount()) ?? 0 >= 1
        ? "PASS"
        : "FAIL"
      self.writeSmokeResult(
        [
          "bundle_identifier": bundleIdentifier,
          "monitoring_state": self.engine?.state.rawValue ?? "stopped",
          "sample_count": (try? self.database?.sampleCount()) ?? 0,
          "status": status,
          "visible": window.isVisible,
          "application_window_count": NSApplication.shared.windows.count,
          "window_count": historyWindowCount,
        ]
      )
      NSApplication.shared.terminate(nil)
    }
  }

  private func runLifecycleSmokeTest() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.window?.close()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { [weak self] in
      guard let self else {
        return
      }
      let sampleCount = (try? self.database?.sampleCount()) ?? 0
      let windowVisible = self.window?.isVisible ?? false
      let state = self.engine?.state ?? .stopped
      let status =
        sampleCount >= 2 && !windowVisible && state == .running
        ? "PASS"
        : "FAIL"
      self.writeSmokeResult(
        [
          "monitoring_state": state.rawValue,
          "sample_count": sampleCount,
          "status": status,
          "window_visible_after_close": windowVisible,
        ]
      )
      NSApplication.shared.terminate(nil)
    }
  }

  private func runLoginItemSmokeTest() {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        return
      }

      let manager = LoginItemManager()
      let initialStatus = manager.status
      guard initialStatus != .enabled && initialStatus != .requiresApproval
      else {
        self.writeSmokeResult(
          [
            "initial_status": initialStatus.rawValue,
            "reason": "existing login item state was preserved",
            "status": "SKIP",
          ]
        )
        NSApplication.shared.terminate(nil)
        return
      }

      var enabledStatus = LoginItemRegistrationStatus.notRegistered
      var restoredStatus = initialStatus
      var errorDescription: String?
      do {
        try manager.setEnabled(true)
        enabledStatus = manager.status
        try manager.setEnabled(false)
        restoredStatus = manager.status
      } catch {
        errorDescription = String(describing: error)
        _ = try? manager.setEnabled(false)
        restoredStatus = manager.status
      }

      let enabledWasAccepted =
        enabledStatus == .enabled || enabledStatus == .requiresApproval
      var result: [String: Any] = [
        "enabled_status": enabledStatus.rawValue,
        "initial_status": initialStatus.rawValue,
        "restored_status": restoredStatus.rawValue,
        "status":
          enabledWasAccepted && restoredStatus == .notRegistered
          ? "PASS"
          : "FAIL",
      ]
      if let errorDescription {
        result["error"] = errorDescription
      }
      self.writeSmokeResult(result)
      NSApplication.shared.terminate(nil)
    }
  }

  private func runHistoryUISmokeTest() {
    waitForHistoryScreen(deadline: Date().addingTimeInterval(5))
  }

  private func runMenuBarSmokeTest() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard
        let self,
        let window = self.window,
        let menuBarController = self.menuBarController
      else {
        return
      }
      let initiallyHidden = !window.isVisible
      let firstButtonAction =
        menuBarController.performStatusButtonClickForTesting()
      let openedFromMenuBar = window.isVisible
      let secondButtonAction =
        menuBarController.performStatusButtonClickForTesting()
      let closedFromMenuBar = !window.isVisible
      let statusTitle = menuBarController.statusTitle
      let status =
        NSApplication.shared.activationPolicy() == .accessory
          && menuBarController.isInstalled
          && menuBarController.hasRequiredCommands
          && firstButtonAction
          && secondButtonAction
          && initiallyHidden
          && openedFromMenuBar
          && closedFromMenuBar
          && statusTitle.hasSuffix(" GB")
          && !statusTitle.contains("—")
          && self.engine?.state == .running
        ? "PASS"
        : "FAIL"
      self.writeSmokeResult([
        "activation_policy": "accessory",
        "button_action_dispatched": firstButtonAction && secondButtonAction,
        "closed_from_menu_bar": closedFromMenuBar,
        "initially_hidden": initiallyHidden,
        "menu_commands_present": menuBarController.hasRequiredCommands,
        "monitoring_state": self.engine?.state.rawValue ?? "stopped",
        "opened_from_menu_bar": openedFromMenuBar,
        "status": status,
        "status_item_installed": menuBarController.isInstalled,
        "status_title": statusTitle,
      ])
      NSApplication.shared.terminate(nil)
    }
  }

  private func waitForHistoryScreen(deadline: Date) {
    guard Date() < deadline else {
      writeSmokeResult([
        "reason": "history screen did not become ready",
        "status": "FAIL",
      ])
      NSApplication.shared.terminate(nil)
      return
    }
    guard
      let snapshot = viewModel.historySnapshot,
      snapshot.period == .threeDays,
      !viewModel.historyIsLoading,
      let loadDuration = viewModel.historyLoadDurationSeconds,
      let startedAt = historyScreenStartedAt,
      let window
    else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.waitForHistoryScreen(deadline: deadline)
      }
      return
    }

    window.displayIfNeeded()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      guard let self else {
        return
      }
      let readyDuration = Date().timeIntervalSince(startedAt)
      let status =
        snapshot.points.count >= 4_000
          && snapshot.cpuHistory.totalPoints.count >= 4_000
          && snapshot.cpuHistory.logicalPoints.count >= 32_000
          && loadDuration < 2
          && readyDuration < 2
          && window.isVisible
        ? "PASS"
        : "FAIL"
      self.writeSmokeResult([
        "history_load_seconds": loadDuration,
        "history_point_count": snapshot.points.count,
        "history_source": snapshot.points.first?.source.rawValue ?? "NONE",
        "logical_cpu_point_count": snapshot.cpuHistory.logicalPoints.count,
        "screen_ready_seconds": readyDuration,
        "sleep_interval_count": snapshot.sleepIntervals.count,
        "status": status,
        "total_cpu_point_count": snapshot.cpuHistory.totalPoints.count,
        "visible": window.isVisible,
      ])
      NSApplication.shared.terminate(nil)
    }
  }

  private func writeSmokeResult(_ result: [String: Any]) {
    let data = try? JSONSerialization.data(
      withJSONObject: result,
      options: [.sortedKeys]
    )
    if let data {
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data([0x0A]))
    }
  }
}

@main
enum MemoryWatcherApp {
  @MainActor
  private static var coordinator: MemoryWatcherApplicationCoordinator?

  @MainActor
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let coordinator = MemoryWatcherApplicationCoordinator()
    self.coordinator = coordinator
    application.delegate = coordinator
    application.run()
  }
}
