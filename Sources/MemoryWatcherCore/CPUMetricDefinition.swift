import Darwin
import Foundation

public struct CPUCounterSnapshot: Equatable, Sendable {
  public let userTicks: UInt64
  public let systemTicks: UInt64
  public let idleTicks: UInt64
  public let niceTicks: UInt64

  public init(
    userTicks: UInt64,
    systemTicks: UInt64,
    idleTicks: UInt64,
    niceTicks: UInt64
  ) {
    self.userTicks = userTicks
    self.systemTicks = systemTicks
    self.idleTicks = idleTicks
    self.niceTicks = niceTicks
  }
}

public enum CPUIntervalContinuity: String, Codable, Sendable {
  case continuous
  case sleep
  case wake
  case reboot
  case clockChange
  case topologyChange
  case unavailable
}

public enum CPUUtilizationQuality: String, Codable, Sendable {
  case measured
  case firstDeltaUnknown
  case sleepBoundary
  case wakeBoundary
  case rebootBoundary
  case clockChangeBoundary
  case topologyChangeBoundary
  case intervalOutOfRange
  case unavailable
  case counterRegression
  case noTickProgress
  case arithmeticOverflow
}

public struct TotalCPUCounterObservation: Equatable, Sendable {
  public let timestampUTC: Date
  public let systemUptimeSeconds: TimeInterval
  public let counters: CPUCounterSnapshot

  public init(
    timestampUTC: Date,
    systemUptimeSeconds: TimeInterval,
    counters: CPUCounterSnapshot
  ) {
    self.timestampUTC = timestampUTC
    self.systemUptimeSeconds = systemUptimeSeconds
    self.counters = counters
  }
}

public struct TotalCPUSample: Equatable, Sendable {
  public let intervalStartUTC: Date?
  public let intervalEndUTC: Date
  public let intervalStartUptimeSeconds: TimeInterval?
  public let intervalEndUptimeSeconds: TimeInterval
  public let delta: CPUCounterDelta?
  public let calculationVersion: String
  public let quality: CPUUtilizationQuality

  public init(
    intervalStartUTC: Date?,
    intervalEndUTC: Date,
    intervalStartUptimeSeconds: TimeInterval?,
    intervalEndUptimeSeconds: TimeInterval,
    delta: CPUCounterDelta?,
    calculationVersion: String = CPUUtilizationCalculator.calculationVersion,
    quality: CPUUtilizationQuality
  ) {
    self.intervalStartUTC = intervalStartUTC
    self.intervalEndUTC = intervalEndUTC
    self.intervalStartUptimeSeconds = intervalStartUptimeSeconds
    self.intervalEndUptimeSeconds = intervalEndUptimeSeconds
    self.delta = delta
    self.calculationVersion = calculationVersion
    self.quality = quality
  }

  public var utilizationPercent: Double? {
    delta?.utilizationPercent
  }
}

public enum TotalCPUSampleValidationError: Error, Equatable, Sendable {
  case invalidEndAnchor
  case invalidMeasuredInterval
  case inconsistentQuality
  case inconsistentDelta
  case invalidCalculationVersion
}

public enum TotalCPUSampleValidator {
  public static func validate(_ sample: TotalCPUSample) throws {
    guard
      sample.intervalEndUTC.timeIntervalSince1970.isFinite,
      sample.intervalEndUTC.timeIntervalSince1970 >= 0,
      sample.intervalEndUptimeSeconds.isFinite,
      sample.intervalEndUptimeSeconds >= 0
    else {
      throw TotalCPUSampleValidationError.invalidEndAnchor
    }
    guard !sample.calculationVersion.isEmpty else {
      throw TotalCPUSampleValidationError.invalidCalculationVersion
    }

    if sample.quality == .measured {
      guard
        let startUTC = sample.intervalStartUTC,
        let startUptime = sample.intervalStartUptimeSeconds,
        let delta = sample.delta
      else {
        throw TotalCPUSampleValidationError.inconsistentQuality
      }
      let elapsed = sample.intervalEndUptimeSeconds - startUptime
      guard
        startUTC <= sample.intervalEndUTC,
        elapsed >= CPUUtilizationCalculator.minimumContinuousIntervalSeconds,
        elapsed <= CPUUtilizationCalculator.maximumContinuousIntervalSeconds
      else {
        throw TotalCPUSampleValidationError.invalidMeasuredInterval
      }
      let busy = try checkedSum(delta.userTicks, delta.systemTicks, delta.niceTicks)
      let total = try checkedSum(busy, delta.idleTicks)
      guard busy == delta.busyTicks, total == delta.totalTicks, total > 0 else {
        throw TotalCPUSampleValidationError.inconsistentDelta
      }
    } else {
      guard
        sample.intervalStartUTC == nil,
        sample.intervalStartUptimeSeconds == nil,
        sample.delta == nil
      else {
        throw TotalCPUSampleValidationError.inconsistentQuality
      }
    }
  }

  private static func checkedSum(_ values: UInt64...) throws -> UInt64 {
    var sum: UInt64 = 0
    for value in values {
      let addition = sum.addingReportingOverflow(value)
      guard !addition.overflow else {
        throw TotalCPUSampleValidationError.inconsistentDelta
      }
      sum = addition.partialValue
    }
    return sum
  }
}

public enum TotalCPUSamplingError: Error, Equatable, Sendable {
  case hostStatistics(Int32)
}

public final class SystemTotalCPUSampler: @unchecked Sendable {
  private let lock = NSLock()
  private let observationProvider: @Sendable () throws -> TotalCPUCounterObservation
  private let timestampProvider: @Sendable () -> Date
  private let uptimeProvider: @Sendable () -> TimeInterval
  private var previousObservation: TotalCPUCounterObservation?
  private var pendingContinuity: CPUIntervalContinuity?

  public init() {
    observationProvider = Self.readSystemObservation
    timestampProvider = { Date() }
    uptimeProvider = { ProcessInfo.processInfo.systemUptime }
  }

  init(
    observationProvider: @escaping @Sendable () throws -> TotalCPUCounterObservation,
    timestampProvider: @escaping @Sendable () -> Date,
    uptimeProvider: @escaping @Sendable () -> TimeInterval
  ) {
    self.observationProvider = observationProvider
    self.timestampProvider = timestampProvider
    self.uptimeProvider = uptimeProvider
  }

  public func reset(for continuity: CPUIntervalContinuity) {
    lock.withLock {
      previousObservation = nil
      pendingContinuity = continuity
    }
  }

  public func reset() {
    lock.withLock {
      previousObservation = nil
      pendingContinuity = nil
    }
  }

  public func sample() -> TotalCPUSample {
    lock.withLock {
      let observation: TotalCPUCounterObservation
      do {
        observation = try observationProvider()
      } catch {
        previousObservation = nil
        pendingContinuity = nil
        return unknownSample(
          timestampUTC: timestampProvider(),
          uptime: uptimeProvider(),
          quality: .unavailable
        )
      }

      if let pendingContinuity {
        self.pendingContinuity = nil
        previousObservation = observation
        return unknownSample(
          observation: observation,
          quality: quality(for: pendingContinuity)
        )
      }
      guard let previousObservation else {
        self.previousObservation = observation
        return unknownSample(
          observation: observation,
          quality: .firstDeltaUnknown
        )
      }
      self.previousObservation = observation

      if SystemTimelineAnalyzer.clockChanged(
        previous: SystemTimelineAnchor(
          timestampUTC: previousObservation.timestampUTC,
          systemUptimeSeconds: previousObservation.systemUptimeSeconds
        ),
        current: SystemTimelineAnchor(
          timestampUTC: observation.timestampUTC,
          systemUptimeSeconds: observation.systemUptimeSeconds
        )
      ) {
        return unknownSample(
          observation: observation,
          quality: .clockChangeBoundary
        )
      }

      let elapsed =
        observation.systemUptimeSeconds
        - previousObservation.systemUptimeSeconds
      guard
        elapsed >= CPUUtilizationCalculator.minimumContinuousIntervalSeconds,
        elapsed <= CPUUtilizationCalculator.maximumContinuousIntervalSeconds
      else {
        return unknownSample(
          observation: observation,
          quality: .intervalOutOfRange
        )
      }

      switch CPUUtilizationCalculator.calculate(
        previous: previousObservation.counters,
        current: observation.counters
      ) {
      case .measured(let delta):
        return TotalCPUSample(
          intervalStartUTC: previousObservation.timestampUTC,
          intervalEndUTC: observation.timestampUTC,
          intervalStartUptimeSeconds: previousObservation.systemUptimeSeconds,
          intervalEndUptimeSeconds: observation.systemUptimeSeconds,
          delta: delta,
          quality: .measured
        )
      case .unknown(let quality):
        return unknownSample(observation: observation, quality: quality)
      }
    }
  }

  private func unknownSample(
    observation: TotalCPUCounterObservation,
    quality: CPUUtilizationQuality
  ) -> TotalCPUSample {
    unknownSample(
      timestampUTC: observation.timestampUTC,
      uptime: observation.systemUptimeSeconds,
      quality: quality
    )
  }

  private func unknownSample(
    timestampUTC: Date,
    uptime: TimeInterval,
    quality: CPUUtilizationQuality
  ) -> TotalCPUSample {
    TotalCPUSample(
      intervalStartUTC: nil,
      intervalEndUTC: timestampUTC,
      intervalStartUptimeSeconds: nil,
      intervalEndUptimeSeconds: uptime,
      delta: nil,
      quality: quality
    )
  }

  private func quality(
    for continuity: CPUIntervalContinuity
  ) -> CPUUtilizationQuality {
    switch CPUUtilizationCalculator.calculate(
      previous: CPUCounterSnapshot(
        userTicks: 0,
        systemTicks: 0,
        idleTicks: 0,
        niceTicks: 0
      ),
      current: CPUCounterSnapshot(
        userTicks: 0,
        systemTicks: 0,
        idleTicks: 0,
        niceTicks: 0
      ),
      continuity: continuity
    ) {
    case .unknown(let quality):
      return quality
    case .measured:
      return .unavailable
    }
  }

  private static func readSystemObservation() throws -> TotalCPUCounterObservation {
    let host = mach_host_self()
    defer {
      mach_port_deallocate(mach_task_self_, host)
    }
    var statistics = host_cpu_load_info_data_t()
    var statisticsCount = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info_data_t>.stride
        / MemoryLayout<integer_t>.stride
    )
    let result = withUnsafeMutablePointer(to: &statistics) { pointer in
      pointer.withMemoryRebound(
        to: integer_t.self,
        capacity: Int(statisticsCount)
      ) { reboundPointer in
        host_statistics(
          host,
          HOST_CPU_LOAD_INFO,
          reboundPointer,
          &statisticsCount
        )
      }
    }
    guard result == KERN_SUCCESS else {
      throw TotalCPUSamplingError.hostStatistics(result)
    }
    return TotalCPUCounterObservation(
      timestampUTC: Date(),
      systemUptimeSeconds: ProcessInfo.processInfo.systemUptime,
      counters: CPUCounterSnapshot(
        userTicks: UInt64(statistics.cpu_ticks.0),
        systemTicks: UInt64(statistics.cpu_ticks.1),
        idleTicks: UInt64(statistics.cpu_ticks.2),
        niceTicks: UInt64(statistics.cpu_ticks.3)
      )
    )
  }
}

public struct CPUCounterDelta: Equatable, Sendable {
  public let userTicks: UInt64
  public let systemTicks: UInt64
  public let idleTicks: UInt64
  public let niceTicks: UInt64
  public let busyTicks: UInt64
  public let totalTicks: UInt64

  public var userPercent: Double { percent(for: userTicks) }
  public var systemPercent: Double { percent(for: systemTicks) }
  public var idlePercent: Double { percent(for: idleTicks) }
  public var nicePercent: Double { percent(for: niceTicks) }
  public var utilizationPercent: Double { percent(for: busyTicks) }

  private func percent(for ticks: UInt64) -> Double {
    100 * Double(ticks) / Double(totalTicks)
  }
}

public enum CPUCounterDeltaResult: Equatable, Sendable {
  case measured(CPUCounterDelta)
  case unknown(CPUUtilizationQuality)
}

public enum CPUUtilizationCalculator {
  public static let calculationVersion = "phase-13-v1"
  public static let targetSamplingIntervalSeconds = 5.0
  public static let minimumContinuousIntervalSeconds = 1.0
  public static let maximumContinuousIntervalSeconds = 15.0

  public static func calculate(
    previous: CPUCounterSnapshot?,
    current: CPUCounterSnapshot,
    continuity: CPUIntervalContinuity = .continuous
  ) -> CPUCounterDeltaResult {
    guard continuity == .continuous else {
      return .unknown(quality(for: continuity))
    }
    guard let previous else {
      return .unknown(.firstDeltaUnknown)
    }
    guard
      current.userTicks >= previous.userTicks,
      current.systemTicks >= previous.systemTicks,
      current.idleTicks >= previous.idleTicks,
      current.niceTicks >= previous.niceTicks
    else {
      return .unknown(.counterRegression)
    }

    let userTicks = current.userTicks - previous.userTicks
    let systemTicks = current.systemTicks - previous.systemTicks
    let idleTicks = current.idleTicks - previous.idleTicks
    let niceTicks = current.niceTicks - previous.niceTicks

    guard
      let busyTicks = checkedSum(userTicks, systemTicks, niceTicks),
      let totalTicks = checkedSum(busyTicks, idleTicks)
    else {
      return .unknown(.arithmeticOverflow)
    }
    guard totalTicks > 0 else {
      return .unknown(.noTickProgress)
    }

    return .measured(
      CPUCounterDelta(
        userTicks: userTicks,
        systemTicks: systemTicks,
        idleTicks: idleTicks,
        niceTicks: niceTicks,
        busyTicks: busyTicks,
        totalTicks: totalTicks
      )
    )
  }

  private static func checkedSum(_ values: UInt64...) -> UInt64? {
    var result: UInt64 = 0
    for value in values {
      let addition = result.addingReportingOverflow(value)
      guard !addition.overflow else { return nil }
      result = addition.partialValue
    }
    return result
  }

  private static func quality(
    for continuity: CPUIntervalContinuity
  ) -> CPUUtilizationQuality {
    switch continuity {
    case .continuous:
      return .measured
    case .sleep:
      return .sleepBoundary
    case .wake:
      return .wakeBoundary
    case .reboot:
      return .rebootBoundary
    case .clockChange:
      return .clockChangeBoundary
    case .topologyChange:
      return .topologyChangeBoundary
    case .unavailable:
      return .unavailable
    }
  }
}
