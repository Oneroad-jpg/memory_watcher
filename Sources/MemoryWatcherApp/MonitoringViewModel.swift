import Foundation
import MemoryWatcherCore

@MainActor
final class MonitoringViewModel: ObservableObject {
  @Published private(set) var runState: MemoryMonitoringRunState = .stopped
  private(set) var sampleCount = 0
  private(set) var gapCount = 0
  private(set) var lastMemoryUsedBytes: UInt64?
  private(set) var pressureLevel: MemoryPressureLevel = .unknown
  private(set) var lastLifecycleKind: SystemLifecycleEventKind?
  @Published private(set) var loginItemStatus: LoginItemRegistrationStatus
  @Published private(set) var errorMessage: String?
  @Published private(set) var currentValuesRevision: UInt64 = 0
  @Published private(set) var currentValuesAreVisible = false
  private(set) var currentValuesPublicationCount: UInt64 = 0

  private let loginItemManager: LoginItemManager
  private var memoryTracker = DashboardMemoryTracker()
  private var totalCPUTracker = DashboardCPUTracker()
  private var logicalCPUTrackers: [Int: DashboardCPUTracker] = [:]
  private var logicalCPUTopology: LogicalCPUTopology?
  private var currentValuesPublicationIsScheduled = false

  init(loginItemManager: LoginItemManager = LoginItemManager()) {
    self.loginItemManager = loginItemManager
    loginItemStatus = loginItemManager.status
  }

  var loginItemIsRegistered: Bool {
    loginItemStatus == .enabled || loginItemStatus == .requiresApproval
  }

  func updateRunState(_ state: MemoryMonitoringRunState) {
    runState = state
  }

  func setCurrentValuesVisible(_ visible: Bool) {
    guard currentValuesAreVisible != visible else { return }
    currentValuesAreVisible = visible
    if visible {
      scheduleCurrentValuesPublication()
    }
  }

  func receive(_ event: MemoryMonitoringEvent) {
    switch event {
    case .sample(let sample):
      sampleCount += 1
      lastMemoryUsedBytes = sample.estimatedMemoryUsedBytes
      memoryTracker.receive(sample)
      scheduleCurrentValuesPublication()
    case .totalCPU(let sample):
      totalCPUTracker.receive(sample)
      scheduleCurrentValuesPublication()
    case .logicalCPU(let outcome):
      switch outcome {
      case .samples(let samples):
        if let topology = samples.first?.topology,
          topology != logicalCPUTopology
        {
          logicalCPUTrackers = [:]
          logicalCPUTopology = topology
        }
        for sample in samples {
          var tracker =
            logicalCPUTrackers[sample.cpuIndex]
            ?? DashboardCPUTracker()
          tracker.receive(sample)
          logicalCPUTrackers[sample.cpuIndex] = tracker
        }
        scheduleCurrentValuesPublication()
      case .gap(let gap):
        for index in Array(logicalCPUTrackers.keys) {
          guard var tracker = logicalCPUTrackers[index] else { continue }
          tracker.receive(
            percent: nil,
            intervalStartUTC: nil,
            intervalEndUTC: gap.timestampUTC,
            quality: gap.quality
          )
          logicalCPUTrackers[index] = tracker
        }
        scheduleCurrentValuesPublication()
      }
    case .gap:
      gapCount += 1
    case .pressure(let observation):
      pressureLevel = observation.level
      scheduleCurrentValuesPublication()
    case .lifecycle(let event):
      lastLifecycleKind = event.kind
      scheduleCurrentValuesPublication()
    case .failure(let message):
      errorMessage = message
    }
  }

  func currentMemory(at now: Date) -> DashboardMemoryPresentation {
    memoryTracker.presentation(at: now, runState: runState)
  }

  func currentTotalCPU(at now: Date) -> DashboardCPUPresentation {
    totalCPUTracker.presentation(at: now, runState: runState)
  }

  func currentLogicalCPUs(
    at now: Date
  ) -> [DashboardLogicalCPUPresentation] {
    guard let logicalCPUTopology else { return [] }
    return logicalCPUTrackers.keys.sorted().compactMap { index in
      guard let tracker = logicalCPUTrackers[index] else { return nil }
      return DashboardLogicalCPUPresentation(
        topology: logicalCPUTopology,
        cpuIndex: index,
        value: tracker.presentation(at: now, runState: runState)
      )
    }
  }

  func setLoginItemEnabled(_ enabled: Bool) {
    do {
      loginItemStatus = try loginItemManager.setEnabled(enabled)
      errorMessage = nil
    } catch {
      loginItemStatus = loginItemManager.status
      errorMessage = String(describing: error)
    }
  }

  func refreshLoginItemStatus() {
    loginItemStatus = loginItemManager.status
  }

  func openLoginItemSettings() {
    loginItemManager.openSystemSettings()
  }

  func reportStartupFailure(_ error: Error) {
    errorMessage = String(describing: error)
    runState = .stopped
  }

  private func scheduleCurrentValuesPublication() {
    guard currentValuesAreVisible, !currentValuesPublicationIsScheduled else {
      return
    }
    currentValuesPublicationIsScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      guard let self else { return }
      self.currentValuesPublicationIsScheduled = false
      guard self.currentValuesAreVisible else { return }
      self.currentValuesRevision &+= 1
      self.currentValuesPublicationCount &+= 1
    }
  }

  #if DEBUG
    func publishCurrentValuesForRenderIsolationTest() {
      guard currentValuesAreVisible else { return }
      currentValuesRevision &+= 1
      currentValuesPublicationCount &+= 1
    }
  #endif
}

@MainActor
final class HistoryViewModel: ObservableObject {
  enum ReloadReason: String, CaseIterable {
    case automatic
    case configure
    case manual
    case periodSelection
    case windowVisible
  }

  @Published private(set) var historyPeriod: MemoryHistoryPeriod =
    .twentyFourHours
  @Published private(set) var historySnapshot: MemoryHistorySnapshot?
  @Published private(set) var historyRenderSnapshot: DashboardHistoryRenderSnapshot?
  @Published private(set) var historyIsLoading = false
  @Published private(set) var historyLoadDurationSeconds: TimeInterval?
  @Published private(set) var historyErrorMessage: String?
  @Published private(set) var selectedUTC: Date?
  @Published private(set) var historyGeneration: UInt64 = 0
  @Published private(set) var historyLoadRequestCount: UInt64 = 0
  private(set) var historyReloadReasonCounts: [ReloadReason: UInt64] = [:]

  private let refreshPolicy = MemoryHistoryRefreshPolicy()
  private var historyLoader: MemoryHistoryLoader?
  private var historyLoadTask: Task<Void, Never>?
  private var lastReloadAt: Date?
  private var windowIsVisible = false
  private var generationGate = DashboardHistoryGenerationGate()

  func configure(
    database: MemoryWatcherDatabase,
    initialPeriod: MemoryHistoryPeriod = .twentyFourHours,
    now: Date = Date()
  ) {
    historyLoader = MemoryHistoryLoader(database: database)
    historyPeriod = initialPeriod
    historySnapshot = nil
    historyRenderSnapshot = nil
    selectedUTC = nil
    lastReloadAt = nil
    if windowIsVisible {
      reloadHistory(now: now, reason: .configure)
    }
  }

  func setWindowVisible(_ visible: Bool, now: Date = Date()) {
    windowIsVisible = visible
    guard visible else {
      historyLoadTask?.cancel()
      historyLoadTask = nil
      historySnapshot = nil
      historyRenderSnapshot = nil
      selectedUTC = nil
      historyIsLoading = false
      lastReloadAt = nil
      return
    }
    if historyRenderSnapshot != nil,
      let lastReloadAt,
      now.timeIntervalSince(lastReloadAt) < 15
    {
      return
    }
    reloadHistory(now: now, reason: .windowVisible)
  }

  func receiveSample(at now: Date) {
    guard
      refreshPolicy.shouldAutomaticallyReload(
        period: historyPeriod,
        isWindowVisible: windowIsVisible,
        isLoading: historyIsLoading,
        lastReloadAt: lastReloadAt,
        now: now
      )
    else {
      return
    }
    reloadHistory(now: now, reason: .automatic)
  }

  func selectHistoryPeriod(
    _ period: MemoryHistoryPeriod,
    now: Date = Date()
  ) {
    guard period != historyPeriod || historySnapshot == nil else {
      return
    }
    historyPeriod = period
    selectedUTC = nil
    reloadHistory(now: now, reason: .periodSelection)
  }

  func reloadHistory(
    now: Date = Date(),
    reason: ReloadReason = .manual
  ) {
    guard let historyLoader else {
      return
    }
    historyLoadTask?.cancel()
    let period = historyPeriod
    let generation = generationGate.issue()
    historyGeneration = generation
    historyLoadRequestCount &+= 1
    historyReloadReasonCounts[reason, default: 0] &+= 1
    historyIsLoading = true
    historyErrorMessage = nil
    historyLoadTask = Task { [weak self] in
      do {
        let loaded = try await Task.detached(priority: .userInitiated) {
          let startedAt = Date()
          let snapshot = try historyLoader.load(period: period, now: now)
          let renderSnapshot = DashboardHistoryRenderSnapshot(
            snapshot: snapshot
          )
          return (
            snapshot,
            renderSnapshot,
            Date().timeIntervalSince(startedAt)
          )
        }.value
        try Task.checkCancellation()
        guard
          let self,
          self.historyPeriod == period,
          self.generationGate.accepts(generation)
        else {
          return
        }
        self.historySnapshot = loaded.0
        self.historyRenderSnapshot = loaded.1
        self.historyLoadDurationSeconds = loaded.2
        self.historyIsLoading = false
        self.lastReloadAt = now
        self.historyLoadTask = nil
      } catch is CancellationError {
        self?.historyLoadTask = nil
        return
      } catch {
        guard let self, self.generationGate.accepts(generation) else {
          return
        }
        self.historyErrorMessage = String(describing: error)
        self.historyIsLoading = false
        self.historyLoadTask = nil
      }
    }
  }

  var historyReloadReasonCountsForAudit: [String: UInt64] {
    Dictionary(
      uniqueKeysWithValues: ReloadReason.allCases.map { reason in
        (reason.rawValue, historyReloadReasonCounts[reason, default: 0])
      }
    )
  }

  func selectTimestamp(_ date: Date?) {
    selectedUTC = date
  }

  var selectedDetails: DashboardHistorySelection? {
    guard let snapshot = historySnapshot else { return nil }
    let target =
      selectedUTC
      ?? snapshot.cpuHistory.totalPoints.last?.timestampUTC
      ?? snapshot.points.last?.timestampUTC
    guard let target else { return nil }
    return DashboardHistorySelectionResolver.resolve(
      snapshot: snapshot,
      at: target
    )
  }

  func nearestHistoryPoint(to date: Date) -> MemoryHistoryPoint? {
    guard let historySnapshot else { return nil }
    return DashboardHistorySelectionResolver.resolve(
      snapshot: historySnapshot,
      at: date
    ).memory
  }

  func nearestTotalCPUPoint(to date: Date) -> TotalCPUHistoryPoint? {
    guard let historySnapshot else { return nil }
    return DashboardHistorySelectionResolver.resolve(
      snapshot: historySnapshot,
      at: date
    ).totalCPU
  }

  func nearestLogicalCPUPoints(to date: Date) -> [LogicalCPUHistoryPoint] {
    guard let historySnapshot else { return [] }
    return DashboardHistorySelectionResolver.resolve(
      snapshot: historySnapshot,
      at: date
    ).logicalCPUs
  }
}
