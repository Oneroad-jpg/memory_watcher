import Dispatch
import Foundation

public enum MemoryPressureLevel: String, Codable, CaseIterable, Sendable {
  case unknown = "UNKNOWN"
  case normal = "NORMAL"
  case warning = "WARNING"
  case critical = "CRITICAL"
}

public struct MemoryPressureObservation: Codable, Equatable, Sendable {
  public let timestampUTC: Date
  public let systemUptimeSeconds: TimeInterval
  public let level: MemoryPressureLevel

  public init(
    timestampUTC: Date,
    systemUptimeSeconds: TimeInterval,
    level: MemoryPressureLevel
  ) {
    self.timestampUTC = timestampUTC
    self.systemUptimeSeconds = systemUptimeSeconds
    self.level = level
  }
}

public enum MemoryPressureMonitorError: Error, Equatable, Sendable {
  case alreadyStarted
}

struct MemoryPressureEventDecoder {
  static func level(
    for event: DispatchSource.MemoryPressureEvent
  ) -> MemoryPressureLevel {
    switch event {
    case .normal:
      return .normal
    case .warning:
      return .warning
    case .critical:
      return .critical
    default:
      return .unknown
    }
  }
}

struct MemoryPressureStateMachine {
  private(set) var currentLevel: MemoryPressureLevel = .unknown

  mutating func transition(
    to nextLevel: MemoryPressureLevel,
    timestampUTC: Date,
    systemUptimeSeconds: TimeInterval
  ) -> MemoryPressureObservation? {
    guard nextLevel != currentLevel else {
      return nil
    }
    currentLevel = nextLevel
    return MemoryPressureObservation(
      timestampUTC: timestampUTC,
      systemUptimeSeconds: systemUptimeSeconds,
      level: nextLevel
    )
  }
}

public final class MemoryPressureMonitor: @unchecked Sendable {
  public typealias ObservationHandler =
    @Sendable (
      MemoryPressureObservation
    ) -> Void

  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let timestampProvider: @Sendable () -> Date
  private let uptimeProvider: @Sendable () -> TimeInterval
  private var source: (any DispatchSourceMemoryPressure)?
  private var stateMachine = MemoryPressureStateMachine()

  public init() {
    queue = DispatchQueue(label: "MemoryWatcher.MemoryPressureMonitor")
    timestampProvider = { Date() }
    uptimeProvider = { ProcessInfo.processInfo.systemUptime }
    queue.setSpecific(key: queueKey, value: 1)
  }

  init(
    queue: DispatchQueue,
    timestampProvider: @escaping @Sendable () -> Date,
    uptimeProvider: @escaping @Sendable () -> TimeInterval
  ) {
    self.queue = queue
    self.timestampProvider = timestampProvider
    self.uptimeProvider = uptimeProvider
    queue.setSpecific(key: queueKey, value: 1)
  }

  @discardableResult
  public func start(
    handler: @escaping ObservationHandler
  ) throws -> MemoryPressureObservation {
    try performOnQueue {
      guard source == nil else {
        throw MemoryPressureMonitorError.alreadyStarted
      }

      stateMachine = MemoryPressureStateMachine()
      let initialObservation = MemoryPressureObservation(
        timestampUTC: timestampProvider(),
        systemUptimeSeconds: uptimeProvider(),
        level: .unknown
      )
      let memoryPressureSource = DispatchSource.makeMemoryPressureSource(
        eventMask: [.normal, .warning, .critical],
        queue: queue
      )
      source = memoryPressureSource
      memoryPressureSource.setEventHandler { [weak self] in
        guard let self, let currentSource = self.source else {
          return
        }
        let nextLevel = MemoryPressureEventDecoder.level(
          for: currentSource.data
        )
        guard
          let observation = self.stateMachine.transition(
            to: nextLevel,
            timestampUTC: self.timestampProvider(),
            systemUptimeSeconds: self.uptimeProvider()
          )
        else {
          return
        }
        handler(observation)
      }
      memoryPressureSource.activate()
      return initialObservation
    }
  }

  public func stop() {
    performOnQueue {
      source?.cancel()
      source = nil
      stateMachine = MemoryPressureStateMachine()
    }
  }

  deinit {
    source?.cancel()
  }

  private func performOnQueue<T>(_ operation: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return try operation()
    }
    return try queue.sync(execute: operation)
  }
}
