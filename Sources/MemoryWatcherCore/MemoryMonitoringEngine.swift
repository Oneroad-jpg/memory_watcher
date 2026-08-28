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
    self.database = database
    sampleProvider = { try SystemMemorySampler().sampleOutcome() }
    timestampProvider = { Date() }
    uptimeProvider = { ProcessInfo.processInfo.systemUptime }
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
    eventHandler: @escaping EventHandler = { _ in }
  ) {
    precondition(sampleInterval > 0)
    self.database = database
    self.sampleProvider = sampleProvider
    self.timestampProvider = timestampProvider
    self.uptimeProvider = uptimeProvider
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
    do {
      let maintenanceAnchor: SystemTimelineAnchor
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
      runHistoryMaintenanceIfDue(at: maintenanceAnchor)
    } catch {
      eventHandler(.failure(String(describing: error)))
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
