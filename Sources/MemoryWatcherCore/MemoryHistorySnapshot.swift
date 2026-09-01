import Foundation

public enum MemoryHistoryPeriod: String, CaseIterable, Identifiable, Sendable {
  case twelveHours
  case twentyFourHours
  case threeDays

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .twelveHours:
      return "12時間"
    case .twentyFourHours:
      return "24時間"
    case .threeDays:
      return "3日"
    }
  }

  public var duration: TimeInterval {
    switch self {
    case .twelveHours:
      return 12 * 60 * 60
    case .twentyFourHours:
      return 24 * 60 * 60
    case .threeDays:
      return 3 * 24 * 60 * 60
    }
  }

  public var expectedPointInterval: TimeInterval {
    switch self {
    case .twelveHours, .twentyFourHours:
      return MemoryWatcherFoundation.sampleInterval
    case .threeDays:
      return MemoryHistoryResolution.oneMinute.bucketDuration
    }
  }
}

public enum MemoryHistoryPointSource: String, Equatable, Sendable {
  case raw
  case oneMinute
  case fiveMinutes
}

public struct MemoryHistoryPoint: Equatable, Sendable {
  public let timestampUTC: Date
  public let source: MemoryHistoryPointSource
  public let sampleCount: Int
  public let continuitySegment: Int
  public let physicalMemoryBytes: Double
  public let estimatedMemoryUsedBytes: Double
  public let estimatedOtherUsedBytes: Double
  public let wiredBytes: Double
  public let compressedBytes: Double
  public let estimatedCachedFilesBytes: Double
  public let swapUsedBytes: Double

  public init(
    timestampUTC: Date,
    source: MemoryHistoryPointSource,
    sampleCount: Int,
    continuitySegment: Int,
    physicalMemoryBytes: Double,
    estimatedMemoryUsedBytes: Double,
    estimatedOtherUsedBytes: Double,
    wiredBytes: Double,
    compressedBytes: Double,
    estimatedCachedFilesBytes: Double,
    swapUsedBytes: Double
  ) {
    self.timestampUTC = timestampUTC
    self.source = source
    self.sampleCount = sampleCount
    self.continuitySegment = continuitySegment
    self.physicalMemoryBytes = physicalMemoryBytes
    self.estimatedMemoryUsedBytes = estimatedMemoryUsedBytes
    self.estimatedOtherUsedBytes = estimatedOtherUsedBytes
    self.wiredBytes = wiredBytes
    self.compressedBytes = compressedBytes
    self.estimatedCachedFilesBytes = estimatedCachedFilesBytes
    self.swapUsedBytes = swapUsedBytes
  }
}

public struct MemoryPressureInterval: Equatable, Sendable {
  public let startUTC: Date
  public let endUTC: Date
  public let level: MemoryPressureLevel

  public init(startUTC: Date, endUTC: Date, level: MemoryPressureLevel) {
    self.startUTC = startUTC
    self.endUTC = endUTC
    self.level = level
  }
}

public struct SystemSleepInterval: Equatable, Sendable {
  public let startUTC: Date
  public let endUTC: Date

  public init(startUTC: Date, endUTC: Date) {
    self.startUTC = startUTC
    self.endUTC = endUTC
  }
}

public struct MemoryHistorySnapshot: Equatable, Sendable {
  public let period: MemoryHistoryPeriod
  public let startUTC: Date
  public let endUTC: Date
  public let points: [MemoryHistoryPoint]
  public let pressureIntervals: [MemoryPressureInterval]
  public let sleepIntervals: [SystemSleepInterval]
  public let cpuHistory: CPUHistorySnapshot

  public init(
    period: MemoryHistoryPeriod,
    startUTC: Date,
    endUTC: Date,
    points: [MemoryHistoryPoint],
    pressureIntervals: [MemoryPressureInterval],
    sleepIntervals: [SystemSleepInterval],
    cpuHistory: CPUHistorySnapshot
  ) {
    self.period = period
    self.startUTC = startUTC
    self.endUTC = endUTC
    self.points = points
    self.pressureIntervals = pressureIntervals
    self.sleepIntervals = sleepIntervals
    self.cpuHistory = cpuHistory
  }
}

public struct MemoryHistoryLoader: Sendable {
  private let database: MemoryWatcherDatabase

  public init(database: MemoryWatcherDatabase) {
    self.database = database
  }

  public func load(
    period: MemoryHistoryPeriod,
    now: Date = Date()
  ) throws -> MemoryHistorySnapshot {
    let start = now.addingTimeInterval(-period.duration)
    let lifecycleEvents = try database.fetchLifecycleEvents()
    let gaps = try database.fetchSamplingGaps()
    let sleepIntervals = Self.sleepIntervals(
      from: lifecycleEvents,
      range: start...now
    )
    let discontinuities =
      gaps.map(\.timestampUTC) + lifecycleEvents.map(\.timestampUTC)

    let values = try historyValues(period: period)
      .filter { $0.timestampUTC >= start && $0.timestampUTC <= now }
      .sorted { $0.timestampUTC < $1.timestampUTC }
    let points = Self.segmentedPoints(
      from: values,
      expectedInterval: period.expectedPointInterval,
      discontinuities: discontinuities,
      sleepIntervals: sleepIntervals
    )
    let pressureIntervals = Self.pressureIntervals(
      from: try database.fetchPressureObservations(),
      range: start...now
    )
    let cpuHistory = try CPUHistoryLoader(database: database).load(
      period: period,
      range: start...now,
      lifecycleEvents: lifecycleEvents,
      sleepIntervals: sleepIntervals
    )
    return MemoryHistorySnapshot(
      period: period,
      startUTC: start,
      endUTC: now,
      points: points,
      pressureIntervals: pressureIntervals,
      sleepIntervals: sleepIntervals,
      cpuHistory: cpuHistory
    )
  }

  private func historyValues(
    period: MemoryHistoryPeriod
  ) throws -> [UnsegmentedHistoryValue] {
    switch period {
    case .twelveHours, .twentyFourHours:
      return try database.fetchSamples().map { sample in
        UnsegmentedHistoryValue(
          timestampUTC: sample.timestampUTC,
          source: .raw,
          sampleCount: 1,
          physicalMemoryBytes: Double(sample.physicalMemoryBytes),
          estimatedMemoryUsedBytes: Double(sample.estimatedMemoryUsedBytes),
          wiredBytes: Double(sample.wiredBytes),
          compressedBytes: Double(sample.compressedBytes),
          estimatedCachedFilesBytes: Double(
            sample.estimatedCachedFilesBytes
          ),
          swapUsedBytes: Double(sample.swapUsedBytes)
        )
      }
    case .threeDays:
      return try aggregateValues(resolution: .oneMinute, source: .oneMinute)
    }
  }

  private func aggregateValues(
    resolution: MemoryHistoryResolution,
    source: MemoryHistoryPointSource
  ) throws -> [UnsegmentedHistoryValue] {
    try database.fetchAggregates(resolution: resolution).map { aggregate in
      UnsegmentedHistoryValue(
        timestampUTC: aggregate.bucketStartUTC,
        source: source,
        sampleCount: aggregate.sampleCount,
        physicalMemoryBytes: aggregate.averagePhysicalMemoryBytes,
        estimatedMemoryUsedBytes: aggregate.averageEstimatedMemoryUsedBytes,
        wiredBytes: aggregate.averageWiredBytes,
        compressedBytes: aggregate.averageCompressedBytes,
        estimatedCachedFilesBytes:
          aggregate.averageEstimatedCachedFilesBytes,
        swapUsedBytes: aggregate.averageSwapUsedBytes
      )
    }
  }

  private static func segmentedPoints(
    from values: [UnsegmentedHistoryValue],
    expectedInterval: TimeInterval,
    discontinuities: [Date],
    sleepIntervals: [SystemSleepInterval]
  ) -> [MemoryHistoryPoint] {
    let sortedDiscontinuities = discontinuities.sorted()
    var segment = 0
    var previousDate: Date?
    return values.map { value in
      if let previousDate {
        let delta = value.timestampUTC.timeIntervalSince(previousDate)
        let crossesDiscontinuity = sortedDiscontinuities.contains { date in
          date > previousDate && date <= value.timestampUTC
        }
        let crossesSleep = sleepIntervals.contains { interval in
          interval.startUTC < value.timestampUTC
            && interval.endUTC > previousDate
        }
        if delta <= 0
          || delta > expectedInterval * 2.5
          || crossesDiscontinuity
          || crossesSleep
        {
          segment += 1
        }
      }
      previousDate = value.timestampUTC
      let otherUsed = max(
        0,
        value.estimatedMemoryUsedBytes
          - value.wiredBytes
          - value.compressedBytes
      )
      return MemoryHistoryPoint(
        timestampUTC: value.timestampUTC,
        source: value.source,
        sampleCount: value.sampleCount,
        continuitySegment: segment,
        physicalMemoryBytes: value.physicalMemoryBytes,
        estimatedMemoryUsedBytes: value.estimatedMemoryUsedBytes,
        estimatedOtherUsedBytes: otherUsed,
        wiredBytes: value.wiredBytes,
        compressedBytes: value.compressedBytes,
        estimatedCachedFilesBytes: value.estimatedCachedFilesBytes,
        swapUsedBytes: value.swapUsedBytes
      )
    }
  }

  private static func pressureIntervals(
    from observations: [MemoryPressureObservation],
    range: ClosedRange<Date>
  ) -> [MemoryPressureInterval] {
    let sorted = observations.sorted { $0.timestampUTC < $1.timestampUTC }
    var currentLevel =
      sorted.last(where: { $0.timestampUTC <= range.lowerBound })?.level
      ?? .unknown
    var cursor = range.lowerBound
    var intervals: [MemoryPressureInterval] = []
    for observation in sorted
    where observation.timestampUTC > range.lowerBound
      && observation.timestampUTC <= range.upperBound
    {
      if observation.timestampUTC > cursor {
        intervals.append(
          MemoryPressureInterval(
            startUTC: cursor,
            endUTC: observation.timestampUTC,
            level: currentLevel
          )
        )
      }
      cursor = observation.timestampUTC
      currentLevel = observation.level
    }
    if cursor < range.upperBound {
      intervals.append(
        MemoryPressureInterval(
          startUTC: cursor,
          endUTC: range.upperBound,
          level: currentLevel
        )
      )
    }
    return intervals
  }

  private static func sleepIntervals(
    from events: [SystemLifecycleEvent],
    range: ClosedRange<Date>
  ) -> [SystemSleepInterval] {
    var openSleep: Date?
    var intervals: [SystemSleepInterval] = []
    for event in events {
      switch event.kind {
      case .sleep:
        if openSleep == nil {
          openSleep = event.timestampUTC
        }
      case .wake:
        if let start = openSleep, event.timestampUTC >= start {
          let clippedStart = max(start, range.lowerBound)
          let clippedEnd = min(event.timestampUTC, range.upperBound)
          if clippedStart < clippedEnd {
            intervals.append(
              SystemSleepInterval(startUTC: clippedStart, endUTC: clippedEnd)
            )
          }
        }
        openSleep = nil
      case .launch, .clockChanged, .rebootDetected:
        continue
      }
    }
    if let start = openSleep {
      let clippedStart = max(start, range.lowerBound)
      if clippedStart < range.upperBound {
        intervals.append(
          SystemSleepInterval(
            startUTC: clippedStart,
            endUTC: range.upperBound
          )
        )
      }
    }
    return intervals
  }
}

public struct MemoryHistoryRefreshPolicy: Equatable, Sendable {
  public static let automaticReloadInterval: TimeInterval = 5 * 60

  public init() {}

  public func shouldAutomaticallyReload(
    period: MemoryHistoryPeriod,
    isWindowVisible: Bool,
    isLoading: Bool,
    lastReloadAt: Date?,
    now: Date
  ) -> Bool {
    guard
      period == .twelveHours || period == .twentyFourHours,
      isWindowVisible,
      !isLoading
    else {
      return false
    }
    guard let lastReloadAt else {
      return true
    }
    return now.timeIntervalSince(lastReloadAt) >= Self.automaticReloadInterval
  }
}

private struct UnsegmentedHistoryValue {
  let timestampUTC: Date
  let source: MemoryHistoryPointSource
  let sampleCount: Int
  let physicalMemoryBytes: Double
  let estimatedMemoryUsedBytes: Double
  let wiredBytes: Double
  let compressedBytes: Double
  let estimatedCachedFilesBytes: Double
  let swapUsedBytes: Double
}
