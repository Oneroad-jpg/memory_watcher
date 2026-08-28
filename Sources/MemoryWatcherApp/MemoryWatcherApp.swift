import AppKit
import Foundation
import MemoryWatcherCore
import SwiftUI

@MainActor
private final class MemoryWatcherApplicationCoordinator: NSObject,
  NSApplicationDelegate
{
  private let arguments = Array(CommandLine.arguments.dropFirst())
  private let viewModel = MonitoringViewModel()
  private var database: MemoryWatcherDatabase?
  private var engine: MemoryMonitoringEngine?
  private var window: NSWindow?
  private var temporaryDirectory: URL?

  func applicationDidFinishLaunching(_ notification: Notification) {
    configureMonitoring()
    configureWindow()
    observeSystemLifecycle()

    guard let window else {
      return
    }
    let application = NSApplication.shared
    application.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()

    if arguments == ["--smoke-test"] {
      runFoundationSmokeTest()
    } else if arguments == ["--lifecycle-smoke-test"] {
      runLifecycleSmokeTest()
    } else if arguments == ["--login-item-smoke-test"] {
      runLoginItemSmokeTest()
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    viewModel.refreshLoginItemStatus()
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
      let viewModel = self.viewModel
      let engine = MemoryMonitoringEngine(database: database) { event in
        Task { @MainActor [weak viewModel] in
          viewModel?.receive(event)
        }
      }
      try engine.start()
      self.database = database
      self.engine = engine
      viewModel.updateRunState(engine.state)
    } catch {
      viewModel.reportStartupFailure(error)
    }
  }

  private func monitoringDatabaseURL() throws -> URL {
    guard
      arguments == ["--smoke-test"]
        || arguments == ["--lifecycle-smoke-test"]
        || arguments == ["--login-item-smoke-test"]
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
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.center()
    window.contentView = contentView
    window.title = "Memory Watcher"
    window.isReleasedWhenClosed = false
    self.window = window
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
      let status =
        bundleIdentifier == "com.oneroad.memorywatcher"
          && NSApplication.shared.windows.count == 1
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
          "window_count": NSApplication.shared.windows.count,
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
    application.setActivationPolicy(.regular)
    let coordinator = MemoryWatcherApplicationCoordinator()
    self.coordinator = coordinator
    application.delegate = coordinator
    application.run()
  }
}
