import Foundation
import MemoryWatcherCore

@MainActor
final class MonitoringViewModel: ObservableObject {
  @Published private(set) var runState: MemoryMonitoringRunState = .stopped
  @Published private(set) var sampleCount = 0
  @Published private(set) var gapCount = 0
  @Published private(set) var lastMemoryUsedBytes: UInt64?
  @Published private(set) var pressureLevel: MemoryPressureLevel = .unknown
  @Published private(set) var lastLifecycleKind: SystemLifecycleEventKind?
  @Published private(set) var loginItemStatus: LoginItemRegistrationStatus
  @Published private(set) var errorMessage: String?

  let history = HistoryViewModel()

  private let loginItemManager: LoginItemManager

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

  func receive(_ event: MemoryMonitoringEvent) {
    switch event {
    case .sample(let sample):
      sampleCount += 1
      lastMemoryUsedBytes = sample.estimatedMemoryUsedBytes
      history.receiveSample(at: sample.timestampUTC)
    case .totalCPU(let sample):
      history.receiveSample(at: sample.intervalEndUTC)
    case .logicalCPU(let outcome):
      switch outcome {
      case .samples(let samples):
        if let timestamp = samples.first?.intervalEndUTC {
          history.receiveSample(at: timestamp)
        }
      case .gap(let gap):
        history.receiveSample(at: gap.timestampUTC)
      }
    case .gap:
      gapCount += 1
    case .pressure(let observation):
      pressureLevel = observation.level
    case .lifecycle(let event):
      lastLifecycleKind = event.kind
    case .failure(let message):
      errorMessage = message
    }
  }

  func configureHistory(
    database: MemoryWatcherDatabase,
    initialPeriod: MemoryHistoryPeriod = .twentyFourHours,
    now: Date = Date()
  ) {
    history.configure(database: database, initialPeriod: initialPeriod, now: now)
  }

  var historyPeriod: MemoryHistoryPeriod {
    history.historyPeriod
  }

  var historySnapshot: MemoryHistorySnapshot? {
    history.historySnapshot
  }

  var historyIsLoading: Bool {
    history.historyIsLoading
  }

  var historyLoadDurationSeconds: TimeInterval? {
    history.historyLoadDurationSeconds
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
}

@MainActor
final class HistoryViewModel: ObservableObject {
  @Published private(set) var historyPeriod: MemoryHistoryPeriod =
    .twentyFourHours
  @Published private(set) var historySnapshot: MemoryHistorySnapshot?
  @Published private(set) var historyIsLoading = false
  @Published private(set) var historyLoadDurationSeconds: TimeInterval?
  @Published private(set) var historyErrorMessage: String?

  private let refreshPolicy = MemoryHistoryRefreshPolicy()
  private var historyLoader: MemoryHistoryLoader?
  private var historyLoadTask: Task<Void, Never>?
  private var lastReloadAt: Date?
  private var windowIsVisible = false

  func configure(
    database: MemoryWatcherDatabase,
    initialPeriod: MemoryHistoryPeriod = .twentyFourHours,
    now: Date = Date()
  ) {
    historyLoader = MemoryHistoryLoader(database: database)
    historyPeriod = initialPeriod
    reloadHistory(now: now)
  }

  func setWindowVisible(_ visible: Bool, now: Date = Date()) {
    windowIsVisible = visible
    guard visible else {
      return
    }
    if let lastReloadAt,
      now.timeIntervalSince(lastReloadAt) < 15
    {
      return
    }
    reloadHistory(now: now)
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
    reloadHistory(now: now)
  }

  func selectHistoryPeriod(
    _ period: MemoryHistoryPeriod,
    now: Date = Date()
  ) {
    guard period != historyPeriod || historySnapshot == nil else {
      return
    }
    historyPeriod = period
    reloadHistory(now: now)
  }

  func reloadHistory(now: Date = Date()) {
    guard let historyLoader else {
      return
    }
    historyLoadTask?.cancel()
    let period = historyPeriod
    historyIsLoading = true
    historyErrorMessage = nil
    historyLoadTask = Task { [weak self] in
      do {
        let loaded = try await Task.detached(priority: .userInitiated) {
          let startedAt = Date()
          let snapshot = try historyLoader.load(period: period, now: now)
          return (snapshot, Date().timeIntervalSince(startedAt))
        }.value
        try Task.checkCancellation()
        guard let self, self.historyPeriod == period else {
          return
        }
        self.historySnapshot = loaded.0
        self.historyLoadDurationSeconds = loaded.1
        self.historyIsLoading = false
        self.lastReloadAt = now
      } catch is CancellationError {
        return
      } catch {
        guard let self else {
          return
        }
        self.historyErrorMessage = String(describing: error)
        self.historyIsLoading = false
      }
    }
  }

  func nearestHistoryPoint(to date: Date) -> MemoryHistoryPoint? {
    nearestPoint(in: historySnapshot?.points ?? [], to: date, at: \.timestampUTC)
  }

  func nearestTotalCPUPoint(to date: Date) -> TotalCPUHistoryPoint? {
    nearestPoint(
      in: historySnapshot?.cpuHistory.totalPoints ?? [],
      to: date,
      at: \.timestampUTC
    )
  }

  func nearestLogicalCPUPoints(to date: Date) -> [LogicalCPUHistoryPoint] {
    guard
      let snapshot = historySnapshot,
      !snapshot.cpuHistory.logicalPoints.isEmpty
    else {
      return []
    }
    let nearest = snapshot.cpuHistory.logicalPoints.min {
      abs($0.timestampUTC.timeIntervalSince(date))
        < abs($1.timestampUTC.timeIntervalSince(date))
    }
    guard let nearest else { return [] }
    let tolerance = max(0.001, snapshot.period.expectedPointInterval / 2)
    return snapshot.cpuHistory.logicalPoints.filter {
      abs($0.timestampUTC.timeIntervalSince(nearest.timestampUTC)) <= tolerance
        && $0.topology == nearest.topology
    }.sorted { $0.cpuIndex < $1.cpuIndex }
  }

  private func nearestPoint<Point>(
    in points: [Point],
    to date: Date,
    at timestamp: KeyPath<Point, Date>
  ) -> Point? {
    guard !points.isEmpty else { return nil }
    var lower = 0
    var upper = points.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if points[middle][keyPath: timestamp] < date {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    if lower == 0 {
      return points[0]
    }
    if lower == points.count {
      return points[points.count - 1]
    }
    let before = points[lower - 1]
    let after = points[lower]
    return date.timeIntervalSince(before[keyPath: timestamp])
      <= after[keyPath: timestamp].timeIntervalSince(date)
      ? before
      : after
  }
}
