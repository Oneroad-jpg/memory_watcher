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
  case unavailable
  case counterRegression
  case noTickProgress
  case arithmeticOverflow
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
