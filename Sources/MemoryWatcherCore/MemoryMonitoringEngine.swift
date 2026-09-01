import Dispatch
import Foundation

public enum MemoryMonitoringRunState: String, Equatable, Sendable {
  case stopped
  case running
  case sleeping
}

public enum MemoryMonitoringEngineError: Error, Equatable, Sendable {
  case alreadyStarted
}

public enum MemoryMonitoringEvent: Sendable {
  case sample(MemorySample)
  case totalCPU(TotalCPUSample)
  case logicalCPU(LogicalCPUSamplingOutcome)
  case gap(MemorySamplingGap)
  case pressure(MemoryPressureObservation)
  case lifecycle(SystemLifecycleEvent)
  case failure(String)
}

public final class MemoryMonitoringEngine: @unchecked Sendable {
  public typealias EventHandler = @Sendable (MemoryMonitoringEvent) -> Void

  private let database: MemoryWatcherDatabase
  private let sampleProvider: @Sendable () throws -> MemorySamplingOutcome
  private let timestampProvider: @Sendable () -> Date
  private let uptimeProvider: @Sendable () -> TimeInterval
  private let totalCPUSampleProvider: (@Sendable () -> TotalCPUSample)?
  private let resetTotalCPUSampler: (@Sendable (CPUIntervalContinuity?) -> Void)?
  private let logicalCPUSampleProvider: (@Sendable () -> LogicalCPUSamplingOutcome)?
  private let resetLogicalCPUSampler: (@Sendable (CPUIntervalContinuity?) -> Void)?
  private let eventHandler: EventHandler
  private let pressureMonitor: MemoryPressureMonitor
  private let sampleInterval: TimeInterval
  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<UInt8>()

  private var timer: DispatchSourceTimer?
  private var runState: MemoryMonitoringRunState = .stopped
  private var lastSampleAnchor: SystemTimelineAnchor?
  private var lastHistoryMaintenanceUptime: TimeInterval?

  public init(
    database: MemoryWatcherDatabase,
    eventHandler: @escaping EventHandler = { _ in }
  ) {
    let totalCPUSampler = SystemTotalCPUSampler()
    let logicalCPUSampler = SystemLogicalCPUSampler()
    self.database = database
    sampleProvider = { try SystemMemorySampler().sampleOutcome() }
    timestampProvider = { Date() }
    uptimeProvider = { ProcessInfo.processInfo.systemUptime }
    totalCPUSampleProvider = { totalCPUSampler.sample() }
    resetTotalCPUSampler = { continuity in
      if let continuity {
        totalCPUSampler.reset(for: continuity)
      } else {
        totalCPUSampler.reset()
      }
    }
    logicalCPUSampleProvider = { logicalCPUSampler.sample() }
    resetLogicalCPUSampler = { continuity in
      if let continuity {
        logicalCPUSampler.reset(for: continuity)
      } else {
        logicalCPUSampler.reset()
      }
    }
    self.eventHandler = eventHandler
    pressureMonitor = MemoryPressureMonitor()
    sampleInterval = MemoryWatcherFoundation.sampleInterval
    queue = DispatchQueue(label: "MemoryWatcher.MonitoringEngine")
    queue.setSpecific(key: queueKey, value: 1)
  }

  init(
    database: MemoryWatcherDatabase,
    sampleProvider: @escaping @Sendable () throws -> MemorySamplingOutcome,
    timestampProvider: @escaping @Sendable () -> Date,
    uptimeProvider: @escaping @Sendable () -> TimeInterval,
    pressureMonitor: MemoryPressureMonitor = MemoryPressureMonitor(),
    sampleInterval: TimeInterval = MemoryWatcherFoundation.sampleInterval,
    totalCPUSampleProvider: (@Sendable () -> TotalCPUSample)? = nil,
    resetTotalCPUSampler: (@Sendable (CPUIntervalContinuity?) -> Void)? = nil,
    logicalCPUSampleProvider:
      (@Sendable () -> LogicalCPUSamplingOutcome)? = nil,
    resetLogicalCPUSampler:
      (@Sendable (CPUIntervalContinuity?) -> Void)? = nil,
    eventHandler: @escaping EventHandler = { _ in }
  ) {
    precondition(sampleInterval > 0)
    self.database = database
    self.sampleProvider = sampleProvider
    self.timestampProvider = timestampProvider
    self.uptimeProvider = uptimeProvider
    self.totalCPUSampleProvider = totalCPUSampleProvider
    self.resetTotalCPUSampler = resetTotalCPUSampler
    self.logicalCPUSampleProvider = logicalCPUSampleProvider
    self.resetLogicalCPUSampler = resetLogicalCPUSampler
    self.eventHandler = eventHandler
    self.pressureMonitor = pressureMonitor
    self.sampleInterval = sampleInterval
    queue = DispatchQueue(label: "MemoryWatcher.MonitoringEngine.Tests")
    queue.setSpecific(key: queueKey, value: 1)
  }

  public var state: MemoryMonitoringRunState {
    performOnQueue { runState }
  }

  public func start() throws {
    try performOnQueue {
      guard runState == .stopped else {
        throw MemoryMonitoringEngineError.alreadyStarted
      }

      let previousSample = try database.latestSampleAnchor()
      let launchAnchor = currentAnchor()
      let launchEvents = SystemTimelineAnalyzer.launchEventKinds(
        previousSample: previousSample,
        current: launchAnchor
      ).map {
        SystemLifecycleEvent(
          timestampUTC: launchAnchor.timestampUTC,
          systemUptimeSeconds: launchAnchor.systemUptimeSeconds,
          kind: $0
        )
      }
      resetTotalCPUSampler?(nil)
      resetLogicalCPUSampler?(nil)
      if launchEvents.contains(where: { $0.kind == .rebootDetected }) {
        resetTotalCPUSampler?(.reboot)
        resetLogicalCPUSampler?(.reboot)
      }
      try database.insert(lifecycleEvents: launchEvents)
      for event in launchEvents {
        eventHandler(.lifecycle(event))
      }

      do {
        let initialPressure = try pressureMonitor.start { [weak self] observation in
          self?.storePressureObservation(observation)
        }
        try database.insert(pressureObservations: [initialPressure])
        eventHandler(.pressure(initialPressure))
      } catch {
        pressureMonitor.stop()
        throw error
      }

      runState = .running
      lastSampleAnchor = nil
      lastHistoryMaintenanceUptime = nil
      recordSampleSlot()
      scheduleTimer()
    }
  }

  public func prepareForSleep() {
    performOnQueue {
      guard runState == .running else {
        return
      }
      cancelTimer()
      runState = .sleeping
      resetTotalCPUSampler?(.sleep)
      resetLogicalCPUSampler?(.sleep)
      lastSampleAnchor = nil
      let event = lifecycleEvent(kind: .sleep)
      do {
        try database.insert(lifecycleEvents: [event])
        eventHandler(.lifecycle(event))
      } catch {
        eventHandler(.failure(String(describing: error)))
      }
    }
  }

  public func resumeAfterWake() {
    performOnQueue {
      guard runState == .sleeping else {
        return
      }
      runState = .running
      resetTotalCPUSampler?(.wake)
      resetLogicalCPUSampler?(.wake)
      lastSampleAnchor = nil
      lastHistoryMaintenanceUptime = nil
      let event = lifecycleEvent(kind: .wake)
      do {
        try database.insert(lifecycleEvents: [event])
        eventHandler(.lifecycle(event))
      } catch {
        eventHandler(.failure(String(describing: error)))
      }
      recordSampleSlot()
      scheduleTimer()
    }
  }

  public func recordSystemClockChange() {
    performOnQueue {
      guard runState != .stopped else {
        return
      }
      let event = lifecycleEvent(kind: .clockChanged)
      do {
        try database.insert(lifecycleEvents: [event])
        eventHandler(.lifecycle(event))
      } catch {
        eventHandler(.failure(String(describing: error)))
      }
      lastSampleAnchor = nil
      lastHistoryMaintenanceUptime = nil
      resetTotalCPUSampler?(.clockChange)
      resetLogicalCPUSampler?(.clockChange)
    }
  }

  public func stop() {
    performOnQueue {
      cancelTimer()
      pressureMonitor.stop()
      runState = .stopped
      lastSampleAnchor = nil
      lastHistoryMaintenanceUptime = nil
    }
  }

  @discardableResult
  func recordSampleNow() -> Bool {
    performOnQueue {
      guard runState == .running else {
        return false
      }
      recordSampleSlot()
      return true
    }
  }

  deinit {
    timer?.cancel()
    pressureMonitor.stop()
  }

  private func scheduleTimer() {
    cancelTimer()
    let newTimer = DispatchSource.makeTimerSource(queue: queue)
    newTimer.schedule(
      deadline: .now() + sampleInterval,
      repeating: sampleInterval,
      leeway: .milliseconds(250)
    )
    newTimer.setEventHandler { [weak self] in
      self?.recordSampleSlot()
    }
    timer = newTimer
    newTimer.activate()
  }

  private func cancelTimer() {
    timer?.cancel()
    timer = nil
  }

  private func recordSampleSlot() {
    guard runState == .running else {
      return
    }
    var maintenanceAnchor: SystemTimelineAnchor?
    do {
      switch try sampleProvider() {
      case .sample(let sample):
        let current = SystemTimelineAnchor(
          timestampUTC: sample.timestampUTC,
          systemUptimeSeconds: sample.systemUptimeSeconds
        )
        if let lastSampleAnchor,
          SystemTimelineAnalyzer.clockChanged(
            previous: lastSampleAnchor,
            current: current
          )
        {
          let event = SystemLifecycleEvent(
            timestampUTC: sample.timestampUTC,
            systemUptimeSeconds: sample.systemUptimeSeconds,
            kind: .clockChanged
          )
          try database.insert(lifecycleEvents: [event])
          eventHandler(.lifecycle(event))
          resetTotalCPUSampler?(.clockChange)
          resetLogicalCPUSampler?(.clockChange)
        }
        try database.insert(samples: [sample])
        self.lastSampleAnchor = current
        eventHandler(.sample(sample))
        maintenanceAnchor = current
      case .gap(let gap):
        try database.insert(gaps: [gap])
        eventHandler(.gap(gap))
        maintenanceAnchor = SystemTimelineAnchor(
          timestampUTC: gap.timestampUTC,
          systemUptimeSeconds: gap.systemUptimeSeconds
        )
      }
    } catch {
      eventHandler(.failure(String(describing: error)))
    }

    if let totalCPUSampleProvider {
      let cpuSample = totalCPUSampleProvider()
      do {
        try database.insert(totalCPUSamples: [cpuSample])
        eventHandler(.totalCPU(cpuSample))
        if maintenanceAnchor == nil {
          maintenanceAnchor = SystemTimelineAnchor(
            timestampUTC: cpuSample.intervalEndUTC,
            systemUptimeSeconds: cpuSample.intervalEndUptimeSeconds
          )
        }
      } catch {
        eventHandler(.failure(String(describing: error)))
      }
    }

    if let logicalCPUSampleProvider {
      let outcome = logicalCPUSampleProvider()
      do {
        switch outcome {
        case .samples(let samples):
          try database.insert(logicalCPUSamples: samples)
          if maintenanceAnchor == nil, let first = samples.first {
            maintenanceAnchor = SystemTimelineAnchor(
              timestampUTC: first.intervalEndUTC,
              systemUptimeSeconds: first.intervalEndUptimeSeconds
            )
          }
        case .gap(let gap):
          try database.insert(logicalCPUGaps: [gap])
          if maintenanceAnchor == nil {
            maintenanceAnchor = SystemTimelineAnchor(
              timestampUTC: gap.timestampUTC,
              systemUptimeSeconds: gap.systemUptimeSeconds
            )
          }
        }
        eventHandler(.logicalCPU(outcome))
      } catch {
        eventHandler(.failure(String(describing: error)))
      }
    }

    if let maintenanceAnchor {
      runHistoryMaintenanceIfDue(at: maintenanceAnchor)
    }
  }

  private func runHistoryMaintenanceIfDue(at anchor: SystemTimelineAnchor) {
    if let lastHistoryMaintenanceUptime {
      let elapsed =
        anchor.systemUptimeSeconds - lastHistoryMaintenanceUptime
      guard
        elapsed < 0
          || elapsed >= MemoryHistoryRetentionPolicy.maintenanceInterval
      else {
        return
      }
    }
    lastHistoryMaintenanceUptime = anchor.systemUptimeSeconds
    do {
      _ = try database.performHistoryMaintenance(now: anchor.timestampUTC)
    } catch {
      eventHandler(.failure(String(describing: error)))
    }
  }

  private func storePressureObservation(_ observation: MemoryPressureObservation) {
    do {
      try database.insert(pressureObservations: [observation])
      eventHandler(.pressure(observation))
    } catch {
      eventHandler(.failure(String(describing: error)))
    }
  }

  private func lifecycleEvent(
    kind: SystemLifecycleEventKind
  ) -> SystemLifecycleEvent {
    let anchor = currentAnchor()
    return SystemLifecycleEvent(
      timestampUTC: anchor.timestampUTC,
      systemUptimeSeconds: anchor.systemUptimeSeconds,
      kind: kind
    )
  }

  private func currentAnchor() -> SystemTimelineAnchor {
    SystemTimelineAnchor(
      timestampUTC: timestampProvider(),
      systemUptimeSeconds: uptimeProvider()
    )
  }

  private func performOnQueue<T>(_ operation: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return try operation()
    }
    return try queue.sync(execute: operation)
  }
}
