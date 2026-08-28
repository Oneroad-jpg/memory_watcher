import Foundation

public enum SystemLifecycleEventKind: String, Codable, CaseIterable, Sendable {
  case launch = "LAUNCH"
  case sleep = "SLEEP"
  case wake = "WAKE"
  case clockChanged = "CLOCK_CHANGED"
  case rebootDetected = "REBOOT_DETECTED"
}

public struct SystemTimelineAnchor: Codable, Equatable, Sendable {
  public let timestampUTC: Date
  public let systemUptimeSeconds: TimeInterval

  public init(timestampUTC: Date, systemUptimeSeconds: TimeInterval) {
    self.timestampUTC = timestampUTC
    self.systemUptimeSeconds = systemUptimeSeconds
  }
}

public struct SystemLifecycleEvent: Codable, Equatable, Sendable {
  public let timestampUTC: Date
  public let systemUptimeSeconds: TimeInterval
  public let kind: SystemLifecycleEventKind

  public init(
    timestampUTC: Date,
    systemUptimeSeconds: TimeInterval,
    kind: SystemLifecycleEventKind
  ) {
    self.timestampUTC = timestampUTC
    self.systemUptimeSeconds = systemUptimeSeconds
    self.kind = kind
  }

  public var anchor: SystemTimelineAnchor {
    SystemTimelineAnchor(
      timestampUTC: timestampUTC,
      systemUptimeSeconds: systemUptimeSeconds
    )
  }
}

public enum SystemTimelineAnalyzer {
  public static let rebootToleranceSeconds: TimeInterval = 1
  public static let clockChangeToleranceSeconds: TimeInterval = 2

  public static func launchEventKinds(
    previousSample: SystemTimelineAnchor?,
    current: SystemTimelineAnchor
  ) -> [SystemLifecycleEventKind] {
    guard let previousSample else {
      return [.launch]
    }
    if current.systemUptimeSeconds + rebootToleranceSeconds
      < previousSample.systemUptimeSeconds
    {
      return [.rebootDetected, .launch]
    }
    return [.launch]
  }

  public static func clockChanged(
    previous: SystemTimelineAnchor,
    current: SystemTimelineAnchor
  ) -> Bool {
    let uptimeDelta =
      current.systemUptimeSeconds - previous.systemUptimeSeconds
    guard uptimeDelta >= 0 else {
      return false
    }
    let wallClockDelta = current.timestampUTC.timeIntervalSince(
      previous.timestampUTC
    )
    return abs(wallClockDelta - uptimeDelta) > clockChangeToleranceSeconds
  }
}
