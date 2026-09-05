import AppKit
import Darwin
import Foundation
import MemoryWatcherCore
import SwiftUI

private struct DashboardSmokeConfiguration {
  let period: MemoryHistoryPeriod
  let logicalCPUCount: Int
  let width: CGFloat
  let height: CGFloat
  let appearanceName: NSAppearance.Name

  init?(arguments: [String]) {
    guard
      arguments.count == 6,
      arguments[0] == "--dashboard-ui-smoke-test",
      let period = MemoryHistoryPeriod(rawValue: arguments[1]),
      let logicalCPUCount = Int(arguments[2]),
      (1...32).contains(logicalCPUCount),
      let width = Double(arguments[3]),
      let height = Double(arguments[4]),
      width >= 780,
      height >= 700
    else { return nil }
    let appearanceName: NSAppearance.Name
    switch arguments[5] {
    case "light": appearanceName = .aqua
    case "dark": appearanceName = .darkAqua
    default: return nil
    }
    self.period = period
    self.logicalCPUCount = logicalCPUCount
    self.width = CGFloat(width)
    self.height = CGFloat(height)
    self.appearanceName = appearanceName
  }
}

private struct DashboardRuntimeAuditContext {
  let startedAt: Date
  let initialSampleCount: Int
  let initialMemoryGapCount: Int
  let initialMonitoringFailureCount: UInt64
  let initialHistoryLoadCount: UInt64
  let hiddenAt: Date
  let hiddenStartSampleCount: Int
  let hiddenStartMemoryGapCount: Int
  let historyLoadCountAtHide: UInt64
}

private struct DashboardPerformanceAuditContext {
  let startedAt: Date
  let startedUptime: TimeInterval
  let initialSampleCount: Int
  let initialHistoryLoadCount: UInt64
  let initialMemoryGapCount: Int
  let initialLogicalCPUGapCount: Int
}

private struct DashboardT21AuditContext {
  let phase: String
  let startedAt: Date
  let startedUptime: TimeInterval
  let initialProcessCPUSeconds: TimeInterval?
  let initialSampleCount: Int
  let initialTotalCPUSampleCount: Int
  let initialHistoryLoadCount: UInt64
  let initialMemoryGapCount: Int
  let initialLogicalCPUGapCount: Int
  let initialMonitoringFailureCount: UInt64
  let initialInteractionBlockCount: UInt64
}

private struct DashboardPeriodReadbackResult {
  let period: MemoryHistoryPeriod
  let memoryPointCount: Int
  let totalCPUPointCount: Int
  let logicalCPUPointCount: Int
  let matchedSelectionCount: Int
  let isValid: Bool

  var jsonValue: [String: Any] {
    [
      "logical_cpu_point_count": logicalCPUPointCount,
      "matched_selection_count": matchedSelectionCount,
      "memory_point_count": memoryPointCount,
      "period": period.rawValue,
      "status": isValid ? "PASS" : "FAIL",
      "total_cpu_point_count": totalCPUPointCount,
    ]
  }
}

private struct DashboardHistoryInputFingerprint: Equatable {
  let period: MemoryHistoryPeriod
  let startUTC: Date
  let endUTC: Date
  let memoryPointCount: Int
  let firstMemoryUTC: Date?
  let lastMemoryUTC: Date?
  let pressureIntervalCount: Int
  let sleepIntervalCount: Int
  let memoryDiscontinuityCount: Int
  let totalCPUPointCount: Int
  let firstTotalCPUUTC: Date?
  let lastTotalCPUUTC: Date?
  let logicalCPUPointCount: Int
  let firstLogicalCPUUTC: Date?
  let lastLogicalCPUUTC: Date?

  init(snapshot: MemoryHistorySnapshot) {
    period = snapshot.period
    startUTC = snapshot.startUTC
    endUTC = snapshot.endUTC
    memoryPointCount = snapshot.points.count
    firstMemoryUTC = snapshot.points.first?.timestampUTC
    lastMemoryUTC = snapshot.points.last?.timestampUTC
    pressureIntervalCount = snapshot.pressureIntervals.count
    sleepIntervalCount = snapshot.sleepIntervals.count
    memoryDiscontinuityCount = snapshot.memoryDiscontinuityDates.count
    totalCPUPointCount = snapshot.cpuHistory.totalPoints.count
    firstTotalCPUUTC = snapshot.cpuHistory.totalPoints.first?.timestampUTC
    lastTotalCPUUTC = snapshot.cpuHistory.totalPoints.last?.timestampUTC
    logicalCPUPointCount = snapshot.cpuHistory.logicalPoints.count
    firstLogicalCPUUTC = snapshot.cpuHistory.logicalPoints.first?.timestampUTC
    lastLogicalCPUUTC = snapshot.cpuHistory.logicalPoints.last?.timestampUTC
  }
}

private final class DashboardContainerView: NSView {
  private let currentView: NSView
  private let historyView: NSView

  init(currentView: NSView, historyView: NSView) {
    self.currentView = currentView
    self.historyView = historyView
    super.init(frame: .zero)
    addSubview(historyView)
    addSubview(currentView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override func layout() {
    super.layout()
    let currentHeight = min(360, max(220, bounds.height * 0.48))
    currentView.frame = NSRect(
      x: 0,
      y: bounds.height - currentHeight,
      width: bounds.width,
      height: currentHeight
    )
    historyView.frame = NSRect(
      x: 0,
      y: 0,
      width: bounds.width,
      height: max(0, bounds.height - currentHeight)
    )
  }
}

@MainActor
private final class MemoryWatcherApplicationCoordinator: NSObject,
  NSApplicationDelegate, NSWindowDelegate
{
  private let arguments = Array(CommandLine.arguments.dropFirst())
  private let viewModel = MonitoringViewModel()
  private let historyViewModel = HistoryViewModel()
  private let renderDiagnostics = DashboardRenderDiagnostics()
  private var database: MemoryWatcherDatabase?
  private var engine: MemoryMonitoringEngine?
  private var window: NSWindow?
  private var currentHostingView: NSView?
  private var historyHostingView: NSView?
  private var menuBarController: MemoryWatcherMenuBarController?
  private var monitoringActivity: NSObjectProtocol?
  private var monitoringFailureCount: UInt64 = 0
  private var dashboardT21InteractionBlockCount: UInt64 = 0
  private var temporaryDirectory: URL?
  private var historyReferenceDate: Date?
  private var historyScreenStartedAt: Date?

  private var isHistoryUITest: Bool {
    arguments == ["--history-ui-smoke-test"]
      || arguments == ["--history-ui-preview"]
      || isDashboardPerformanceAudit
      || isDashboardT21Audit
      || dashboardSmokeConfiguration != nil
      || isRenderIsolationSmokeTest
  }

  private var dashboardSmokeConfiguration: DashboardSmokeConfiguration? {
    DashboardSmokeConfiguration(arguments: arguments)
  }

  private var isDashboardRuntimeAudit: Bool {
    arguments == ["--dashboard-runtime-audit"]
  }

  private var isDashboardPerformanceAudit: Bool {
    arguments == ["--dashboard-performance-audit"]
  }

  private var isDashboardT21Audit: Bool {
    arguments == ["--dashboard-t21-audit"]
  }

  private var isRenderIsolationSmokeTest: Bool {
    arguments == ["--render-isolation-smoke-test"]
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
      || isDashboardRuntimeAudit
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
    } else if let configuration = dashboardSmokeConfiguration {
      runDashboardUISmokeTest(configuration)
    } else if isRenderIsolationSmokeTest {
      runRenderIsolationSmokeTest()
    } else if isDashboardPerformanceAudit {
      runDashboardPerformanceAudit()
    } else if isDashboardT21Audit {
      runDashboardT21Audit()
    } else if isDashboardRuntimeAudit {
      runDashboardRuntimeAudit()
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
    endMonitoringActivity()
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
        let now = HistoryUISmokeFixture.minuteAlignedReferenceDate(
          containing: Date()
        )
        try HistoryUISmokeFixture.populate(
          database: database,
          now: now,
          logicalCPUCount: dashboardSmokeConfiguration?.logicalCPUCount ?? 8
        )
        historyReferenceDate = now
      }
      let engine = MemoryMonitoringEngine(database: database) { [weak self] event in
        Task { @MainActor [weak self] in
          self?.handleMonitoringEvent(event)
        }
      }
      try engine.start()
      beginMonitoringActivity()
      self.database = database
      self.engine = engine
      viewModel.updateRunState(engine.state)
      let startedAt = Date()
      historyViewModel.configure(
        database: database,
        initialPeriod: dashboardSmokeConfiguration?.period
          ?? (isHistoryUITest ? .threeDays : .twentyFourHours),
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
        || isDashboardRuntimeAudit
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
    let requestedSize =
      dashboardSmokeConfiguration.map {
        NSSize(width: $0.width, height: $0.height)
      } ?? NSSize(width: 1_080, height: 900)
    let currentHostingView = NSHostingView(
      rootView: CurrentValuesRootView(
        viewModel: viewModel,
        diagnostics: renderDiagnostics
      )
    )
    let historyHostingView = NSHostingView(
      rootView: HistoryRootView(
        viewModel: historyViewModel,
        diagnostics: renderDiagnostics
      )
    )
    let contentView = DashboardContainerView(
      currentView: currentHostingView,
      historyView: historyHostingView
    )
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: requestedSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.center()
    window.contentView = contentView
    window.title = "Memory Watcher"
    if let appearanceName = dashboardSmokeConfiguration?.appearanceName {
      window.appearance = NSAppearance(named: appearanceName)
    }
    window.isReleasedWhenClosed = false
    window.delegate = self
    self.currentHostingView = currentHostingView
    self.historyHostingView = historyHostingView
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
    switch event {
    case .sample(let sample):
      historyViewModel.receiveSample(at: sample.timestampUTC)
      refreshMenuBar()
    case .gap(let gap):
      historyViewModel.receiveSample(at: gap.timestampUTC)
    case .totalCPU, .logicalCPU:
      break
    case .pressure:
      refreshMenuBar()
    case .lifecycle:
      break
    case .failure:
      monitoringFailureCount &+= 1
    }
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
    viewModel.setCurrentValuesVisible(true)
    historyViewModel.setWindowVisible(true)
    NSApplication.shared.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
  }

  private func toggleHistoryWindow() {
    guard !isDashboardT21Audit else {
      dashboardT21InteractionBlockCount &+= 1
      return
    }
    guard let window else {
      return
    }
    if window.isVisible {
      viewModel.setCurrentValuesVisible(false)
      historyViewModel.setWindowVisible(false)
      window.orderOut(nil)
    } else {
      showHistoryWindow()
    }
  }

  func windowWillClose(_ notification: Notification) {
    viewModel.setCurrentValuesVisible(false)
    historyViewModel.setWindowVisible(false)
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
    endMonitoringActivity()
    updateRunState()
  }

  @objc private func workspaceDidWake(_ notification: Notification) {
    guard let engine else {
      return
    }
    beginMonitoringActivity()
    engine.resumeAfterWake()
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

  private func beginMonitoringActivity() {
    guard monitoringActivity == nil else {
      return
    }
    monitoringActivity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "Memory Watcher is recording system history"
    )
  }

  private func endMonitoringActivity() {
    guard let monitoringActivity else {
      return
    }
    ProcessInfo.processInfo.endActivity(monitoringActivity)
    self.monitoringActivity = nil
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
      guard let self else { return }
      self.window?.close()
      let hiddenPublicationCount = self.viewModel.currentValuesPublicationCount
      DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
        guard let self else { return }
        let sampleCount = (try? self.database?.sampleCount()) ?? 0
        let windowVisible = self.window?.isVisible ?? false
        let state = self.engine?.state ?? .stopped
        let hiddenPublicationDelta =
          self.viewModel.currentValuesPublicationCount - hiddenPublicationCount
        let status =
          sampleCount >= 2
            && !windowVisible
            && state == .running
            && hiddenPublicationDelta == 0
          ? "PASS"
          : "FAIL"
        self.writeSmokeResult(
          [
            "hidden_current_value_publication_delta": hiddenPublicationDelta,
            "monitoring_state": state.rawValue,
            "sample_count": sampleCount,
            "status": status,
            "window_visible_after_close": windowVisible,
          ]
        )
        NSApplication.shared.terminate(nil)
      }
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

  private func runDashboardUISmokeTest(
    _ configuration: DashboardSmokeConfiguration
  ) {
    waitForDashboardScreen(
      configuration,
      deadline: Date().addingTimeInterval(8)
    )
  }

  private func runRenderIsolationSmokeTest() {
    #if DEBUG
      waitForRenderIsolationScreen(deadline: Date().addingTimeInterval(8))
    #else
      writeSmokeResult([
        "reason": "render diagnostics are unavailable in Release",
        "status": "FAIL",
      ])
      NSApplication.shared.terminate(nil)
    #endif
  }

  #if DEBUG
    private func waitForRenderIsolationScreen(deadline: Date) {
      guard Date() < deadline else {
        writeSmokeResult([
          "reason": "render-isolation screen did not become ready",
          "status": "FAIL",
        ])
        NSApplication.shared.terminate(nil)
        return
      }
      guard
        let snapshot = historyViewModel.historySnapshot,
        snapshot.period == .threeDays,
        !historyViewModel.historyIsLoading,
        let window,
        let currentHostingView,
        let historyHostingView
      else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          [weak self] in
          self?.waitForRenderIsolationScreen(deadline: deadline)
        }
        return
      }

      window.contentView?.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        guard let self else { return }
        let initialCurrentRootUpdates =
          self.renderDiagnostics.currentRootUpdateCount
        let initialHistoryRootUpdates =
          self.renderDiagnostics.historyRootUpdateCount
        let initialPublications = self.viewModel.currentValuesPublicationCount
        let initialHistoryLoads = self.historyViewModel.historyLoadRequestCount
        let initialHistoryGeneration = self.historyViewModel.historyGeneration
        let initialFingerprint = DashboardHistoryInputFingerprint(
          snapshot: snapshot
        )

        for _ in 0..<120 {
          self.viewModel.publishCurrentValuesForRenderIsolationTest()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
          [weak self] in
          guard let self else { return }
          let finalSnapshot = self.historyViewModel.historySnapshot
          let finalFingerprint = finalSnapshot.map(
            DashboardHistoryInputFingerprint.init(snapshot:)
          )
          let currentRootUpdateDelta =
            self.renderDiagnostics.currentRootUpdateCount
            - initialCurrentRootUpdates
          let historyRootUpdateDelta =
            self.renderDiagnostics.historyRootUpdateCount
            - initialHistoryRootUpdates
          let publicationDelta =
            self.viewModel.currentValuesPublicationCount
            - initialPublications
          let historyLoadDelta =
            self.historyViewModel.historyLoadRequestCount
            - initialHistoryLoads
          let historyGenerationUnchanged =
            self.historyViewModel.historyGeneration
            == initialHistoryGeneration
          let windowCount = NSApplication.shared.windows.filter {
            $0.title == "Memory Watcher" && $0.styleMask.contains(.titled)
          }.count
          let hostIdentityStable =
            self.currentHostingView === currentHostingView
            && self.historyHostingView === historyHostingView
          let status =
            publicationDelta >= 120
              && currentRootUpdateDelta > 0
              && historyRootUpdateDelta == 0
              && historyLoadDelta == 0
              && historyGenerationUnchanged
              && finalFingerprint == initialFingerprint
              && hostIdentityStable
              && windowCount == 1
              && self.engine?.state == .running
            ? "PASS"
            : "FAIL"
          self.writeSmokeResult([
            "current_publication_delta": publicationDelta,
            "current_root_update_delta": currentRootUpdateDelta,
            "history_fingerprint_unchanged":
              finalFingerprint == initialFingerprint,
            "history_generation_unchanged": historyGenerationUnchanged,
            "history_load_delta": historyLoadDelta,
            "history_root_update_delta": historyRootUpdateDelta,
            "host_identity_stable": hostIdentityStable,
            "monitoring_state": self.engine?.state.rawValue ?? "stopped",
            "status": status,
            "window_count": windowCount,
          ])
          NSApplication.shared.terminate(nil)
        }
      }
    }
  #endif

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
      var buttonActionsDispatched = true
      var openedFromMenuBar = false
      for index in 0..<20 {
        buttonActionsDispatched =
          menuBarController.performStatusButtonClickForTesting()
          && buttonActionsDispatched
        if index == 0 {
          openedFromMenuBar = window.isVisible
        }
      }
      let closedFromMenuBar = !window.isVisible
      let historyWindowCount = NSApplication.shared.windows.filter {
        $0.title == "Memory Watcher" && $0.styleMask.contains(.titled)
      }.count
      let statusTitle = menuBarController.statusTitle
      let renderedUpdateCountBeforeDuplicate =
        menuBarController.renderedUpdateCount
      refreshMenuBar()
      let renderedUpdateCountAfterFirstDuplicate =
        menuBarController.renderedUpdateCount
      refreshMenuBar()
      let duplicateUpdateWasSuppressed =
        menuBarController.renderedUpdateCount
        == renderedUpdateCountAfterFirstDuplicate
      let firstDuplicateDidNotOverRender =
        renderedUpdateCountAfterFirstDuplicate
        - renderedUpdateCountBeforeDuplicate <= 1
      let status =
        NSApplication.shared.activationPolicy() == .accessory
          && menuBarController.isInstalled
          && menuBarController.hasRequiredCommands
          && buttonActionsDispatched
          && initiallyHidden
          && openedFromMenuBar
          && closedFromMenuBar
          && historyWindowCount == 1
          && statusTitle.hasSuffix(" GB")
          && !statusTitle.contains("—")
          && duplicateUpdateWasSuppressed
          && firstDuplicateDidNotOverRender
          && self.engine?.state == .running
        ? "PASS"
        : "FAIL"
      self.writeSmokeResult([
        "activation_policy": "accessory",
        "button_action_dispatched": buttonActionsDispatched,
        "closed_from_menu_bar": closedFromMenuBar,
        "history_window_count": historyWindowCount,
        "initially_hidden": initiallyHidden,
        "menu_commands_present": menuBarController.hasRequiredCommands,
        "duplicate_update_suppressed": duplicateUpdateWasSuppressed,
        "monitoring_state": self.engine?.state.rawValue ?? "stopped",
        "opened_from_menu_bar": openedFromMenuBar,
        "status": status,
        "status_item_installed": menuBarController.isInstalled,
        "status_title": statusTitle,
      ])
      NSApplication.shared.terminate(nil)
    }
  }

  private func runDashboardRuntimeAudit() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, let database = self.database else { return }
      let startedAt = Date()
      let initialSampleCount = (try? database.sampleCount()) ?? -1
      let initialMemoryGapCount = (try? database.samplingGapCount()) ?? -1
      let initialHistoryLoadCount =
        self.historyViewModel.historyLoadRequestCount
      self.writeSmokeResult([
        "event": "runtime-audit-start",
        "history_load_count": initialHistoryLoadCount,
        "memory_gap_count": initialMemoryGapCount,
        "monitoring_failure_count": self.monitoringFailureCount,
        "process_id": ProcessInfo.processInfo.processIdentifier,
        "sample_count": initialSampleCount,
      ])

      DispatchQueue.main.asyncAfter(deadline: .now() + 15 * 60) { [weak self] in
        guard let self, let database = self.database, let window = self.window
        else { return }
        let hiddenAt = Date()
        let hiddenStartSampleCount = (try? database.sampleCount()) ?? -1
        let hiddenStartMemoryGapCount =
          (try? database.samplingGapCount()) ?? -1
        self.viewModel.setCurrentValuesVisible(false)
        self.historyViewModel.setWindowVisible(false)
        window.orderOut(nil)
        let historyLoadCountAtHide =
          self.historyViewModel.historyLoadRequestCount
        self.writeSmokeResult([
          "event": "runtime-audit-hidden",
          "history_load_count": historyLoadCountAtHide,
          "memory_gap_count": hiddenStartMemoryGapCount,
          "sample_count": hiddenStartSampleCount,
          "visible_seconds": hiddenAt.timeIntervalSince(startedAt),
          "window_visible": window.isVisible,
        ])

        let context = DashboardRuntimeAuditContext(
          startedAt: startedAt,
          initialSampleCount: initialSampleCount,
          initialMemoryGapCount: initialMemoryGapCount,
          initialMonitoringFailureCount: self.monitoringFailureCount,
          initialHistoryLoadCount: initialHistoryLoadCount,
          hiddenAt: hiddenAt,
          hiddenStartSampleCount: hiddenStartSampleCount,
          hiddenStartMemoryGapCount: hiddenStartMemoryGapCount,
          historyLoadCountAtHide: historyLoadCountAtHide
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 15 * 60) {
          [weak self] in
          self?.finishDashboardRuntimeAuditHiddenPeriod(context)
        }
      }
    }
  }

  private func runDashboardPerformanceAudit() {
    waitForDashboardPerformanceAuditReady(
      deadline: Date().addingTimeInterval(10)
    )
  }

  private func runDashboardT21Audit() {
    waitForDashboardT21AuditReady(deadline: Date().addingTimeInterval(10))
  }

  private func waitForDashboardT21AuditReady(deadline: Date) {
    guard Date() < deadline else {
      writeSmokeResult([
        "event": "t21-audit-start",
        "reason": "three-day history did not become ready",
        "status": "FAIL",
      ])
      NSApplication.shared.terminate(nil)
      return
    }
    guard
      let window,
      window.isVisible,
      !historyViewModel.historyIsLoading,
      historyViewModel.historySnapshot?.period == .threeDays
    else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.waitForDashboardT21AuditReady(deadline: deadline)
      }
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
      self?.beginDashboardT21VisiblePhase()
    }
  }

  private func beginDashboardT21VisiblePhase() {
    guard let context = makeDashboardT21Context(phase: "visible") else {
      return
    }
    writeDashboardT21Checkpoint(context: context, minute: 0)
    scheduleDashboardT21Checkpoint(context: context, minute: 5)
  }

  private func scheduleDashboardT21Checkpoint(
    context: DashboardT21AuditContext,
    minute: Int
  ) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 5 * 60) { [weak self] in
      guard let self else { return }
      self.writeDashboardT21Checkpoint(context: context, minute: minute)
      if minute < 15 {
        self.scheduleDashboardT21Checkpoint(
          context: context,
          minute: minute + 5
        )
      } else if context.phase == "visible" {
        self.waitToBeginDashboardT21HiddenPhase(
          visibleContext: context,
          deadline: Date().addingTimeInterval(10)
        )
      } else {
        self.finishDashboardT21Audit(hiddenContext: context)
      }
    }
  }

  private func waitToBeginDashboardT21HiddenPhase(
    visibleContext: DashboardT21AuditContext,
    deadline: Date
  ) {
    guard Date() < deadline else {
      writeSmokeResult([
        "event": "t21-visible-finished",
        "reason": "scheduled history reload did not finish",
        "status": "FAIL",
      ])
      return
    }
    guard !historyViewModel.historyIsLoading else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.waitToBeginDashboardT21HiddenPhase(
          visibleContext: visibleContext,
          deadline: deadline
        )
      }
      return
    }
    guard let window else { return }
    viewModel.setCurrentValuesVisible(false)
    historyViewModel.setWindowVisible(false)
    window.orderOut(nil)
    writeDashboardT21PhaseResult(context: visibleContext)
    let historyLoadCountAfterHide = historyViewModel.historyLoadRequestCount
    let interactionBlockCountBeforeTest = dashboardT21InteractionBlockCount
    menuBarController?.performPrimaryActionForTesting()
    let interactionIsolationPassed =
      !window.isVisible
      && historyViewModel.historyLoadRequestCount == historyLoadCountAfterHide
      && dashboardT21InteractionBlockCount
        == interactionBlockCountBeforeTest + 1
    writeSmokeResult([
      "blocked_interaction_delta":
        dashboardT21InteractionBlockCount - interactionBlockCountBeforeTest,
      "event": "t21-interaction-isolation",
      "history_load_delta":
        historyViewModel.historyLoadRequestCount - historyLoadCountAfterHide,
      "status": interactionIsolationPassed ? "PASS" : "FAIL",
      "window_visible": window.isVisible,
    ])
    guard interactionIsolationPassed else {
      NSApplication.shared.terminate(nil)
      return
    }
    guard let hiddenContext = makeDashboardT21Context(phase: "hidden") else {
      return
    }
    writeDashboardT21Checkpoint(context: hiddenContext, minute: 0)
    scheduleDashboardT21Checkpoint(context: hiddenContext, minute: 5)
  }

  private func finishDashboardT21Audit(
    hiddenContext: DashboardT21AuditContext
  ) {
    guard let database, let window else { return }
    let finishedUptime = ProcessInfo.processInfo.systemUptime
    let elapsedUptime = finishedUptime - hiddenContext.startedUptime
    let finalProcessCPUSeconds = processCPUSeconds()
    let processCPUSecondsDelta = cpuSecondsDelta(
      from: hiddenContext.initialProcessCPUSeconds,
      through: finalProcessCPUSeconds
    )
    let averageCPUPercent = processCPUSecondsDelta.map {
      $0 / elapsedUptime * 100
    }
    let finalSampleCount = (try? database.sampleCount()) ?? -1
    let finalTotalCPUSampleCount =
      (try? database.totalCPUSampleCount()) ?? -1
    let finalHistoryLoadCount = historyViewModel.historyLoadRequestCount
    let finalLogicalCPUGapCount =
      (try? database.logicalCPUSamplingGapCount()) ?? -1
    let historyLoadDelta =
      finalHistoryLoadCount >= hiddenContext.initialHistoryLoadCount
      ? finalHistoryLoadCount - hiddenContext.initialHistoryLoadCount
      : UInt64.max
    let monitoringFailureDelta =
      monitoringFailureCount >= hiddenContext.initialMonitoringFailureCount
      ? monitoringFailureCount - hiddenContext.initialMonitoringFailureCount
      : UInt64.max
    let totalCPUSampleDelta =
      finalTotalCPUSampleCount - hiddenContext.initialTotalCPUSampleCount
    let allMemoryGaps = (try? database.fetchSamplingGaps()) ?? []
    let memoryGapAudit = DashboardMemoryGapAuditEvaluator.evaluate(
      allGaps: allMemoryGaps,
      initialGapCount: hiddenContext.initialMemoryGapCount,
      initialMonitoringFailureCount:
        hiddenContext.initialMonitoringFailureCount,
      finalMonitoringFailureCount: monitoringFailureCount
    )
    let memorySlotDelta =
      DashboardMemoryGapAuditEvaluator.observedSlotCount(
        sampleDelta: finalSampleCount - hiddenContext.initialSampleCount,
        explicitGapCount: memoryGapAudit.explicitGapCount
      )
    let status =
      elapsedUptime >= 15 * 60 - 1
        && averageCPUPercent.map { $0 < 1 } == true
        && memorySlotDelta.map { $0 >= 170 } == true
        && totalCPUSampleDelta >= 170
        && historyLoadDelta == 0
        && memoryGapAudit.isValid
        && finalLogicalCPUGapCount == hiddenContext.initialLogicalCPUGapCount
        && (try? database.integrityCheck()) == "ok"
        && !window.isVisible
      ? "PASS"
      : "FAIL"
    writeSmokeResult([
      "average_cpu_percent": averageCPUPercent ?? NSNull(),
      "event": "t21-audit-finished",
      "history_load_delta": historyLoadDelta,
      "history_reload_reason_counts":
        historyViewModel.historyReloadReasonCountsForAudit,
      "logical_cpu_gap_delta":
        finalLogicalCPUGapCount - hiddenContext.initialLogicalCPUGapCount,
      "memory_gap_delta": memoryGapAudit.explicitGapCount,
      "memory_gap_diagnostics_status":
        memoryGapAudit.isValid ? "PASS" : "FAIL",
      "memory_gap_reason_counts": memoryGapAudit.reasonCounts,
      "memory_slot_delta": memorySlotDelta ?? -1,
      "monitoring_activity_active": monitoringActivity != nil,
      "monitoring_failure_delta": monitoringFailureDelta,
      "process_id": ProcessInfo.processInfo.processIdentifier,
      "process_cpu_seconds_delta": processCPUSecondsDelta ?? NSNull(),
      "sample_delta": finalSampleCount - hiddenContext.initialSampleCount,
      "status": status,
      "system_uptime": finishedUptime,
      "system_uptime_delta": elapsedUptime,
      "total_cpu_sample_delta": totalCPUSampleDelta,
      "window_interaction_block_delta":
        dashboardT21InteractionBlockCount
        - hiddenContext.initialInteractionBlockCount,
      "window_visible": window.isVisible,
    ])
    NSApplication.shared.terminate(nil)
  }

  private func makeDashboardT21Context(
    phase: String
  ) -> DashboardT21AuditContext? {
    guard let database else { return nil }
    return DashboardT21AuditContext(
      phase: phase,
      startedAt: Date(),
      startedUptime: ProcessInfo.processInfo.systemUptime,
      initialProcessCPUSeconds: processCPUSeconds(),
      initialSampleCount: (try? database.sampleCount()) ?? -1,
      initialTotalCPUSampleCount: (try? database.totalCPUSampleCount()) ?? -1,
      initialHistoryLoadCount: historyViewModel.historyLoadRequestCount,
      initialMemoryGapCount: (try? database.samplingGapCount()) ?? -1,
      initialLogicalCPUGapCount: (try? database.logicalCPUSamplingGapCount()) ?? -1,
      initialMonitoringFailureCount: monitoringFailureCount,
      initialInteractionBlockCount: dashboardT21InteractionBlockCount
    )
  }

  private func writeDashboardT21Checkpoint(
    context: DashboardT21AuditContext,
    minute: Int
  ) {
    guard let database, let window else { return }
    writeSmokeResult([
      "event": "t21-\(context.phase)-\(minute)",
      "history_load_count": historyViewModel.historyLoadRequestCount,
      "history_reload_reason_counts":
        historyViewModel.historyReloadReasonCountsForAudit,
      "monitoring_activity_active": monitoringActivity != nil,
      "monitoring_failure_count": monitoringFailureCount,
      "process_id": ProcessInfo.processInfo.processIdentifier,
      "process_cpu_seconds": processCPUSeconds() ?? NSNull(),
      "sample_count": (try? database.sampleCount()) ?? -1,
      "system_uptime": ProcessInfo.processInfo.systemUptime,
      "total_cpu_sample_count":
        (try? database.totalCPUSampleCount()) ?? -1,
      "window_interaction_block_count": dashboardT21InteractionBlockCount,
      "window_visible": window.isVisible,
    ])
  }

  private func writeDashboardT21PhaseResult(
    context: DashboardT21AuditContext
  ) {
    guard let database, let window else { return }
    let finishedUptime = ProcessInfo.processInfo.systemUptime
    let elapsedUptime = finishedUptime - context.startedUptime
    let finalProcessCPUSeconds = processCPUSeconds()
    let processCPUSecondsDelta = cpuSecondsDelta(
      from: context.initialProcessCPUSeconds,
      through: finalProcessCPUSeconds
    )
    let averageCPUPercent = processCPUSecondsDelta.map {
      $0 / elapsedUptime * 100
    }
    let finalHistoryLoadCount = historyViewModel.historyLoadRequestCount
    let historyLoadDelta =
      finalHistoryLoadCount >= context.initialHistoryLoadCount
      ? finalHistoryLoadCount - context.initialHistoryLoadCount
      : UInt64.max
    let sampleDelta =
      ((try? database.sampleCount()) ?? -1) - context.initialSampleCount
    let totalCPUSampleDelta =
      ((try? database.totalCPUSampleCount()) ?? -1)
      - context.initialTotalCPUSampleCount
    let allMemoryGaps = (try? database.fetchSamplingGaps()) ?? []
    let memoryGapAudit = DashboardMemoryGapAuditEvaluator.evaluate(
      allGaps: allMemoryGaps,
      initialGapCount: context.initialMemoryGapCount,
      initialMonitoringFailureCount: context.initialMonitoringFailureCount,
      finalMonitoringFailureCount: monitoringFailureCount
    )
    let memorySlotDelta =
      DashboardMemoryGapAuditEvaluator.observedSlotCount(
        sampleDelta: sampleDelta,
        explicitGapCount: memoryGapAudit.explicitGapCount
      )
    let logicalCPUGapDelta =
      ((try? database.logicalCPUSamplingGapCount()) ?? -1)
      - context.initialLogicalCPUGapCount
    let monitoringFailureDelta =
      monitoringFailureCount >= context.initialMonitoringFailureCount
      ? monitoringFailureCount - context.initialMonitoringFailureCount
      : UInt64.max
    let status =
      elapsedUptime >= 15 * 60 - 1
        && averageCPUPercent.map { $0 < 1 } == true
        && memorySlotDelta.map { $0 >= 170 } == true
        && totalCPUSampleDelta >= 170
        && historyLoadDelta == 3
        && memoryGapAudit.isValid
        && logicalCPUGapDelta == 0
        && !window.isVisible
      ? "PASS"
      : "FAIL"
    writeSmokeResult([
      "average_cpu_percent": averageCPUPercent ?? NSNull(),
      "event": "t21-\(context.phase)-finished",
      "history_load_delta": historyLoadDelta,
      "history_reload_reason_counts":
        historyViewModel.historyReloadReasonCountsForAudit,
      "logical_cpu_gap_delta": logicalCPUGapDelta,
      "memory_gap_delta": memoryGapAudit.explicitGapCount,
      "memory_gap_diagnostics_status":
        memoryGapAudit.isValid ? "PASS" : "FAIL",
      "memory_gap_reason_counts": memoryGapAudit.reasonCounts,
      "memory_slot_delta": memorySlotDelta ?? -1,
      "monitoring_activity_active": monitoringActivity != nil,
      "monitoring_failure_delta": monitoringFailureDelta,
      "process_id": ProcessInfo.processInfo.processIdentifier,
      "process_cpu_seconds_delta": processCPUSecondsDelta ?? NSNull(),
      "sample_delta": sampleDelta,
      "status": status,
      "system_uptime": finishedUptime,
      "system_uptime_delta": elapsedUptime,
      "total_cpu_sample_delta": totalCPUSampleDelta,
      "window_interaction_block_delta":
        dashboardT21InteractionBlockCount
        - context.initialInteractionBlockCount,
      "window_visible": window.isVisible,
    ])
  }

  private func processCPUSeconds() -> TimeInterval? {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else {
      return nil
    }
    let userSeconds =
      TimeInterval(usage.ru_utime.tv_sec)
      + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
    let systemSeconds =
      TimeInterval(usage.ru_stime.tv_sec)
      + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
    return userSeconds + systemSeconds
  }

  private func cpuSecondsDelta(
    from initial: TimeInterval?,
    through final: TimeInterval?
  ) -> TimeInterval? {
    guard let initial, let final, final >= initial else {
      return nil
    }
    return final - initial
  }

  private func waitForDashboardPerformanceAuditReady(deadline: Date) {
    guard Date() < deadline else {
      writeSmokeResult([
        "event": "r8-audit-start",
        "reason": "three-day history did not become ready",
        "status": "FAIL",
      ])
      NSApplication.shared.terminate(nil)
      return
    }
    guard
      let database,
      let window,
      window.isVisible,
      !historyViewModel.historyIsLoading,
      historyViewModel.historySnapshot?.period == .threeDays
    else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.waitForDashboardPerformanceAuditReady(deadline: deadline)
      }
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
      guard let self else { return }
      let context = DashboardPerformanceAuditContext(
        startedAt: Date(),
        startedUptime: ProcessInfo.processInfo.systemUptime,
        initialSampleCount: (try? database.sampleCount()) ?? -1,
        initialHistoryLoadCount: self.historyViewModel.historyLoadRequestCount,
        initialMemoryGapCount: (try? database.samplingGapCount()) ?? -1,
        initialLogicalCPUGapCount: (try? database.logicalCPUSamplingGapCount()) ?? -1
      )
      self.writeSmokeResult([
        "event": "r8-audit-start",
        "history_load_count": context.initialHistoryLoadCount,
        "history_reload_reason_counts":
          self.historyViewModel.historyReloadReasonCountsForAudit,
        "process_id": ProcessInfo.processInfo.processIdentifier,
        "sample_count": context.initialSampleCount,
        "system_uptime": context.startedUptime,
      ])
      DispatchQueue.main.asyncAfter(deadline: .now() + 5 * 60) { [weak self] in
        self?.waitForDashboardPerformanceAuditFinish(
          context,
          deadline: Date().addingTimeInterval(10)
        )
      }
    }
  }

  private func waitForDashboardPerformanceAuditFinish(
    _ context: DashboardPerformanceAuditContext,
    deadline: Date
  ) {
    guard Date() < deadline else {
      writeSmokeResult([
        "event": "r8-audit-finished",
        "reason": "scheduled history reload did not finish",
        "status": "FAIL",
      ])
      return
    }
    guard !historyViewModel.historyIsLoading else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.waitForDashboardPerformanceAuditFinish(
          context,
          deadline: deadline
        )
      }
      return
    }
    guard let database, let window else { return }

    let finishedAt = Date()
    let finishedUptime = ProcessInfo.processInfo.systemUptime
    let finalSampleCount = (try? database.sampleCount()) ?? -1
    let finalHistoryLoadCount = historyViewModel.historyLoadRequestCount
    let finalMemoryGapCount = (try? database.samplingGapCount()) ?? -1
    let finalLogicalCPUGapCount =
      (try? database.logicalCPUSamplingGapCount()) ?? -1
    let historyLoadDelta =
      finalHistoryLoadCount >= context.initialHistoryLoadCount
      ? finalHistoryLoadCount - context.initialHistoryLoadCount
      : UInt64.max
    let status =
      finishedUptime - context.startedUptime >= 5 * 60 - 1
        && finalSampleCount - context.initialSampleCount >= 55
        && historyLoadDelta == 1
        && finalMemoryGapCount == context.initialMemoryGapCount
        && finalLogicalCPUGapCount == context.initialLogicalCPUGapCount
        && (try? database.integrityCheck()) == "ok"
        && window.isVisible
      ? "PASS"
      : "FAIL"
    writeSmokeResult([
      "elapsed_seconds": finishedAt.timeIntervalSince(context.startedAt),
      "event": "r8-audit-finished",
      "history_load_delta": historyLoadDelta,
      "history_reload_reason_counts":
        historyViewModel.historyReloadReasonCountsForAudit,
      "logical_cpu_gap_delta":
        finalLogicalCPUGapCount - context.initialLogicalCPUGapCount,
      "memory_gap_delta": finalMemoryGapCount - context.initialMemoryGapCount,
      "process_id": ProcessInfo.processInfo.processIdentifier,
      "sample_delta": finalSampleCount - context.initialSampleCount,
      "status": status,
      "system_uptime": finishedUptime,
      "system_uptime_delta": finishedUptime - context.startedUptime,
      "window_visible": window.isVisible,
    ])
  }

  private func finishDashboardRuntimeAuditHiddenPeriod(
    _ context: DashboardRuntimeAuditContext
  ) {
    guard let database, let window else { return }
    let hiddenEndedAt = Date()
    let hiddenEndSampleCount = (try? database.sampleCount()) ?? -1
    let historyLoadCountBeforeShow = historyViewModel.historyLoadRequestCount
    showHistoryWindow()
    waitForDashboardRuntimeAuditReadback(
      context,
      hiddenEndedAt: hiddenEndedAt,
      hiddenEndSampleCount: hiddenEndSampleCount,
      historyLoadCountBeforeShow: historyLoadCountBeforeShow,
      deadline: Date().addingTimeInterval(5),
      window: window
    )
  }

  private func waitForDashboardRuntimeAuditReadback(
    _ context: DashboardRuntimeAuditContext,
    hiddenEndedAt: Date,
    hiddenEndSampleCount: Int,
    historyLoadCountBeforeShow: UInt64,
    deadline: Date,
    window: NSWindow
  ) {
    guard Date() < deadline else {
      writeSmokeResult([
        "event": "runtime-audit-finished",
        "reason": "history readback did not finish",
        "status": "FAIL",
      ])
      NSApplication.shared.terminate(nil)
      return
    }
    guard
      !historyViewModel.historyIsLoading,
      let snapshot = historyViewModel.historySnapshot,
      snapshot.period == .twentyFourHours
    else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.waitForDashboardRuntimeAuditReadback(
          context,
          hiddenEndedAt: hiddenEndedAt,
          hiddenEndSampleCount: hiddenEndSampleCount,
          historyLoadCountBeforeShow: historyLoadCountBeforeShow,
          deadline: deadline,
          window: window
        )
      }
      return
    }

    let twentyFourHourReadback = periodReadbackResult(snapshot)
    let historyLoadCountAfterShow = historyViewModel.historyLoadRequestCount
    historyViewModel.selectHistoryPeriod(.twelveHours)
    waitForDashboardRuntimeAuditPeriod(
      context,
      hiddenEndedAt: hiddenEndedAt,
      hiddenEndSampleCount: hiddenEndSampleCount,
      historyLoadCountBeforeShow: historyLoadCountBeforeShow,
      historyLoadCountAfterShow: historyLoadCountAfterShow,
      periodResults: [twentyFourHourReadback],
      expectedPeriod: .twelveHours,
      deadline: Date().addingTimeInterval(5),
      window: window
    )
  }

  private func waitForDashboardRuntimeAuditPeriod(
    _ context: DashboardRuntimeAuditContext,
    hiddenEndedAt: Date,
    hiddenEndSampleCount: Int,
    historyLoadCountBeforeShow: UInt64,
    historyLoadCountAfterShow: UInt64,
    periodResults: [DashboardPeriodReadbackResult],
    expectedPeriod: MemoryHistoryPeriod,
    deadline: Date,
    window: NSWindow
  ) {
    guard Date() < deadline else {
      writeSmokeResult([
        "event": "runtime-audit-finished",
        "period": expectedPeriod.rawValue,
        "reason": "period readback did not finish",
        "status": "FAIL",
      ])
      NSApplication.shared.terminate(nil)
      return
    }
    guard
      !historyViewModel.historyIsLoading,
      let snapshot = historyViewModel.historySnapshot,
      snapshot.period == expectedPeriod
    else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.waitForDashboardRuntimeAuditPeriod(
          context,
          hiddenEndedAt: hiddenEndedAt,
          hiddenEndSampleCount: hiddenEndSampleCount,
          historyLoadCountBeforeShow: historyLoadCountBeforeShow,
          historyLoadCountAfterShow: historyLoadCountAfterShow,
          periodResults: periodResults,
          expectedPeriod: expectedPeriod,
          deadline: deadline,
          window: window
        )
      }
      return
    }

    let results = periodResults + [periodReadbackResult(snapshot)]
    if expectedPeriod == .twelveHours {
      historyViewModel.selectHistoryPeriod(.threeDays)
      waitForDashboardRuntimeAuditPeriod(
        context,
        hiddenEndedAt: hiddenEndedAt,
        hiddenEndSampleCount: hiddenEndSampleCount,
        historyLoadCountBeforeShow: historyLoadCountBeforeShow,
        historyLoadCountAfterShow: historyLoadCountAfterShow,
        periodResults: results,
        expectedPeriod: .threeDays,
        deadline: Date().addingTimeInterval(5),
        window: window
      )
      return
    }

    finishDashboardRuntimeAudit(
      context,
      hiddenEndedAt: hiddenEndedAt,
      hiddenEndSampleCount: hiddenEndSampleCount,
      historyLoadCountBeforeShow: historyLoadCountBeforeShow,
      historyLoadCountAfterShow: historyLoadCountAfterShow,
      periodResults: results,
      window: window
    )
  }

  private func finishDashboardRuntimeAudit(
    _ context: DashboardRuntimeAuditContext,
    hiddenEndedAt: Date,
    hiddenEndSampleCount: Int,
    historyLoadCountBeforeShow: UInt64,
    historyLoadCountAfterShow: UInt64,
    periodResults: [DashboardPeriodReadbackResult],
    window: NSWindow
  ) {
    guard let database else { return }

    let finalHistoryLoadCount = historyViewModel.historyLoadRequestCount
    let visibleSampleDelta =
      context.hiddenStartSampleCount - context.initialSampleCount
    let hiddenSampleDelta = hiddenEndSampleCount - context.hiddenStartSampleCount
    let hiddenHistoryLoadDelta =
      historyLoadCountBeforeShow >= context.historyLoadCountAtHide
      ? historyLoadCountBeforeShow - context.historyLoadCountAtHide
      : UInt64.max
    let readbackLoadDelta =
      historyLoadCountAfterShow >= historyLoadCountBeforeShow
      ? historyLoadCountAfterShow - historyLoadCountBeforeShow
      : UInt64.max
    let integrity = (try? database.integrityCheck()) ?? "unavailable"
    let allMemoryGaps = (try? database.fetchSamplingGaps()) ?? []
    let memoryGapAudit = DashboardMemoryGapAuditEvaluator.evaluate(
      allGaps: allMemoryGaps,
      initialGapCount: context.initialMemoryGapCount,
      initialMonitoringFailureCount: context.initialMonitoringFailureCount,
      finalMonitoringFailureCount: monitoringFailureCount
    )
    let visibleGapDelta =
      context.hiddenStartMemoryGapCount >= context.initialMemoryGapCount
      ? context.hiddenStartMemoryGapCount - context.initialMemoryGapCount
      : -1
    let hiddenGapDelta =
      allMemoryGaps.count >= context.hiddenStartMemoryGapCount
      ? allMemoryGaps.count - context.hiddenStartMemoryGapCount
      : -1
    let visibleMemorySlotDelta =
      DashboardMemoryGapAuditEvaluator.observedSlotCount(
        sampleDelta: visibleSampleDelta,
        explicitGapCount: visibleGapDelta
      )
    let hiddenMemorySlotDelta =
      DashboardMemoryGapAuditEvaluator.observedSlotCount(
        sampleDelta: hiddenSampleDelta,
        explicitGapCount: hiddenGapDelta
      )
    let logicalCPUGapCount =
      (try? database.logicalCPUSamplingGapCount()) ?? -1
    let status =
      context.hiddenAt.timeIntervalSince(context.startedAt) >= 15 * 60 - 1
        && hiddenEndedAt.timeIntervalSince(context.hiddenAt) >= 15 * 60 - 1
        && context.initialSampleCount >= 0
        && context.hiddenStartSampleCount >= 0
        && hiddenEndSampleCount >= 0
        && visibleMemorySlotDelta.map { $0 >= 170 } == true
        && hiddenMemorySlotDelta.map { $0 >= 170 } == true
        && hiddenHistoryLoadDelta == 0
        && readbackLoadDelta == 1
        && memoryGapAudit.isValid
        && logicalCPUGapCount == 0
        && integrity == "ok"
        && window.isVisible
        && periodResults.count == 3
        && periodResults.allSatisfy(\.isValid)
      ? "PASS"
      : "FAIL"
    writeSmokeResult([
      "event": "runtime-audit-finished",
      "final_history_load_count": finalHistoryLoadCount,
      "hidden_history_load_delta": hiddenHistoryLoadDelta,
      "hidden_memory_gap_delta": hiddenGapDelta,
      "hidden_memory_slot_delta": hiddenMemorySlotDelta ?? -1,
      "hidden_sample_delta": hiddenSampleDelta,
      "hidden_seconds": hiddenEndedAt.timeIntervalSince(context.hiddenAt),
      "initial_history_load_count": context.initialHistoryLoadCount,
      "integrity_check": integrity,
      "logical_cpu_gap_count": logicalCPUGapCount,
      "memory_gap_count": allMemoryGaps.count,
      "memory_gap_delta": memoryGapAudit.explicitGapCount,
      "memory_gap_diagnostics_status":
        memoryGapAudit.isValid ? "PASS" : "FAIL",
      "memory_gap_reason_counts": memoryGapAudit.reasonCounts,
      "monitoring_failure_delta":
        memoryGapAudit.monitoringFailureDelta ?? UInt64.max,
      "period_readbacks": periodResults.map(\.jsonValue),
      "readback_load_delta": readbackLoadDelta,
      "status": status,
      "visible_sample_delta": visibleSampleDelta,
      "visible_memory_gap_delta": visibleGapDelta,
      "visible_memory_slot_delta": visibleMemorySlotDelta ?? -1,
      "visible_seconds": context.hiddenAt.timeIntervalSince(context.startedAt),
      "window_visible_after_readback": window.isVisible,
    ])
    NSApplication.shared.terminate(nil)
  }

  private func periodReadbackResult(
    _ snapshot: MemoryHistorySnapshot
  ) -> DashboardPeriodReadbackResult {
    if snapshot.period == .threeDays {
      let empty =
        snapshot.points.isEmpty
        && snapshot.cpuHistory.totalPoints.isEmpty
        && snapshot.cpuHistory.logicalPoints.isEmpty
      return DashboardPeriodReadbackResult(
        period: snapshot.period,
        memoryPointCount: snapshot.points.count,
        totalCPUPointCount: snapshot.cpuHistory.totalPoints.count,
        logicalCPUPointCount: snapshot.cpuHistory.logicalPoints.count,
        matchedSelectionCount: 0,
        isValid: empty
      )
    }

    let totalPoints = snapshot.cpuHistory.totalPoints
    guard totalPoints.count >= 3 else {
      return DashboardPeriodReadbackResult(
        period: snapshot.period,
        memoryPointCount: snapshot.points.count,
        totalCPUPointCount: totalPoints.count,
        logicalCPUPointCount: snapshot.cpuHistory.logicalPoints.count,
        matchedSelectionCount: 0,
        isValid: false
      )
    }

    let representativeSelections = representativeDashboardReadbackSelections(
      snapshot
    ).filter { $0.memory?.source == .raw }
    let matchedSelectionCount = representativeSelections.count
    let sourcesAreRaw =
      Set(snapshot.points.map(\.source)) == [.raw]
      && Set(totalPoints.map(\.source)) == [.raw]
      && Set(snapshot.cpuHistory.logicalPoints.map(\.source)) == [.raw]
    return DashboardPeriodReadbackResult(
      period: snapshot.period,
      memoryPointCount: snapshot.points.count,
      totalCPUPointCount: totalPoints.count,
      logicalCPUPointCount: snapshot.cpuHistory.logicalPoints.count,
      matchedSelectionCount: matchedSelectionCount,
      isValid: matchedSelectionCount == 3 && sourcesAreRaw
    )
  }

  private func logicalCPUReadbackIsComplete(
    _ points: [LogicalCPUHistoryPoint]
  ) -> Bool {
    guard let topology = points.first?.topology else {
      return false
    }
    return points.count == topology.logicalCPUCount
      && Set(points.map(\.cpuIndex)).count == topology.logicalCPUCount
      && points.allSatisfy { $0.topology.epochKey == topology.epochKey }
  }

  private func representativeDashboardReadbackSelections(
    _ snapshot: MemoryHistorySnapshot
  ) -> [DashboardHistorySelection] {
    guard !snapshot.points.isEmpty else {
      return []
    }
    let targetIndices = [
      0,
      snapshot.points.count / 2,
      snapshot.points.count - 1,
    ]
    var selectedDates = Set<Date>()
    return targetIndices.compactMap { targetIndex in
      for distance in 0..<snapshot.points.count {
        let candidateIndices = [targetIndex - distance, targetIndex + distance]
        for candidateIndex in candidateIndices
        where snapshot.points.indices.contains(candidateIndex) {
          let memoryPoint = snapshot.points[candidateIndex]
          guard
            let selection = dashboardReadbackSelection(
              snapshot: snapshot,
              memoryPoint: memoryPoint
            ),
            selectedDates.insert(selection.requestedUTC).inserted
          else {
            continue
          }
          return selection
        }
      }
      return nil
    }
  }

  private func dashboardReadbackSelection(
    snapshot: MemoryHistorySnapshot,
    memoryPoint: MemoryHistoryPoint
  ) -> DashboardHistorySelection? {
    let selectedUTC: Date
    switch memoryPoint.source {
    case .raw:
      selectedUTC = memoryPoint.timestampUTC
    case .oneMinute, .fiveMinutes:
      selectedUTC = memoryPoint.intervalStartUTC.addingTimeInterval(
        memoryPoint.intervalEndUTC.timeIntervalSince(
          memoryPoint.intervalStartUTC
        ) / 2
      )
    }
    let selection = DashboardHistorySelectionResolver.resolve(
      snapshot: snapshot,
      at: selectedUTC
    )
    guard
      selection.memory == memoryPoint,
      selection.totalCPU != nil,
      logicalCPUReadbackIsComplete(selection.logicalCPUs)
    else {
      return nil
    }
    return selection
  }

  private func waitForDashboardScreen(
    _ configuration: DashboardSmokeConfiguration,
    deadline: Date
  ) {
    guard Date() < deadline else {
      writeSmokeResult([
        "reason": "unified dashboard did not become ready",
        "status": "FAIL",
      ])
      NSApplication.shared.terminate(nil)
      return
    }
    guard
      let snapshot = historyViewModel.historySnapshot,
      snapshot.period == configuration.period,
      !historyViewModel.historyIsLoading,
      let loadDuration = historyViewModel.historyLoadDurationSeconds,
      let startedAt = historyScreenStartedAt,
      let window
    else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.waitForDashboardScreen(configuration, deadline: deadline)
      }
      return
    }

    let selectedUTC = representativeDashboardReadbackSelections(snapshot)
      .last?.requestedUTC
    historyViewModel.selectTimestamp(selectedUTC)
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      guard let self else { return }
      let readyDuration = Date().timeIntervalSince(startedAt)
      let expectedSource: MemoryHistoryPointSource =
        configuration.period == .threeDays ? .oneMinute : .raw
      let minimumPointCount =
        configuration.period == .threeDays ? 4_000 : 600
      let logicalIndices = Set(snapshot.cpuHistory.logicalPoints.map(\.cpuIndex))
      let selection = self.historyViewModel.selectedDetails
      let windowCount = NSApplication.shared.windows.filter {
        $0.title == "Memory Watcher" && $0.styleMask.contains(.titled)
      }.count
      let selectionMatches =
        selection?.memory != nil
        && selection?.totalCPU != nil
        && selection?.logicalCPUs.count == configuration.logicalCPUCount
      let status =
        snapshot.points.count >= minimumPointCount
          && snapshot.cpuHistory.totalPoints.count >= minimumPointCount
          && logicalIndices.count == configuration.logicalCPUCount
          && Set(snapshot.points.map(\.source)) == Set([expectedSource])
          && Set(snapshot.cpuHistory.totalPoints.map(\.source))
            == Set([expectedSource])
          && loadDuration < 2
          && readyDuration < 2
          && window.isVisible
          && windowCount == 1
          && selectionMatches
        ? "PASS"
        : "FAIL"
      self.writeSmokeResult([
        "appearance": configuration.appearanceName.rawValue,
        "history_load_seconds": loadDuration,
        "history_point_count": snapshot.points.count,
        "history_source": snapshot.points.first?.source.rawValue ?? "NONE",
        "history_window_count": windowCount,
        "layout_mode": DashboardLayoutPolicy.mode(
          forAvailableWidth: Double(window.contentLayoutRect.width)
        ).rawValue,
        "logical_cpu_count": logicalIndices.count,
        "logical_cpu_point_count": snapshot.cpuHistory.logicalPoints.count,
        "period": configuration.period.rawValue,
        "screen_ready_seconds": readyDuration,
        "selection_matches": selectionMatches,
        "status": status,
        "total_cpu_point_count": snapshot.cpuHistory.totalPoints.count,
        "visible": window.isVisible,
        "window_height": window.contentLayoutRect.height,
        "window_width": window.contentLayoutRect.width,
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
      let snapshot = historyViewModel.historySnapshot,
      snapshot.period == .threeDays,
      !historyViewModel.historyIsLoading,
      let loadDuration = historyViewModel.historyLoadDurationSeconds,
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
