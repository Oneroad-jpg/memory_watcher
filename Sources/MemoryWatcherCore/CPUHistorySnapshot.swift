import Foundation

public struct TotalCPUHistoryPoint: Equatable, Sendable {
  public let timestampUTC: Date
  public let intervalStartUTC: Date
  public let intervalEndUTC: Date
  public let source: MemoryHistoryPointSource
  public let sampleCount: Int
  public let continuitySegment: Int
  public let userPercent: Double
  public let systemPercent: Double
  public let nicePercent: Double
  public let idlePercent: Double
  public let utilizationPercent: Double

  public init(
    timestampUTC: Date,
    intervalStartUTC: Date,
    intervalEndUTC: Date,
    source: MemoryHistoryPointSource,
    sampleCount: Int,
    continuitySegment: Int,
    userPercent: Double,
    systemPercent: Double,
    nicePercent: Double,
    idlePercent: Double,
    utilizationPercent: Double
  ) {
    self.timestampUTC = timestampUTC
    self.intervalStartUTC = intervalStartUTC
    self.intervalEndUTC = intervalEndUTC
    self.source = source
    self.sampleCount = sampleCount
    self.continuitySegment = continuitySegment
    self.userPercent = userPercent
    self.systemPercent = systemPercent
    self.nicePercent = nicePercent
    self.idlePercent = idlePercent
    self.utilizationPercent = utilizationPercent
  }
}

public struct LogicalCPUHistoryPoint: Equatable, Sendable {
  public let topology: LogicalCPUTopology
  public let cpuIndex: Int
  public let timestampUTC: Date
  public let intervalStartUTC: Date
  public let intervalEndUTC: Date
  public let source: MemoryHistoryPointSource
  public let sampleCount: Int
  public let continuitySegment: Int
  public let userPercent: Double
  public let systemPercent: Double
  public let nicePercent: Double
  public let idlePercent: Double
  public let utilizationPercent: Double

  public init(
    topology: LogicalCPUTopology,
    cpuIndex: Int,
    timestampUTC: Date,
    intervalStartUTC: Date,
    intervalEndUTC: Date,
    source: MemoryHistoryPointSource,
    sampleCount: Int,
    continuitySegment: Int,
    userPercent: Double,
    systemPercent: Double,
    nicePercent: Double,
    idlePercent: Double,
    utilizationPercent: Double
  ) {
    self.topology = topology
    self.cpuIndex = cpuIndex
    self.timestampUTC = timestampUTC
    self.intervalStartUTC = intervalStartUTC
    self.intervalEndUTC = intervalEndUTC
    self.source = source
    self.sampleCount = sampleCount
    self.continuitySegment = continuitySegment
    self.userPercent = userPercent
    self.systemPercent = systemPercent
    self.nicePercent = nicePercent
    self.idlePercent = idlePercent
    self.utilizationPercent = utilizationPercent
  }

  public var displayName: String {
    "CPU \(cpuIndex + 1)"
  }

  public var seriesIdentifier: String {
    "\(topology.epochKey)-\(cpuIndex)-\(continuitySegment)"
  }
}

public struct CPUHistorySnapshot: Equatable, Sendable {
  public let totalPoints: [TotalCPUHistoryPoint]
  public let logicalPoints: [LogicalCPUHistoryPoint]
  public let totalDiscontinuityDates: [Date]
  public let logicalGlobalDiscontinuityDates: [Date]
  public let logicalSeriesDiscontinuityDates: [String: [Date]]

  public init(
    totalPoints: [TotalCPUHistoryPoint],
    logicalPoints: [LogicalCPUHistoryPoint],
    totalDiscontinuityDates: [Date] = [],
    logicalGlobalDiscontinuityDates: [Date] = [],
    logicalSeriesDiscontinuityDates: [String: [Date]] = [:]
  ) {
    self.totalPoints = totalPoints
    self.logicalPoints = logicalPoints
    self.totalDiscontinuityDates = totalDiscontinuityDates
    self.logicalGlobalDiscontinuityDates = logicalGlobalDiscontinuityDates
    self.logicalSeriesDiscontinuityDates = logicalSeriesDiscontinuityDates
  }

  public static let empty = CPUHistorySnapshot(
    totalPoints: [],
    logicalPoints: []
  )
}

struct CPUHistoryLoader: Sendable {
  private let database: MemoryWatcherDatabase

  init(database: MemoryWatcherDatabase) {
    self.database = database
  }

  func load(
    period: MemoryHistoryPeriod,
    range: ClosedRange<Date>,
    lifecycleEvents: [SystemLifecycleEvent],
    sleepIntervals: [SystemSleepInterval]
  ) throws -> CPUHistorySnapshot {
    let totalSamples: [TotalCPUSample]
    let logicalSamples: [LogicalCPUSample]
    let totalValues: [UnsegmentedCPUHistoryValue]
    let logicalValues: [UnsegmentedCPUHistoryValue]

    switch period {
    case .twelveHours, .twentyFourHours:
      totalSamples = try database.fetchTotalCPUSamples(
        from: range.lowerBound,
        through: range.upperBound
      )
      logicalSamples = try database.fetchLogicalCPUSamples(
        from: range.lowerBound,
        through: range.upperBound
      )
      totalValues = totalSamples.compactMap(Self.rawValue(from:))
      logicalValues = logicalSamples.compactMap(Self.rawValue(from:))
    case .threeDays:
      totalSamples = try database.fetchTotalCPUUnknownSamples(
        from: range.lowerBound,
        through: range.upperBound
      )
      logicalSamples = try database.fetchLogicalCPUUnknownSamples(
        from: range.lowerBound,
        through: range.upperBound
      )
      totalValues = try database.fetchTotalCPUAggregates(
        resolution: .oneMinute,
        from: range.lowerBound,
        through: range.upperBound
      ).map(Self.aggregateValue(from:))
      logicalValues = try database.fetchLogicalCPUAggregates(
        resolution: .oneMinute,
        from: range.lowerBound,
        through: range.upperBound
      ).map(Self.aggregateValue(from:))
    }

    let lifecycleDiscontinuities = lifecycleEvents.map(\.timestampUTC)
    let totalUnknownDates =
      totalSamples
      .filter { $0.quality != .measured }
      .map(\.intervalEndUTC)
    let logicalUnknownDates = Dictionary(
      grouping: logicalSamples.filter { $0.quality != .measured },
      by: { SeriesKey(topologyEpoch: $0.topology.epochKey, cpuIndex: $0.cpuIndex) }
    ).mapValues { $0.map(\.intervalEndUTC) }
    let logicalGapDates = try database.fetchLogicalCPUSamplingGaps(
      from: range.lowerBound,
      through: range.upperBound
    ).map(\.timestampUTC)

    let totalSegmented = Self.segment(
      values: totalValues,
      expectedInterval: period.expectedPointInterval,
      globalDiscontinuities: lifecycleDiscontinuities + totalUnknownDates,
      perSeriesDiscontinuities: [:],
      sleepIntervals: sleepIntervals
    )
    let logicalSegmented = Self.segment(
      values: logicalValues,
      expectedInterval: period.expectedPointInterval,
      globalDiscontinuities: lifecycleDiscontinuities + logicalGapDates,
      perSeriesDiscontinuities: logicalUnknownDates,
      sleepIntervals: sleepIntervals
    )

    return CPUHistorySnapshot(
      totalPoints: totalSegmented.map(Self.totalPoint(from:)),
      logicalPoints: logicalSegmented.map(Self.logicalPoint(from:)),
      totalDiscontinuityDates: (lifecycleDiscontinuities + totalUnknownDates)
        .sorted(),
      logicalGlobalDiscontinuityDates: (lifecycleDiscontinuities + logicalGapDates).sorted(),
      logicalSeriesDiscontinuityDates: Dictionary(
        uniqueKeysWithValues: logicalUnknownDates.map { key, dates in
          (key.publicIdentifier, dates.sorted())
        }
      )
    )
  }

  private static func rawValue(
    from sample: TotalCPUSample
  ) -> UnsegmentedCPUHistoryValue? {
    guard
      sample.quality == .measured,
      let startUTC = sample.intervalStartUTC,
      let delta = sample.delta
    else {
      return nil
    }
    return value(
      topology: nil,
      cpuIndex: nil,
      timestampUTC: sample.intervalEndUTC,
      intervalStartUTC: startUTC,
      intervalEndUTC: sample.intervalEndUTC,
      source: .raw,
      sampleCount: 1,
      userTicks: delta.userTicks,
      systemTicks: delta.systemTicks,
      idleTicks: delta.idleTicks,
      niceTicks: delta.niceTicks,
      busyTicks: delta.busyTicks,
      totalTicks: delta.totalTicks
    )
  }

  private static func rawValue(
    from sample: LogicalCPUSample
  ) -> UnsegmentedCPUHistoryValue? {
    guard
      sample.quality == .measured,
      let startUTC = sample.intervalStartUTC,
      let delta = sample.delta
    else {
      return nil
    }
    return value(
      topology: sample.topology,
      cpuIndex: sample.cpuIndex,
      timestampUTC: sample.intervalEndUTC,
      intervalStartUTC: startUTC,
      intervalEndUTC: sample.intervalEndUTC,
      source: .raw,
      sampleCount: 1,
      userTicks: delta.userTicks,
      systemTicks: delta.systemTicks,
      idleTicks: delta.idleTicks,
      niceTicks: delta.niceTicks,
      busyTicks: delta.busyTicks,
      totalTicks: delta.totalTicks
    )
  }

  private static func aggregateValue(
    from aggregate: TotalCPUHistoryAggregate
  ) -> UnsegmentedCPUHistoryValue {
    value(
      topology: nil,
      cpuIndex: nil,
      timestampUTC: aggregate.bucketStartUTC,
      intervalStartUTC: aggregate.bucketStartUTC,
      intervalEndUTC: aggregate.bucketStartUTC.addingTimeInterval(
        aggregate.resolution.bucketDuration
      ),
      source: .oneMinute,
      sampleCount: aggregate.sampleCount,
      userTicks: aggregate.summedUserTicks,
      systemTicks: aggregate.summedSystemTicks,
      idleTicks: aggregate.summedIdleTicks,
      niceTicks: aggregate.summedNiceTicks,
      busyTicks: aggregate.summedBusyTicks,
      totalTicks: aggregate.summedTotalTicks
    )
  }

  private static func aggregateValue(
    from aggregate: LogicalCPUHistoryAggregate
  ) -> UnsegmentedCPUHistoryValue {
    value(
      topology: aggregate.topology,
      cpuIndex: aggregate.cpuIndex,
      timestampUTC: aggregate.bucketStartUTC,
      intervalStartUTC: aggregate.bucketStartUTC,
      intervalEndUTC: aggregate.bucketStartUTC.addingTimeInterval(
        aggregate.resolution.bucketDuration
      ),
      source: .oneMinute,
      sampleCount: aggregate.sampleCount,
      userTicks: aggregate.summedUserTicks,
      systemTicks: aggregate.summedSystemTicks,
      idleTicks: aggregate.summedIdleTicks,
      niceTicks: aggregate.summedNiceTicks,
      busyTicks: aggregate.summedBusyTicks,
      totalTicks: aggregate.summedTotalTicks
    )
  }

  private static func value(
    topology: LogicalCPUTopology?,
    cpuIndex: Int?,
    timestampUTC: Date,
    intervalStartUTC: Date,
    intervalEndUTC: Date,
    source: MemoryHistoryPointSource,
    sampleCount: Int,
    userTicks: UInt64,
    systemTicks: UInt64,
    idleTicks: UInt64,
    niceTicks: UInt64,
    busyTicks: UInt64,
    totalTicks: UInt64
  ) -> UnsegmentedCPUHistoryValue {
    func percent(_ ticks: UInt64) -> Double {
      100 * Double(ticks) / Double(totalTicks)
    }
    return UnsegmentedCPUHistoryValue(
      topology: topology,
      cpuIndex: cpuIndex,
      timestampUTC: timestampUTC,
      intervalStartUTC: intervalStartUTC,
      intervalEndUTC: intervalEndUTC,
      source: source,
      sampleCount: sampleCount,
      userPercent: percent(userTicks),
      systemPercent: percent(systemTicks),
      nicePercent: percent(niceTicks),
      idlePercent: percent(idleTicks),
      utilizationPercent: percent(busyTicks)
    )
  }

  private static func segment(
    values: [UnsegmentedCPUHistoryValue],
    expectedInterval: TimeInterval,
    globalDiscontinuities: [Date],
    perSeriesDiscontinuities: [SeriesKey: [Date]],
    sleepIntervals: [SystemSleepInterval]
  ) -> [SegmentedCPUHistoryValue] {
    let globalDates = globalDiscontinuities.sorted()
    let groups = Dictionary(grouping: values, by: \.seriesKey)
    var result: [SegmentedCPUHistoryValue] = []
    for key in groups.keys.sorted() {
      guard let group = groups[key] else { continue }
      let seriesDates = (perSeriesDiscontinuities[key] ?? []).sorted()
      var segment = 0
      var previousDate: Date?
      for value in group.sorted(by: { $0.timestampUTC < $1.timestampUTC }) {
        if let previousDate {
          let delta = value.timestampUTC.timeIntervalSince(previousDate)
          let crossesGlobal = crosses(
            dates: globalDates,
            after: previousDate,
            through: value.timestampUTC
          )
          let crossesSeries = crosses(
            dates: seriesDates,
            after: previousDate,
            through: value.timestampUTC
          )
          let crossesSleep = sleepIntervals.contains { interval in
            interval.startUTC < value.timestampUTC
              && interval.endUTC > previousDate
          }
          if delta <= 0
            || delta > expectedInterval * 2.5
            || crossesGlobal
            || crossesSeries
            || crossesSleep
          {
            segment += 1
          }
        }
        previousDate = value.timestampUTC
        result.append(
          SegmentedCPUHistoryValue(value: value, continuitySegment: segment)
        )
      }
    }
    return result.sorted {
      if $0.value.timestampUTC != $1.value.timestampUTC {
        return $0.value.timestampUTC < $1.value.timestampUTC
      }
      return $0.value.seriesKey < $1.value.seriesKey
    }
  }

  private static func crosses(
    dates: [Date],
    after start: Date,
    through end: Date
  ) -> Bool {
    dates.contains { $0 > start && $0 <= end }
  }

  private static func totalPoint(
    from value: SegmentedCPUHistoryValue
  ) -> TotalCPUHistoryPoint {
    let raw = value.value
    return TotalCPUHistoryPoint(
      timestampUTC: raw.timestampUTC,
      intervalStartUTC: raw.intervalStartUTC,
      intervalEndUTC: raw.intervalEndUTC,
      source: raw.source,
      sampleCount: raw.sampleCount,
      continuitySegment: value.continuitySegment,
      userPercent: raw.userPercent,
      systemPercent: raw.systemPercent,
      nicePercent: raw.nicePercent,
      idlePercent: raw.idlePercent,
      utilizationPercent: raw.utilizationPercent
    )
  }

  private static func logicalPoint(
    from value: SegmentedCPUHistoryValue
  ) -> LogicalCPUHistoryPoint {
    let raw = value.value
    return LogicalCPUHistoryPoint(
      topology: raw.topology!,
      cpuIndex: raw.cpuIndex!,
      timestampUTC: raw.timestampUTC,
      intervalStartUTC: raw.intervalStartUTC,
      intervalEndUTC: raw.intervalEndUTC,
      source: raw.source,
      sampleCount: raw.sampleCount,
      continuitySegment: value.continuitySegment,
      userPercent: raw.userPercent,
      systemPercent: raw.systemPercent,
      nicePercent: raw.nicePercent,
      idlePercent: raw.idlePercent,
      utilizationPercent: raw.utilizationPercent
    )
  }
}

private struct SeriesKey: Hashable, Comparable {
  let topologyEpoch: String?
  let cpuIndex: Int?

  var publicIdentifier: String {
    "\(topologyEpoch ?? "")-\(cpuIndex ?? -1)"
  }

  static func < (lhs: SeriesKey, rhs: SeriesKey) -> Bool {
    let lhsEpoch = lhs.topologyEpoch ?? ""
    let rhsEpoch = rhs.topologyEpoch ?? ""
    if lhsEpoch != rhsEpoch { return lhsEpoch < rhsEpoch }
    return (lhs.cpuIndex ?? -1) < (rhs.cpuIndex ?? -1)
  }
}

private struct UnsegmentedCPUHistoryValue {
  let topology: LogicalCPUTopology?
  let cpuIndex: Int?
  let timestampUTC: Date
  let intervalStartUTC: Date
  let intervalEndUTC: Date
  let source: MemoryHistoryPointSource
  let sampleCount: Int
  let userPercent: Double
  let systemPercent: Double
  let nicePercent: Double
  let idlePercent: Double
  let utilizationPercent: Double

  var seriesKey: SeriesKey {
    SeriesKey(topologyEpoch: topology?.epochKey, cpuIndex: cpuIndex)
  }
}

private struct SegmentedCPUHistoryValue {
  let value: UnsegmentedCPUHistoryValue
  let continuitySegment: Int
}
