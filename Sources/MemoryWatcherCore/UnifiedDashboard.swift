import Foundation

public enum DashboardValueStatus: String, Equatable, Sendable {
  case current
  case stale
  case unknown
  case unavailable
  case invalid
}

public struct DashboardMemoryPresentation: Equatable, Sendable {
  public let status: DashboardValueStatus
  public let usedBytes: UInt64?
  public let measuredAtUTC: Date?

  public init(
    status: DashboardValueStatus,
    usedBytes: UInt64?,
    measuredAtUTC: Date?
  ) {
    self.status = status
    self.usedBytes = usedBytes
    self.measuredAtUTC = measuredAtUTC
  }
}

public struct DashboardMemoryTracker: Equatable, Sendable {
  public static let staleInterval: TimeInterval = 15

  private var usedBytes: UInt64?
  private var measuredAtUTC: Date?

  public init() {}

  public mutating func receive(_ sample: MemorySample) {
    usedBytes = sample.estimatedMemoryUsedBytes
    measuredAtUTC = sample.timestampUTC
  }

  public func presentation(
    at now: Date,
    runState: MemoryMonitoringRunState
  ) -> DashboardMemoryPresentation {
    guard let usedBytes, let measuredAtUTC else {
      return DashboardMemoryPresentation(
        status: .unknown,
        usedBytes: nil,
        measuredAtUTC: nil
      )
    }
    let age = now.timeIntervalSince(measuredAtUTC)
    guard age.isFinite, age >= 0 else {
      return DashboardMemoryPresentation(
        status: .invalid,
        usedBytes: nil,
        measuredAtUTC: measuredAtUTC
      )
    }
    let status: DashboardValueStatus =
      runState == .running && age < Self.staleInterval
      ? .current
      : .stale
    return DashboardMemoryPresentation(
      status: status,
      usedBytes: usedBytes,
      measuredAtUTC: measuredAtUTC
    )
  }
}

public struct DashboardCPUPresentation: Equatable, Sendable {
  public let status: DashboardValueStatus
  public let percent: Double?
  public let intervalStartUTC: Date?
  public let intervalEndUTC: Date?
  public let quality: CPUUtilizationQuality
  public let showsFinalValue: Bool

  public init(
    status: DashboardValueStatus,
    percent: Double?,
    intervalStartUTC: Date?,
    intervalEndUTC: Date?,
    quality: CPUUtilizationQuality,
    showsFinalValue: Bool
  ) {
    self.status = status
    self.percent = percent
    self.intervalStartUTC = intervalStartUTC
    self.intervalEndUTC = intervalEndUTC
    self.quality = quality
    self.showsFinalValue = showsFinalValue
  }
}

public struct DashboardCPUTracker: Equatable, Sendable {
  public static let staleInterval: TimeInterval = 15

  private var latestQuality: CPUUtilizationQuality = .firstDeltaUnknown
  private var latestEndUTC: Date?
  private var latestIsInvalid = false
  private var measuredPercent: Double?
  private var measuredStartUTC: Date?
  private var measuredEndUTC: Date?

  public init() {}

  public mutating func receive(_ sample: TotalCPUSample) {
    receive(
      percent: sample.utilizationPercent,
      intervalStartUTC: sample.intervalStartUTC,
      intervalEndUTC: sample.intervalEndUTC,
      quality: sample.quality
    )
  }

  public mutating func receive(_ sample: LogicalCPUSample) {
    receive(
      percent: sample.utilizationPercent,
      intervalStartUTC: sample.intervalStartUTC,
      intervalEndUTC: sample.intervalEndUTC,
      quality: sample.quality
    )
  }

  public mutating func receive(
    percent: Double?,
    intervalStartUTC: Date?,
    intervalEndUTC: Date,
    quality: CPUUtilizationQuality
  ) {
    latestQuality = quality
    latestEndUTC = intervalEndUTC
    latestIsInvalid = false
    guard quality == .measured else { return }
    guard
      let percent,
      percent.isFinite,
      (0...100).contains(percent),
      let intervalStartUTC,
      intervalStartUTC <= intervalEndUTC
    else {
      latestIsInvalid = true
      return
    }
    measuredPercent = percent
    measuredStartUTC = intervalStartUTC
    measuredEndUTC = intervalEndUTC
  }

  public func presentation(
    at now: Date,
    runState: MemoryMonitoringRunState
  ) -> DashboardCPUPresentation {
    if latestIsInvalid {
      return presentation(status: .invalid, showsFinalValue: false)
    }
    guard latestQuality == .measured else {
      return presentation(
        status: latestQuality == .unavailable ? .unavailable : .unknown,
        showsFinalValue: measuredPercent != nil
      )
    }
    guard let measuredEndUTC else {
      return presentation(status: .invalid, showsFinalValue: false)
    }
    let age = now.timeIntervalSince(measuredEndUTC)
    guard age.isFinite, age >= 0 else {
      return presentation(status: .invalid, showsFinalValue: false)
    }
    let status: DashboardValueStatus =
      runState == .running && age < Self.staleInterval
      ? .current
      : .stale
    return presentation(status: status, showsFinalValue: status == .stale)
  }

  private func presentation(
    status: DashboardValueStatus,
    showsFinalValue: Bool
  ) -> DashboardCPUPresentation {
    DashboardCPUPresentation(
      status: status,
      percent: measuredPercent,
      intervalStartUTC: measuredStartUTC,
      intervalEndUTC: measuredEndUTC ?? latestEndUTC,
      quality: latestQuality,
      showsFinalValue: showsFinalValue
    )
  }
}

public struct DashboardLogicalCPUPresentation: Equatable, Sendable {
  public let topology: LogicalCPUTopology
  public let cpuIndex: Int
  public let value: DashboardCPUPresentation

  public init(
    topology: LogicalCPUTopology,
    cpuIndex: Int,
    value: DashboardCPUPresentation
  ) {
    self.topology = topology
    self.cpuIndex = cpuIndex
    self.value = value
  }

  public var displayName: String { "CPU \(cpuIndex + 1)" }
}

public struct DashboardHistoryGenerationGate: Equatable, Sendable {
  public private(set) var currentGeneration: UInt64 = 0

  public init() {}

  public mutating func issue() -> UInt64 {
    currentGeneration =
      currentGeneration == UInt64.max ? 1 : currentGeneration + 1
    return currentGeneration
  }

  public func accepts(_ generation: UInt64) -> Bool {
    generation == currentGeneration
  }
}

public enum DashboardLayoutMode: String, Equatable, Sendable {
  case columns
  case stacked
}

public enum DashboardLayoutPolicy {
  public static let columnMinimumWidth = 960.0

  public static func mode(forAvailableWidth width: Double) -> DashboardLayoutMode {
    width >= columnMinimumWidth ? .columns : .stacked
  }
}

public enum DashboardDownsamplingPolicy {
  public static func retainedIndices(
    segmentIdentifiers: [String],
    limit: Int
  ) -> [Int] {
    guard segmentIdentifiers.count > limit, limit > 2 else {
      return Array(segmentIdentifiers.indices)
    }
    let step = Double(segmentIdentifiers.count - 1) / Double(limit - 1)
    var indexes = Set(
      (0..<limit).map { Int((Double($0) * step).rounded()) }
    )
    indexes.insert(0)
    indexes.insert(segmentIdentifiers.count - 1)
    for index in 1..<segmentIdentifiers.count
    where segmentIdentifiers[index] != segmentIdentifiers[index - 1] {
      indexes.insert(index - 1)
      indexes.insert(index)
    }
    return indexes.sorted()
  }
}

public enum DashboardChartPointBudget {
  public static let primarySeriesLimit = 400
  public static let logicalTotalLimit = 400
  public static let logicalMinimumPerSeries = 10

  public static func logicalPerSeriesLimit(seriesCount: Int) -> Int {
    guard seriesCount > 0 else { return 0 }
    return max(logicalMinimumPerSeries, logicalTotalLimit / seriesCount)
  }
}

public struct DashboardLogicalCPUHistorySeries: Equatable, Sendable {
  public let id: String
  public let cpuIndex: Int
  public let displayName: String
  public let points: [LogicalCPUHistoryPoint]

  public init(
    id: String,
    cpuIndex: Int,
    displayName: String,
    points: [LogicalCPUHistoryPoint]
  ) {
    self.id = id
    self.cpuIndex = cpuIndex
    self.displayName = displayName
    self.points = points
  }
}

public struct DashboardHistoryRenderSnapshot: Equatable, Sendable {
  public let period: MemoryHistoryPeriod
  public let startUTC: Date
  public let endUTC: Date
  public let memoryPoints: [MemoryHistoryPoint]
  public let pressureIntervals: [MemoryPressureInterval]
  public let sleepIntervals: [SystemSleepInterval]
  public let totalCPUPoints: [TotalCPUHistoryPoint]
  public let logicalCPUSeries: [DashboardLogicalCPUHistorySeries]

  public init(snapshot: MemoryHistorySnapshot) {
    period = snapshot.period
    startUTC = snapshot.startUTC
    endUTC = snapshot.endUTC
    pressureIntervals = snapshot.pressureIntervals
    sleepIntervals = snapshot.sleepIntervals
    memoryPoints = Self.retained(
      snapshot.points,
      segmentIdentifiers: snapshot.points.map {
        String($0.continuitySegment)
      },
      limit: DashboardChartPointBudget.primarySeriesLimit
    )
    totalCPUPoints = Self.retained(
      snapshot.cpuHistory.totalPoints,
      segmentIdentifiers: snapshot.cpuHistory.totalPoints.map {
        String($0.continuitySegment)
      },
      limit: DashboardChartPointBudget.primarySeriesLimit
    )

    let groups = Dictionary(
      grouping: snapshot.cpuHistory.logicalPoints,
      by: \.cpuIndex
    )
    let perSeriesLimit = DashboardChartPointBudget.logicalPerSeriesLimit(
      seriesCount: groups.count
    )
    logicalCPUSeries = groups.compactMap { cpuIndex, points in
      let ordered = points.sorted { $0.timestampUTC < $1.timestampUTC }
      guard let first = ordered.first else { return nil }
      return DashboardLogicalCPUHistorySeries(
        id: String(cpuIndex),
        cpuIndex: cpuIndex,
        displayName: first.displayName,
        points: Self.retained(
          ordered,
          segmentIdentifiers: ordered.map(\.seriesIdentifier),
          limit: perSeriesLimit
        )
      )
    }.sorted { lhs, rhs in
      lhs.cpuIndex < rhs.cpuIndex
    }
  }

  public var isEmpty: Bool {
    memoryPoints.isEmpty
      && totalCPUPoints.isEmpty
      && logicalCPUSeries.allSatisfy { $0.points.isEmpty }
  }

  private static func retained<Element>(
    _ values: [Element],
    segmentIdentifiers: [String],
    limit: Int
  ) -> [Element] {
    DashboardDownsamplingPolicy.retainedIndices(
      segmentIdentifiers: segmentIdentifiers,
      limit: limit
    ).map { values[$0] }
  }
}

public struct DashboardMemoryGapAudit: Equatable, Sendable {
  public let explicitGapCount: Int
  public let reasonCounts: [String: Int]
  public let monitoringFailureDelta: UInt64?
  public let isValid: Bool

  public init(
    explicitGapCount: Int,
    reasonCounts: [String: Int],
    monitoringFailureDelta: UInt64?,
    isValid: Bool
  ) {
    self.explicitGapCount = explicitGapCount
    self.reasonCounts = reasonCounts
    self.monitoringFailureDelta = monitoringFailureDelta
    self.isValid = isValid
  }
}

public enum DashboardMemoryGapAuditEvaluator {
  public static func observedSlotCount(
    sampleDelta: Int,
    explicitGapCount: Int
  ) -> Int? {
    guard sampleDelta >= 0, explicitGapCount >= 0 else { return nil }
    let result = sampleDelta.addingReportingOverflow(explicitGapCount)
    return result.overflow ? nil : result.partialValue
  }

  public static func evaluate(
    allGaps: [MemorySamplingGap],
    initialGapCount: Int,
    initialMonitoringFailureCount: UInt64,
    finalMonitoringFailureCount: UInt64
  ) -> DashboardMemoryGapAudit {
    guard
      initialGapCount >= 0,
      initialGapCount <= allGaps.count,
      finalMonitoringFailureCount >= initialMonitoringFailureCount
    else {
      return DashboardMemoryGapAudit(
        explicitGapCount: 0,
        reasonCounts: [:],
        monitoringFailureDelta: nil,
        isValid: false
      )
    }

    let newGaps = Array(allGaps.dropFirst(initialGapCount))
    let failureDelta =
      finalMonitoringFailureCount - initialMonitoringFailureCount
    let diagnosticsAreComplete = newGaps.allSatisfy { gap in
      gap.acquisitionAttemptCount
        == MemorySamplingRetryPolicy.phase03.maximumAttempts
        && gap.timestampUTC.timeIntervalSince1970.isFinite
        && gap.systemUptimeSeconds.isFinite
        && gap.systemUptimeSeconds >= 0
        && gap.lastInconsistency.physicalMemoryBytes > 0
        && gap.lastInconsistency.pageSizeBytes > 0
        && gap.lastInconsistency.excessBytes > 0
    }
    let reasonCounts = Dictionary(
      grouping: newGaps,
      by: { $0.lastInconsistency.reason.rawValue }
    ).mapValues(\.count)
    return DashboardMemoryGapAudit(
      explicitGapCount: newGaps.count,
      reasonCounts: reasonCounts,
      monitoringFailureDelta: failureDelta,
      isValid: diagnosticsAreComplete && failureDelta == 0
    )
  }
}

public struct DashboardHistorySelection: Equatable, Sendable {
  public let requestedUTC: Date
  public let memory: MemoryHistoryPoint?
  public let totalCPU: TotalCPUHistoryPoint?
  public let logicalCPUs: [LogicalCPUHistoryPoint]
  public let pressure: MemoryPressureLevel?

  public init(
    requestedUTC: Date,
    memory: MemoryHistoryPoint?,
    totalCPU: TotalCPUHistoryPoint?,
    logicalCPUs: [LogicalCPUHistoryPoint],
    pressure: MemoryPressureLevel?
  ) {
    self.requestedUTC = requestedUTC
    self.memory = memory
    self.totalCPU = totalCPU
    self.logicalCPUs = logicalCPUs
    self.pressure = pressure
  }
}

public enum DashboardHistorySelectionResolver {
  public static func resolve(
    snapshot: MemoryHistorySnapshot,
    at requestedUTC: Date
  ) -> DashboardHistorySelection {
    guard
      requestedUTC >= snapshot.startUTC,
      requestedUTC <= snapshot.endUTC,
      !contains(requestedUTC, in: snapshot.sleepIntervals)
    else {
      return DashboardHistorySelection(
        requestedUTC: requestedUTC,
        memory: nil,
        totalCPU: nil,
        logicalCPUs: [],
        pressure: pressure(in: snapshot, at: requestedUTC)
      )
    }

    let memory = resolveMemory(snapshot: snapshot, at: requestedUTC)
    let totalCPU = resolveTotalCPU(snapshot: snapshot, at: requestedUTC)
    let logicalCPUs = resolveLogicalCPUs(snapshot: snapshot, at: requestedUTC)
    return DashboardHistorySelection(
      requestedUTC: requestedUTC,
      memory: memory,
      totalCPU: totalCPU,
      logicalCPUs: logicalCPUs,
      pressure: pressure(in: snapshot, at: requestedUTC)
    )
  }

  private static func resolveMemory(
    snapshot: MemoryHistorySnapshot,
    at requestedUTC: Date
  ) -> MemoryHistoryPoint? {
    switch snapshot.period {
    case .twelveHours, .twentyFourHours:
      guard
        let point = snapshot.points.last(where: {
          $0.source == .raw && $0.timestampUTC <= requestedUTC
        }),
        requestedUTC.timeIntervalSince(point.timestampUTC) <= 5,
        !crosses(
          snapshot.memoryDiscontinuityDates,
          after: point.timestampUTC,
          through: requestedUTC
        )
      else { return nil }
      return point
    case .threeDays:
      return snapshot.points.first(where: {
        $0.source == .oneMinute
          && $0.intervalStartUTC <= requestedUTC
          && requestedUTC < $0.intervalEndUTC
          && $0.intervalEndUTC <= snapshot.endUTC
          && !crosses(
            snapshot.memoryDiscontinuityDates,
            after: $0.intervalStartUTC,
            through: requestedUTC
          )
      })
    }
  }

  private static func resolveTotalCPU(
    snapshot: MemoryHistorySnapshot,
    at requestedUTC: Date
  ) -> TotalCPUHistoryPoint? {
    resolveCPUPoint(
      snapshot.cpuHistory.totalPoints,
      period: snapshot.period,
      requestedUTC: requestedUTC,
      endUTC: snapshot.endUTC,
      discontinuities: snapshot.cpuHistory.totalDiscontinuityDates
    )
  }

  private static func resolveLogicalCPUs(
    snapshot: MemoryHistorySnapshot,
    at requestedUTC: Date
  ) -> [LogicalCPUHistoryPoint] {
    let points = snapshot.cpuHistory.logicalPoints
    let candidateRange: Range<Int>
    switch snapshot.period {
    case .twelveHours, .twentyFourHours:
      candidateRange =
        lowerBound(
          points,
          timestampUTC: requestedUTC.addingTimeInterval(-5)
        )..<upperBound(points, timestampUTC: requestedUTC)
    case .threeDays:
      candidateRange =
        lowerBound(
          points,
          timestampUTC: requestedUTC.addingTimeInterval(
            -snapshot.period.expectedPointInterval
          )
        )..<upperBound(points, timestampUTC: requestedUTC)
    }

    var candidates: [String: LogicalCPUHistoryPoint] = [:]
    for point in points[candidateRange] {
      let key = "\(point.topology.epochKey)-\(point.cpuIndex)"
      switch snapshot.period {
      case .twelveHours, .twentyFourHours:
        guard point.source == .raw, point.intervalEndUTC <= requestedUTC else {
          continue
        }
        if let existing = candidates[key],
          existing.intervalEndUTC >= point.intervalEndUTC
        {
          continue
        }
        candidates[key] = point
      case .threeDays:
        guard
          point.source == .oneMinute,
          point.intervalStartUTC <= requestedUTC,
          requestedUTC < point.intervalEndUTC,
          point.intervalEndUTC <= snapshot.endUTC
        else {
          continue
        }
        candidates[key] = point
      }
    }

    let resolved = candidates.compactMap { key, point -> LogicalCPUHistoryPoint? in
      let boundaries =
        snapshot.cpuHistory.logicalGlobalDiscontinuityDates
        + (snapshot.cpuHistory.logicalSeriesDiscontinuityDates[key] ?? [])
      switch snapshot.period {
      case .twelveHours, .twentyFourHours:
        guard
          requestedUTC.timeIntervalSince(point.intervalEndUTC) <= 5,
          !crosses(
            boundaries,
            after: point.intervalEndUTC,
            through: requestedUTC
          )
        else { return nil }
      case .threeDays:
        guard
          !crosses(
            boundaries,
            after: point.intervalStartUTC,
            through: requestedUTC
          )
        else { return nil }
      }
      return point
    }
    guard
      let newestEpoch = resolved.max(by: {
        $0.topology.bootSessionStartUTC < $1.topology.bootSessionStartUTC
      })?.topology.epochKey
    else { return [] }
    return resolved.filter { $0.topology.epochKey == newestEpoch }
      .sorted { $0.cpuIndex < $1.cpuIndex }
  }

  private static func lowerBound(
    _ points: [LogicalCPUHistoryPoint],
    timestampUTC: Date
  ) -> Int {
    var lower = points.startIndex
    var upper = points.endIndex
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if points[middle].timestampUTC < timestampUTC {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }

  private static func upperBound(
    _ points: [LogicalCPUHistoryPoint],
    timestampUTC: Date
  ) -> Int {
    var lower = points.startIndex
    var upper = points.endIndex
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if points[middle].timestampUTC <= timestampUTC {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }

  private static func resolveCPUPoint<Point>(
    _ points: [Point],
    period: MemoryHistoryPeriod,
    requestedUTC: Date,
    endUTC: Date,
    discontinuities: [Date]
  ) -> Point? where Point: DashboardCPUHistoryPoint {
    switch period {
    case .twelveHours, .twentyFourHours:
      guard
        let point = points.last(where: {
          $0.source == .raw && $0.intervalEndUTC <= requestedUTC
        }),
        requestedUTC.timeIntervalSince(point.intervalEndUTC) <= 5,
        !crosses(
          discontinuities,
          after: point.intervalEndUTC,
          through: requestedUTC
        )
      else { return nil }
      return point
    case .threeDays:
      return points.first(where: {
        $0.source == .oneMinute
          && $0.intervalStartUTC <= requestedUTC
          && requestedUTC < $0.intervalEndUTC
          && $0.intervalEndUTC <= endUTC
          && !crosses(
            discontinuities,
            after: $0.intervalStartUTC,
            through: requestedUTC
          )
      })
    }
  }

  private static func pressure(
    in snapshot: MemoryHistorySnapshot,
    at requestedUTC: Date
  ) -> MemoryPressureLevel? {
    snapshot.pressureIntervals.first {
      $0.startUTC <= requestedUTC && requestedUTC < $0.endUTC
    }?.level
  }

  private static func contains(
    _ date: Date,
    in intervals: [SystemSleepInterval]
  ) -> Bool {
    intervals.contains { $0.startUTC <= date && date < $0.endUTC }
  }

  private static func crosses(
    _ dates: [Date],
    after start: Date,
    through end: Date
  ) -> Bool {
    dates.contains { $0 > start && $0 <= end }
  }
}

public protocol DashboardCPUHistoryPoint {
  var intervalStartUTC: Date { get }
  var intervalEndUTC: Date { get }
  var source: MemoryHistoryPointSource { get }
}

extension TotalCPUHistoryPoint: DashboardCPUHistoryPoint {}
extension LogicalCPUHistoryPoint: DashboardCPUHistoryPoint {}
