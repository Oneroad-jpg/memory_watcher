import Foundation

public enum MemoryResourceAuditDisposition: String, Codable, Sendable {
  case pending = "PENDING"
  case passed = "PASS"
  case hold = "HOLD"
}

public struct MemoryResourceAuditCheckpoint: Codable, Equatable, Sendable {
  public static let schemaVersion = 1

  public let schemaVersion: Int
  public let createdAtUTC: Date
  public let requiredEndUTC: Date
  public let targetProcessIdentifier: Int32
  public let databaseCapacityLimitBytes: UInt64
  public let forbiddenNetworkAPIMatchCount: Int
  public let forbiddenNotificationAPIMatchCount: Int
  public let initialIntegrityCheck: String

  public init(
    schemaVersion: Int = MemoryResourceAuditCheckpoint.schemaVersion,
    createdAtUTC: Date,
    requiredEndUTC: Date,
    targetProcessIdentifier: Int32,
    databaseCapacityLimitBytes: UInt64,
    forbiddenNetworkAPIMatchCount: Int,
    forbiddenNotificationAPIMatchCount: Int,
    initialIntegrityCheck: String
  ) {
    self.schemaVersion = schemaVersion
    self.createdAtUTC = createdAtUTC
    self.requiredEndUTC = requiredEndUTC
    self.targetProcessIdentifier = targetProcessIdentifier
    self.databaseCapacityLimitBytes = databaseCapacityLimitBytes
    self.forbiddenNetworkAPIMatchCount = forbiddenNetworkAPIMatchCount
    self.forbiddenNotificationAPIMatchCount =
      forbiddenNotificationAPIMatchCount
    self.initialIntegrityCheck = initialIntegrityCheck
  }
}

public struct MemoryResourceObservation: Codable, Equatable, Sendable {
  public let observedAtUTC: Date
  public let processIdentifier: Int32
  public let cumulativeCPUSeconds: TimeInterval
  public let residentMemoryBytes: UInt64
  public let internetSocketCount: Int
  public let databaseFileSetBytes: UInt64
  public let rawSampleCount: Int
  public let oneMinuteAggregateCount: Int
  public let fiveMinuteAggregateCount: Int

  public init(
    observedAtUTC: Date,
    processIdentifier: Int32,
    cumulativeCPUSeconds: TimeInterval,
    residentMemoryBytes: UInt64,
    internetSocketCount: Int,
    databaseFileSetBytes: UInt64,
    rawSampleCount: Int,
    oneMinuteAggregateCount: Int,
    fiveMinuteAggregateCount: Int
  ) {
    self.observedAtUTC = observedAtUTC
    self.processIdentifier = processIdentifier
    self.cumulativeCPUSeconds = cumulativeCPUSeconds
    self.residentMemoryBytes = residentMemoryBytes
    self.internetSocketCount = internetSocketCount
    self.databaseFileSetBytes = databaseFileSetBytes
    self.rawSampleCount = rawSampleCount
    self.oneMinuteAggregateCount = oneMinuteAggregateCount
    self.fiveMinuteAggregateCount = fiveMinuteAggregateCount
  }
}

public struct MemoryResourceAuditReport: Codable, Equatable, Sendable {
  public let disposition: MemoryResourceAuditDisposition
  public let generatedAtUTC: Date
  public let requiredEndUTC: Date
  public let elapsedSeconds: TimeInterval
  public let observationCount: Int
  public let observationSpanSeconds: TimeInterval
  public let averageCPUPercent: Double?
  public let firstResidentMemoryBytes: UInt64?
  public let lastResidentMemoryBytes: UInt64?
  public let minimumResidentMemoryBytes: UInt64?
  public let maximumResidentMemoryBytes: UInt64?
  public let residentMemoryMonotonicallyGrowing: Bool?
  public let maximumInternetSocketCount: Int
  public let maximumObservedDatabaseBytes: UInt64
  public let projectedRetainedDatabaseBytes: UInt64?
  public let databaseCapacityLimitBytes: UInt64
  public let integrityCheck: String
  public let forbiddenNetworkAPIMatchCount: Int
  public let forbiddenNotificationAPIMatchCount: Int
  public let awaitingRequirements: [String]
  public let holdReasons: [String]

  public init(
    disposition: MemoryResourceAuditDisposition,
    generatedAtUTC: Date,
    requiredEndUTC: Date,
    elapsedSeconds: TimeInterval,
    observationCount: Int,
    observationSpanSeconds: TimeInterval,
    averageCPUPercent: Double?,
    firstResidentMemoryBytes: UInt64?,
    lastResidentMemoryBytes: UInt64?,
    minimumResidentMemoryBytes: UInt64?,
    maximumResidentMemoryBytes: UInt64?,
    residentMemoryMonotonicallyGrowing: Bool?,
    maximumInternetSocketCount: Int,
    maximumObservedDatabaseBytes: UInt64,
    projectedRetainedDatabaseBytes: UInt64?,
    databaseCapacityLimitBytes: UInt64,
    integrityCheck: String,
    forbiddenNetworkAPIMatchCount: Int,
    forbiddenNotificationAPIMatchCount: Int,
    awaitingRequirements: [String],
    holdReasons: [String]
  ) {
    self.disposition = disposition
    self.generatedAtUTC = generatedAtUTC
    self.requiredEndUTC = requiredEndUTC
    self.elapsedSeconds = elapsedSeconds
    self.observationCount = observationCount
    self.observationSpanSeconds = observationSpanSeconds
    self.averageCPUPercent = averageCPUPercent
    self.firstResidentMemoryBytes = firstResidentMemoryBytes
    self.lastResidentMemoryBytes = lastResidentMemoryBytes
    self.minimumResidentMemoryBytes = minimumResidentMemoryBytes
    self.maximumResidentMemoryBytes = maximumResidentMemoryBytes
    self.residentMemoryMonotonicallyGrowing =
      residentMemoryMonotonicallyGrowing
    self.maximumInternetSocketCount = maximumInternetSocketCount
    self.maximumObservedDatabaseBytes = maximumObservedDatabaseBytes
    self.projectedRetainedDatabaseBytes = projectedRetainedDatabaseBytes
    self.databaseCapacityLimitBytes = databaseCapacityLimitBytes
    self.integrityCheck = integrityCheck
    self.forbiddenNetworkAPIMatchCount = forbiddenNetworkAPIMatchCount
    self.forbiddenNotificationAPIMatchCount =
      forbiddenNotificationAPIMatchCount
    self.awaitingRequirements = awaitingRequirements
    self.holdReasons = holdReasons
  }
}

public struct MemoryResourceAuditor: Sendable {
  public static let requiredDuration: TimeInterval = 24 * 60 * 60
  public static let requiredObservationCount = 4
  public static let averageCPUTargetPercent = 1.0
  public static let databaseCapacityLimitBytes: UInt64 = 64 * 1_024 * 1_024

  private static let maximumRawSampleCount = 24 * 60 * 60 / 5
  private static let maximumOneMinuteAggregateCount = 3 * 24 * 60
  private static let maximumFiveMinuteAggregateCount = 3 * 24 * 12
  private static let conservativeAdditionalRowBytes: UInt64 = 1_024

  public init() {}

  public func makeCheckpoint(
    processIdentifier: Int32,
    forbiddenNetworkAPIMatchCount: Int,
    forbiddenNotificationAPIMatchCount: Int,
    initialIntegrityCheck: String,
    now: Date = Date()
  ) -> MemoryResourceAuditCheckpoint {
    MemoryResourceAuditCheckpoint(
      createdAtUTC: now,
      requiredEndUTC: now.addingTimeInterval(Self.requiredDuration),
      targetProcessIdentifier: processIdentifier,
      databaseCapacityLimitBytes: Self.databaseCapacityLimitBytes,
      forbiddenNetworkAPIMatchCount: forbiddenNetworkAPIMatchCount,
      forbiddenNotificationAPIMatchCount: forbiddenNotificationAPIMatchCount,
      initialIntegrityCheck: initialIntegrityCheck
    )
  }

  public func makeReport(
    checkpoint: MemoryResourceAuditCheckpoint,
    observations: [MemoryResourceObservation],
    currentIntegrityCheck: String,
    now: Date = Date()
  ) -> MemoryResourceAuditReport {
    let elapsed = max(0, now.timeIntervalSince(checkpoint.createdAtUTC))
    guard checkpoint.schemaVersion == MemoryResourceAuditCheckpoint.schemaVersion else {
      return holdReport(
        checkpoint: checkpoint,
        now: now,
        elapsed: elapsed,
        currentIntegrityCheck: currentIntegrityCheck,
        reason: "unsupported resource checkpoint schema"
      )
    }

    let ordered = observations.sorted { $0.observedAtUTC < $1.observedAtUTC }
    let observationSpan = max(
      0,
      (ordered.last?.observedAtUTC ?? checkpoint.createdAtUTC)
        .timeIntervalSince(ordered.first?.observedAtUTC ?? checkpoint.createdAtUTC)
    )
    let averageCPU = Self.averageCPUPercent(from: ordered)
    let residentValues = ordered.map(\.residentMemoryBytes)
    let monotonicallyGrowing = Self.isMonotonicallyGrowing(residentValues)
    let maximumSockets = ordered.map(\.internetSocketCount).max() ?? 0
    let maximumDatabaseBytes = ordered.map(\.databaseFileSetBytes).max() ?? 0
    let projection = ordered.last.map(Self.projectedRetainedDatabaseBytes)

    var awaiting: [String] = []
    if now < checkpoint.requiredEndUTC {
      awaiting.append("24-hour duration")
    }
    if ordered.count < Self.requiredObservationCount {
      awaiting.append("four resource observations")
    }
    if observationSpan < Self.requiredDuration {
      awaiting.append("24-hour observation span")
    }
    let durationComplete = awaiting.isEmpty

    var holdReasons: [String] = []
    if checkpoint.targetProcessIdentifier <= 0
      || ordered.contains(where: {
        $0.processIdentifier != checkpoint.targetProcessIdentifier
      })
    {
      holdReasons.append("target process identity changed")
    }
    if !Self.observationsAreValid(ordered) {
      holdReasons.append("resource observation is invalid")
    }
    if checkpoint.initialIntegrityCheck != "ok" || currentIntegrityCheck != "ok" {
      holdReasons.append("SQLite integrity check failed")
    }
    if checkpoint.forbiddenNetworkAPIMatchCount > 0 {
      holdReasons.append("network API exists in product source")
    }
    if checkpoint.forbiddenNotificationAPIMatchCount > 0 {
      holdReasons.append("notification API exists in product source")
    }
    if maximumSockets > 0 {
      holdReasons.append("target process opened an Internet socket")
    }
    if let projection, projection > checkpoint.databaseCapacityLimitBytes {
      holdReasons.append("projected retained database exceeds capacity limit")
    }
    if !durationComplete,
      let minimumFinalCPU = Self.minimumFinalAverageCPUPercent(from: ordered),
      minimumFinalCPU >= Self.averageCPUTargetPercent
    {
      holdReasons.append("average idle CPU target is no longer reachable")
    }

    if durationComplete, let averageCPU,
      averageCPU >= Self.averageCPUTargetPercent
    {
      holdReasons.append("average idle CPU target was not met")
    }
    if durationComplete, monotonicallyGrowing == true {
      holdReasons.append("resident memory grew monotonically")
    }

    let disposition: MemoryResourceAuditDisposition
    if !holdReasons.isEmpty {
      disposition = .hold
    } else if !awaiting.isEmpty {
      disposition = .pending
    } else {
      disposition = .passed
    }
    return MemoryResourceAuditReport(
      disposition: disposition,
      generatedAtUTC: now,
      requiredEndUTC: checkpoint.requiredEndUTC,
      elapsedSeconds: elapsed,
      observationCount: ordered.count,
      observationSpanSeconds: observationSpan,
      averageCPUPercent: averageCPU,
      firstResidentMemoryBytes: residentValues.first,
      lastResidentMemoryBytes: residentValues.last,
      minimumResidentMemoryBytes: residentValues.min(),
      maximumResidentMemoryBytes: residentValues.max(),
      residentMemoryMonotonicallyGrowing: monotonicallyGrowing,
      maximumInternetSocketCount: maximumSockets,
      maximumObservedDatabaseBytes: maximumDatabaseBytes,
      projectedRetainedDatabaseBytes: projection,
      databaseCapacityLimitBytes: checkpoint.databaseCapacityLimitBytes,
      integrityCheck: currentIntegrityCheck,
      forbiddenNetworkAPIMatchCount: checkpoint.forbiddenNetworkAPIMatchCount,
      forbiddenNotificationAPIMatchCount:
        checkpoint.forbiddenNotificationAPIMatchCount,
      awaitingRequirements: awaiting,
      holdReasons: holdReasons
    )
  }

  public static func projectedRetainedDatabaseBytes(
    from observation: MemoryResourceObservation
  ) -> UInt64 {
    let currentPrimaryRows = max(
      0,
      observation.rawSampleCount
        + observation.oneMinuteAggregateCount
        + observation.fiveMinuteAggregateCount
    )
    let maximumPrimaryRows =
      maximumRawSampleCount
      + maximumOneMinuteAggregateCount
      + maximumFiveMinuteAggregateCount
    let remainingRows = UInt64(max(0, maximumPrimaryRows - currentPrimaryRows))
    let additionalBytes = remainingRows.multipliedReportingOverflow(
      by: conservativeAdditionalRowBytes
    )
    guard !additionalBytes.overflow else {
      return UInt64.max
    }
    let projected = observation.databaseFileSetBytes.addingReportingOverflow(
      additionalBytes.partialValue
    )
    return projected.overflow ? UInt64.max : projected.partialValue
  }

  private static func averageCPUPercent(
    from observations: [MemoryResourceObservation]
  ) -> Double? {
    guard let first = observations.first, let last = observations.last else {
      return nil
    }
    let wallSeconds = last.observedAtUTC.timeIntervalSince(first.observedAtUTC)
    let cpuSeconds = last.cumulativeCPUSeconds - first.cumulativeCPUSeconds
    guard wallSeconds > 0, cpuSeconds >= 0 else {
      return nil
    }
    return cpuSeconds / wallSeconds * 100
  }

  private static func minimumFinalAverageCPUPercent(
    from observations: [MemoryResourceObservation]
  ) -> Double? {
    guard let first = observations.first, let last = observations.last else {
      return nil
    }
    let cpuSeconds = last.cumulativeCPUSeconds - first.cumulativeCPUSeconds
    guard cpuSeconds >= 0 else {
      return nil
    }
    return cpuSeconds / requiredDuration * 100
  }

  private static func isMonotonicallyGrowing(_ values: [UInt64]) -> Bool? {
    guard values.count >= requiredObservationCount else {
      return nil
    }
    let neverDecreased = zip(values, values.dropFirst()).allSatisfy { pair in
      pair.1 >= pair.0
    }
    return neverDecreased && values.last! > values.first!
  }

  private static func observationsAreValid(
    _ observations: [MemoryResourceObservation]
  ) -> Bool {
    guard !observations.isEmpty else {
      return true
    }
    var previous: MemoryResourceObservation?
    for observation in observations {
      guard
        observation.processIdentifier > 0,
        observation.cumulativeCPUSeconds.isFinite,
        observation.cumulativeCPUSeconds >= 0,
        observation.residentMemoryBytes > 0,
        observation.internetSocketCount >= 0,
        observation.databaseFileSetBytes > 0,
        observation.rawSampleCount >= 0,
        observation.oneMinuteAggregateCount >= 0,
        observation.fiveMinuteAggregateCount >= 0
      else {
        return false
      }
      if let previous {
        guard
          observation.observedAtUTC > previous.observedAtUTC,
          observation.cumulativeCPUSeconds >= previous.cumulativeCPUSeconds
        else {
          return false
        }
      }
      previous = observation
    }
    return true
  }

  private func holdReport(
    checkpoint: MemoryResourceAuditCheckpoint,
    now: Date,
    elapsed: TimeInterval,
    currentIntegrityCheck: String,
    reason: String
  ) -> MemoryResourceAuditReport {
    MemoryResourceAuditReport(
      disposition: .hold,
      generatedAtUTC: now,
      requiredEndUTC: checkpoint.requiredEndUTC,
      elapsedSeconds: elapsed,
      observationCount: 0,
      observationSpanSeconds: 0,
      averageCPUPercent: nil,
      firstResidentMemoryBytes: nil,
      lastResidentMemoryBytes: nil,
      minimumResidentMemoryBytes: nil,
      maximumResidentMemoryBytes: nil,
      residentMemoryMonotonicallyGrowing: nil,
      maximumInternetSocketCount: 0,
      maximumObservedDatabaseBytes: 0,
      projectedRetainedDatabaseBytes: nil,
      databaseCapacityLimitBytes: checkpoint.databaseCapacityLimitBytes,
      integrityCheck: currentIntegrityCheck,
      forbiddenNetworkAPIMatchCount: checkpoint.forbiddenNetworkAPIMatchCount,
      forbiddenNotificationAPIMatchCount:
        checkpoint.forbiddenNotificationAPIMatchCount,
      awaitingRequirements: [],
      holdReasons: [reason]
    )
  }
}
