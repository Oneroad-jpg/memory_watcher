import Foundation

public enum MemoryRunAuditDisposition: String, Codable, Sendable {
  case pending = "PENDING"
  case passed = "PASS"
  case hold = "HOLD"
}

public struct MemoryRunAuditCheckpoint: Codable, Equatable, Sendable {
  public static let schemaVersion = 1

  public let schemaVersion: Int
  public let createdAtUTC: Date
  public let auditStartUTC: Date
  public let requiredEndUTC: Date
  public let initialSampleCount: Int
  public let historyMarkerUTC: Date?
  public let initialIntegrityCheck: String

  public init(
    schemaVersion: Int = MemoryRunAuditCheckpoint.schemaVersion,
    createdAtUTC: Date,
    auditStartUTC: Date,
    requiredEndUTC: Date,
    initialSampleCount: Int,
    historyMarkerUTC: Date?,
    initialIntegrityCheck: String
  ) {
    self.schemaVersion = schemaVersion
    self.createdAtUTC = createdAtUTC
    self.auditStartUTC = auditStartUTC
    self.requiredEndUTC = requiredEndUTC
    self.initialSampleCount = initialSampleCount
    self.historyMarkerUTC = historyMarkerUTC
    self.initialIntegrityCheck = initialIntegrityCheck
  }
}

public struct MemoryAuditMetricValues: Codable, Equatable, Sendable {
  public let physicalMemoryBytes: Double
  public let memoryUsedBytes: Double
  public let wiredBytes: Double
  public let compressedBytes: Double
  public let cachedFilesBytes: Double
  public let swapUsedBytes: Double

  public init(
    physicalMemoryBytes: Double,
    memoryUsedBytes: Double,
    wiredBytes: Double,
    compressedBytes: Double,
    cachedFilesBytes: Double,
    swapUsedBytes: Double
  ) {
    self.physicalMemoryBytes = physicalMemoryBytes
    self.memoryUsedBytes = memoryUsedBytes
    self.wiredBytes = wiredBytes
    self.compressedBytes = compressedBytes
    self.cachedFilesBytes = cachedFilesBytes
    self.swapUsedBytes = swapUsedBytes
  }

  fileprivate var allValuesAreValid: Bool {
    [
      physicalMemoryBytes,
      memoryUsedBytes,
      wiredBytes,
      compressedBytes,
      cachedFilesBytes,
      swapUsedBytes,
    ].allSatisfy { $0.isFinite && $0 >= 0 }
  }
}

public struct MemoryActivityMonitorComparison: Codable, Equatable, Sendable {
  public let label: String
  public let observedAtUTC: Date
  public let memoryWatcherSampleUTC: Date
  public let activityMonitor: MemoryAuditMetricValues
  public let memoryWatcher: MemoryAuditMetricValues
  public let differencesExplained: Bool
  public let explanation: String

  public init(
    label: String,
    observedAtUTC: Date,
    memoryWatcherSampleUTC: Date,
    activityMonitor: MemoryAuditMetricValues,
    memoryWatcher: MemoryAuditMetricValues,
    differencesExplained: Bool,
    explanation: String
  ) {
    self.label = label
    self.observedAtUTC = observedAtUTC
    self.memoryWatcherSampleUTC = memoryWatcherSampleUTC
    self.activityMonitor = activityMonitor
    self.memoryWatcher = memoryWatcher
    self.differencesExplained = differencesExplained
    self.explanation = explanation
  }

  public var sampleSkewSeconds: TimeInterval {
    abs(observedAtUTC.timeIntervalSince(memoryWatcherSampleUTC))
  }
}

public struct MemoryRunAuditReport: Codable, Equatable, Sendable {
  public let disposition: MemoryRunAuditDisposition
  public let generatedAtUTC: Date
  public let auditStartUTC: Date
  public let requiredEndUTC: Date
  public let elapsedSeconds: TimeInterval
  public let expectedSampleSlotCount: Int
  public let recordedSampleCount: Int
  public let explicitGapCount: Int
  public let boundaryAllowanceSlotCount: Int
  public let unexplainedMissingSlotCount: Int
  public let completedSleepIntervalCount: Int
  public let samplesInsideSleepCount: Int
  public let unexpectedLaunchCount: Int
  public let rebootCount: Int
  public let clockChangeCount: Int
  public let activityMonitorComparisonCount: Int
  public let rejectedActivityMonitorComparisonCount: Int
  public let historyMarkerReadable: Bool
  public let integrityCheck: String
  public let awaitingRequirements: [String]
  public let holdReasons: [String]

  public init(
    disposition: MemoryRunAuditDisposition,
    generatedAtUTC: Date,
    auditStartUTC: Date,
    requiredEndUTC: Date,
    elapsedSeconds: TimeInterval,
    expectedSampleSlotCount: Int,
    recordedSampleCount: Int,
    explicitGapCount: Int,
    boundaryAllowanceSlotCount: Int,
    unexplainedMissingSlotCount: Int,
    completedSleepIntervalCount: Int,
    samplesInsideSleepCount: Int,
    unexpectedLaunchCount: Int,
    rebootCount: Int,
    clockChangeCount: Int,
    activityMonitorComparisonCount: Int,
    rejectedActivityMonitorComparisonCount: Int,
    historyMarkerReadable: Bool,
    integrityCheck: String,
    awaitingRequirements: [String],
    holdReasons: [String]
  ) {
    self.disposition = disposition
    self.generatedAtUTC = generatedAtUTC
    self.auditStartUTC = auditStartUTC
    self.requiredEndUTC = requiredEndUTC
    self.elapsedSeconds = elapsedSeconds
    self.expectedSampleSlotCount = expectedSampleSlotCount
    self.recordedSampleCount = recordedSampleCount
    self.explicitGapCount = explicitGapCount
    self.boundaryAllowanceSlotCount = boundaryAllowanceSlotCount
    self.unexplainedMissingSlotCount = unexplainedMissingSlotCount
    self.completedSleepIntervalCount = completedSleepIntervalCount
    self.samplesInsideSleepCount = samplesInsideSleepCount
    self.unexpectedLaunchCount = unexpectedLaunchCount
    self.rebootCount = rebootCount
    self.clockChangeCount = clockChangeCount
    self.activityMonitorComparisonCount = activityMonitorComparisonCount
    self.rejectedActivityMonitorComparisonCount =
      rejectedActivityMonitorComparisonCount
    self.historyMarkerReadable = historyMarkerReadable
    self.integrityCheck = integrityCheck
    self.awaitingRequirements = awaitingRequirements
    self.holdReasons = holdReasons
  }
}

public struct MemoryRunAuditor: Sendable {
  public static let requiredDuration: TimeInterval = 24 * 60 * 60
  public static let requiredActivityMonitorComparisons = 3

  private let database: MemoryWatcherDatabase

  public init(database: MemoryWatcherDatabase) {
    self.database = database
  }

  public func makeCheckpoint(
    now: Date = Date()
  ) throws -> MemoryRunAuditCheckpoint {
    let auditStart = Self.nextFullMinute(after: now)
    return MemoryRunAuditCheckpoint(
      createdAtUTC: now,
      auditStartUTC: auditStart,
      requiredEndUTC: auditStart.addingTimeInterval(Self.requiredDuration),
      initialSampleCount: try database.sampleCount(),
      historyMarkerUTC: try database.fetchSamples().last?.timestampUTC,
      initialIntegrityCheck: try database.integrityCheck()
    )
  }

  public func makeReport(
    checkpoint: MemoryRunAuditCheckpoint,
    now: Date = Date(),
    activityMonitorComparisons: [MemoryActivityMonitorComparison]
  ) throws -> MemoryRunAuditReport {
    let elapsed = max(0, now.timeIntervalSince(checkpoint.auditStartUTC))
    guard checkpoint.schemaVersion == MemoryRunAuditCheckpoint.schemaVersion else {
      return emptyHoldReport(
        checkpoint: checkpoint,
        now: now,
        elapsed: elapsed,
        comparisonCount: 0,
        reason: "unsupported checkpoint schema"
      )
    }

    let analysisEnd = min(now, checkpoint.requiredEndUTC)
    let samples = try database.fetchSamples()
    let minuteAggregates = try database.fetchAggregates(resolution: .oneMinute)
    let gaps = try database.fetchSamplingGaps().filter {
      $0.timestampUTC >= checkpoint.auditStartUTC
        && $0.timestampUTC < analysisEnd
    }
    let lifecycleEvents = try database.fetchLifecycleEvents()
    let sleepIntervals = Self.sleepIntervals(
      from: lifecycleEvents,
      rangeStart: checkpoint.auditStartUTC,
      rangeEnd: analysisEnd
    )
    let activeIntervals = Self.activeIntervals(
      rangeStart: checkpoint.auditStartUTC,
      rangeEnd: analysisEnd,
      sleepIntervals: sleepIntervals
    )
    let expectedSlots = activeIntervals.reduce(into: 0) { total, interval in
      total += Int(floor(interval.duration / MemoryWatcherFoundation.sampleInterval))
    }
    let sampleCount = Self.recordedSampleCount(
      samples: samples,
      aggregates: minuteAggregates,
      rangeStart: checkpoint.auditStartUTC,
      rangeEnd: analysisEnd
    )
    let boundaryAllowance = activeIntervals.count
    let unexplainedMissing = max(
      0,
      expectedSlots - sampleCount - gaps.count - boundaryAllowance
    )
    let samplesInsideSleep = Self.samplesInsideSleepCount(
      samples: samples,
      aggregates: minuteAggregates,
      sleepIntervals: sleepIntervals
    )
    let targetEvents = lifecycleEvents.filter {
      $0.timestampUTC >= checkpoint.auditStartUTC
        && $0.timestampUTC < analysisEnd
    }
    let unexpectedLaunches = targetEvents.count { $0.kind == .launch }
    let reboots = targetEvents.count { $0.kind == .rebootDetected }
    let clockChanges = targetEvents.count { $0.kind == .clockChanged }
    let integrity = try database.integrityCheck()
    let historyMarkerReadable = Self.historyMarkerIsReadable(
      checkpoint.historyMarkerUTC,
      samples: samples,
      aggregates: minuteAggregates
    )
    let validComparisons = activityMonitorComparisons.filter {
      Self.comparisonIsValid(
        $0,
        rangeStart: checkpoint.auditStartUTC,
        rangeEnd: analysisEnd
      )
    }
    let rejectedComparisonCount =
      activityMonitorComparisons.count - validComparisons.count

    var awaiting: [String] = []
    if now < checkpoint.requiredEndUTC {
      awaiting.append("24-hour duration")
    }
    if sleepIntervals.isEmpty {
      awaiting.append("completed sleep and wake interval")
    }
    if validComparisons.count < Self.requiredActivityMonitorComparisons {
      awaiting.append("three Activity Monitor comparisons")
    }

    var holdReasons: [String] = []
    if checkpoint.initialIntegrityCheck != "ok" || integrity != "ok" {
      holdReasons.append("SQLite integrity check failed")
    }
    if unexplainedMissing > 0 {
      holdReasons.append("unexplained measurement slots remain")
    }
    if samplesInsideSleep > 0 {
      holdReasons.append("samples exist inside a completed sleep interval")
    }
    if unexpectedLaunches > 0 {
      holdReasons.append("application relaunched during the audit interval")
    }
    if reboots > 0 {
      holdReasons.append("system rebooted during the audit interval")
    }
    if !historyMarkerReadable {
      holdReasons.append("history marker from checkpoint is no longer readable")
    }
    if validComparisons.contains(where: { !$0.differencesExplained }) {
      holdReasons.append("Activity Monitor difference remains unexplained")
    }

    let disposition: MemoryRunAuditDisposition
    if !holdReasons.isEmpty {
      disposition = .hold
    } else if !awaiting.isEmpty {
      disposition = .pending
    } else {
      disposition = .passed
    }
    return MemoryRunAuditReport(
      disposition: disposition,
      generatedAtUTC: now,
      auditStartUTC: checkpoint.auditStartUTC,
      requiredEndUTC: checkpoint.requiredEndUTC,
      elapsedSeconds: elapsed,
      expectedSampleSlotCount: expectedSlots,
      recordedSampleCount: sampleCount,
      explicitGapCount: gaps.count,
      boundaryAllowanceSlotCount: boundaryAllowance,
      unexplainedMissingSlotCount: unexplainedMissing,
      completedSleepIntervalCount: sleepIntervals.count,
      samplesInsideSleepCount: samplesInsideSleep,
      unexpectedLaunchCount: unexpectedLaunches,
      rebootCount: reboots,
      clockChangeCount: clockChanges,
      activityMonitorComparisonCount: validComparisons.count,
      rejectedActivityMonitorComparisonCount: rejectedComparisonCount,
      historyMarkerReadable: historyMarkerReadable,
      integrityCheck: integrity,
      awaitingRequirements: awaiting,
      holdReasons: holdReasons
    )
  }

  private func emptyHoldReport(
    checkpoint: MemoryRunAuditCheckpoint,
    now: Date,
    elapsed: TimeInterval,
    comparisonCount: Int,
    reason: String
  ) -> MemoryRunAuditReport {
    MemoryRunAuditReport(
      disposition: .hold,
      generatedAtUTC: now,
      auditStartUTC: checkpoint.auditStartUTC,
      requiredEndUTC: checkpoint.requiredEndUTC,
      elapsedSeconds: elapsed,
      expectedSampleSlotCount: 0,
      recordedSampleCount: 0,
      explicitGapCount: 0,
      boundaryAllowanceSlotCount: 0,
      unexplainedMissingSlotCount: 0,
      completedSleepIntervalCount: 0,
      samplesInsideSleepCount: 0,
      unexpectedLaunchCount: 0,
      rebootCount: 0,
      clockChangeCount: 0,
      activityMonitorComparisonCount: comparisonCount,
      rejectedActivityMonitorComparisonCount: 0,
      historyMarkerReadable: false,
      integrityCheck: "unknown",
      awaitingRequirements: [],
      holdReasons: [reason]
    )
  }

  private static func nextFullMinute(after date: Date) -> Date {
    let seconds = date.timeIntervalSince1970
    return Date(timeIntervalSince1970: (floor(seconds / 60) + 1) * 60)
  }

  private static func recordedSampleCount(
    samples: [MemorySample],
    aggregates: [MemoryHistoryAggregate],
    rangeStart: Date,
    rangeEnd: Date
  ) -> Int {
    let aggregateCounts: [Date: Int] = Dictionary(
      uniqueKeysWithValues: aggregates.compactMap { aggregate in
        guard
          aggregate.bucketStartUTC >= rangeStart,
          aggregate.bucketStartUTC < rangeEnd
        else {
          return nil
        }
        return (aggregate.bucketStartUTC, aggregate.sampleCount)
      }
    )
    let rawCounts = Dictionary(
      grouping: samples.filter {
        $0.timestampUTC >= rangeStart && $0.timestampUTC < rangeEnd
      }
    ) { minuteStart(for: $0.timestampUTC) }.mapValues(\.count)
    var total = 0
    var cursor = rangeStart
    while cursor < rangeEnd {
      total += aggregateCounts[cursor] ?? rawCounts[cursor] ?? 0
      cursor = cursor.addingTimeInterval(60)
    }
    return total
  }

  private static func samplesInsideSleepCount(
    samples: [MemorySample],
    aggregates: [MemoryHistoryAggregate],
    sleepIntervals: [AuditInterval]
  ) -> Int {
    let rawBuckets = Set(samples.map { minuteStart(for: $0.timestampUTC) })
    let rawCount = samples.count { sample in
      sleepIntervals.contains { interval in
        sample.timestampUTC > interval.start && sample.timestampUTC < interval.end
      }
    }
    let aggregateCount = aggregates.reduce(into: 0) { total, aggregate in
      let bucketEnd = aggregate.bucketStartUTC.addingTimeInterval(60)
      let fullyInsideSleep = sleepIntervals.contains { interval in
        aggregate.bucketStartUTC >= interval.start && bucketEnd <= interval.end
      }
      if fullyInsideSleep && !rawBuckets.contains(aggregate.bucketStartUTC) {
        total += aggregate.sampleCount
      }
    }
    return rawCount + aggregateCount
  }

  private static func historyMarkerIsReadable(
    _ marker: Date?,
    samples: [MemorySample],
    aggregates: [MemoryHistoryAggregate]
  ) -> Bool {
    guard let marker else {
      return true
    }
    if samples.contains(where: { $0.timestampUTC == marker }) {
      return true
    }
    let bucket = minuteStart(for: marker)
    return aggregates.contains {
      $0.bucketStartUTC == bucket && $0.sampleCount > 0
    }
  }

  private static func comparisonIsValid(
    _ comparison: MemoryActivityMonitorComparison,
    rangeStart: Date,
    rangeEnd: Date
  ) -> Bool {
    comparison.observedAtUTC >= rangeStart
      && comparison.observedAtUTC <= rangeEnd
      && comparison.sampleSkewSeconds <= 10
      && !comparison.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !comparison.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
      && comparison.activityMonitor.allValuesAreValid
      && comparison.memoryWatcher.allValuesAreValid
  }

  private static func sleepIntervals(
    from events: [SystemLifecycleEvent],
    rangeStart: Date,
    rangeEnd: Date
  ) -> [AuditInterval] {
    var openSleep: Date?
    var intervals: [AuditInterval] = []
    for event in events.sorted(by: { $0.timestampUTC < $1.timestampUTC }) {
      switch event.kind {
      case .sleep:
        if openSleep == nil {
          openSleep = event.timestampUTC
        }
      case .wake:
        if let start = openSleep, event.timestampUTC > start {
          let clippedStart = max(start, rangeStart)
          let clippedEnd = min(event.timestampUTC, rangeEnd)
          if clippedStart < clippedEnd {
            intervals.append(AuditInterval(start: clippedStart, end: clippedEnd))
          }
        }
        openSleep = nil
      case .launch, .clockChanged, .rebootDetected:
        continue
      }
    }
    return intervals
  }

  private static func activeIntervals(
    rangeStart: Date,
    rangeEnd: Date,
    sleepIntervals: [AuditInterval]
  ) -> [AuditInterval] {
    guard rangeStart < rangeEnd else {
      return []
    }
    var cursor = rangeStart
    var intervals: [AuditInterval] = []
    for sleep in sleepIntervals.sorted(by: { $0.start < $1.start }) {
      if cursor < sleep.start {
        intervals.append(AuditInterval(start: cursor, end: sleep.start))
      }
      cursor = max(cursor, sleep.end)
    }
    if cursor < rangeEnd {
      intervals.append(AuditInterval(start: cursor, end: rangeEnd))
    }
    return intervals
  }

  private static func minuteStart(for date: Date) -> Date {
    Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
  }
}

private struct AuditInterval {
  let start: Date
  let end: Date

  var duration: TimeInterval {
    end.timeIntervalSince(start)
  }
}
