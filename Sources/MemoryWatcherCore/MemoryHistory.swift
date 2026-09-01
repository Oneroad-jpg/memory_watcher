import Foundation

public enum MemoryHistoryResolution: String, CaseIterable, Sendable {
  case oneMinute
  case fiveMinutes

  public var bucketDuration: TimeInterval {
    switch self {
    case .oneMinute:
      return 60
    case .fiveMinutes:
      return 5 * 60
    }
  }
}

public struct MemoryHistoryAggregate: Equatable, Sendable {
  public let resolution: MemoryHistoryResolution
  public let bucketStartUTC: Date
  public let sampleCount: Int
  public let averagePhysicalMemoryBytes: Double
  public let averageEstimatedMemoryUsedBytes: Double
  public let averageWiredBytes: Double
  public let averageCompressedBytes: Double
  public let averageEstimatedCachedFilesBytes: Double
  public let averageSwapUsedBytes: Double

  public init(
    resolution: MemoryHistoryResolution,
    bucketStartUTC: Date,
    sampleCount: Int,
    averagePhysicalMemoryBytes: Double,
    averageEstimatedMemoryUsedBytes: Double,
    averageWiredBytes: Double,
    averageCompressedBytes: Double,
    averageEstimatedCachedFilesBytes: Double,
    averageSwapUsedBytes: Double
  ) {
    self.resolution = resolution
    self.bucketStartUTC = bucketStartUTC
    self.sampleCount = sampleCount
    self.averagePhysicalMemoryBytes = averagePhysicalMemoryBytes
    self.averageEstimatedMemoryUsedBytes = averageEstimatedMemoryUsedBytes
    self.averageWiredBytes = averageWiredBytes
    self.averageCompressedBytes = averageCompressedBytes
    self.averageEstimatedCachedFilesBytes = averageEstimatedCachedFilesBytes
    self.averageSwapUsedBytes = averageSwapUsedBytes
  }
}

public struct TotalCPUHistoryAggregate: Equatable, Sendable {
  public let resolution: MemoryHistoryResolution
  public let bucketStartUTC: Date
  public let sampleCount: Int
  public let summedUserTicks: UInt64
  public let summedSystemTicks: UInt64
  public let summedIdleTicks: UInt64
  public let summedNiceTicks: UInt64
  public let summedBusyTicks: UInt64
  public let summedTotalTicks: UInt64
  public let calculationVersion: String

  public init(
    resolution: MemoryHistoryResolution,
    bucketStartUTC: Date,
    sampleCount: Int,
    summedUserTicks: UInt64,
    summedSystemTicks: UInt64,
    summedIdleTicks: UInt64,
    summedNiceTicks: UInt64,
    summedBusyTicks: UInt64,
    summedTotalTicks: UInt64,
    calculationVersion: String
  ) {
    self.resolution = resolution
    self.bucketStartUTC = bucketStartUTC
    self.sampleCount = sampleCount
    self.summedUserTicks = summedUserTicks
    self.summedSystemTicks = summedSystemTicks
    self.summedIdleTicks = summedIdleTicks
    self.summedNiceTicks = summedNiceTicks
    self.summedBusyTicks = summedBusyTicks
    self.summedTotalTicks = summedTotalTicks
    self.calculationVersion = calculationVersion
  }

  public var utilizationPercent: Double {
    100 * Double(summedBusyTicks) / Double(summedTotalTicks)
  }
}

public struct LogicalCPUHistoryAggregate: Equatable, Sendable {
  public let resolution: MemoryHistoryResolution
  public let topology: LogicalCPUTopology
  public let cpuIndex: Int
  public let bucketStartUTC: Date
  public let sampleCount: Int
  public let summedUserTicks: UInt64
  public let summedSystemTicks: UInt64
  public let summedIdleTicks: UInt64
  public let summedNiceTicks: UInt64
  public let summedBusyTicks: UInt64
  public let summedTotalTicks: UInt64
  public let calculationVersion: String

  public init(
    resolution: MemoryHistoryResolution,
    topology: LogicalCPUTopology,
    cpuIndex: Int,
    bucketStartUTC: Date,
    sampleCount: Int,
    summedUserTicks: UInt64,
    summedSystemTicks: UInt64,
    summedIdleTicks: UInt64,
    summedNiceTicks: UInt64,
    summedBusyTicks: UInt64,
    summedTotalTicks: UInt64,
    calculationVersion: String
  ) {
    self.resolution = resolution
    self.topology = topology
    self.cpuIndex = cpuIndex
    self.bucketStartUTC = bucketStartUTC
    self.sampleCount = sampleCount
    self.summedUserTicks = summedUserTicks
    self.summedSystemTicks = summedSystemTicks
    self.summedIdleTicks = summedIdleTicks
    self.summedNiceTicks = summedNiceTicks
    self.summedBusyTicks = summedBusyTicks
    self.summedTotalTicks = summedTotalTicks
    self.calculationVersion = calculationVersion
  }

  public var utilizationPercent: Double {
    100 * Double(summedBusyTicks) / Double(summedTotalTicks)
  }
}

public enum MemoryHistoryRetentionPolicy {
  public static let rawSampleRetention: TimeInterval = 24 * 60 * 60
  public static let oneMinuteRetention: TimeInterval = 3 * 24 * 60 * 60
  public static let fiveMinuteRetention: TimeInterval = 3 * 24 * 60 * 60
  public static let maintenanceInterval: TimeInterval = 60 * 60
}

public struct MemoryHistoryMaintenanceResult: Equatable, Sendable {
  public let oneMinuteBucketsUpserted: Int
  public let fiveMinuteBucketsUpserted: Int
  public let rawSamplesDeleted: Int
  public let oneMinuteBucketsDeleted: Int
  public let fiveMinuteBucketsDeleted: Int
  public let pressureObservationsDeleted: Int
  public let samplingGapsDeleted: Int
  public let lifecycleEventsDeleted: Int
  public let totalCPUOneMinuteBucketsUpserted: Int
  public let totalCPUFiveMinuteBucketsUpserted: Int
  public let totalCPURawSamplesDeleted: Int
  public let totalCPUOneMinuteBucketsDeleted: Int
  public let totalCPUFiveMinuteBucketsDeleted: Int
  public let logicalCPUOneMinuteBucketsUpserted: Int
  public let logicalCPUFiveMinuteBucketsUpserted: Int
  public let logicalCPURawSamplesDeleted: Int
  public let logicalCPUGapsDeleted: Int
  public let logicalCPUOneMinuteBucketsDeleted: Int
  public let logicalCPUFiveMinuteBucketsDeleted: Int

  public init(
    oneMinuteBucketsUpserted: Int,
    fiveMinuteBucketsUpserted: Int,
    rawSamplesDeleted: Int,
    oneMinuteBucketsDeleted: Int,
    fiveMinuteBucketsDeleted: Int,
    pressureObservationsDeleted: Int,
    samplingGapsDeleted: Int,
    lifecycleEventsDeleted: Int,
    totalCPUOneMinuteBucketsUpserted: Int = 0,
    totalCPUFiveMinuteBucketsUpserted: Int = 0,
    totalCPURawSamplesDeleted: Int = 0,
    totalCPUOneMinuteBucketsDeleted: Int = 0,
    totalCPUFiveMinuteBucketsDeleted: Int = 0,
    logicalCPUOneMinuteBucketsUpserted: Int = 0,
    logicalCPUFiveMinuteBucketsUpserted: Int = 0,
    logicalCPURawSamplesDeleted: Int = 0,
    logicalCPUGapsDeleted: Int = 0,
    logicalCPUOneMinuteBucketsDeleted: Int = 0,
    logicalCPUFiveMinuteBucketsDeleted: Int = 0
  ) {
    self.oneMinuteBucketsUpserted = oneMinuteBucketsUpserted
    self.fiveMinuteBucketsUpserted = fiveMinuteBucketsUpserted
    self.rawSamplesDeleted = rawSamplesDeleted
    self.oneMinuteBucketsDeleted = oneMinuteBucketsDeleted
    self.fiveMinuteBucketsDeleted = fiveMinuteBucketsDeleted
    self.pressureObservationsDeleted = pressureObservationsDeleted
    self.samplingGapsDeleted = samplingGapsDeleted
    self.lifecycleEventsDeleted = lifecycleEventsDeleted
    self.totalCPUOneMinuteBucketsUpserted = totalCPUOneMinuteBucketsUpserted
    self.totalCPUFiveMinuteBucketsUpserted = totalCPUFiveMinuteBucketsUpserted
    self.totalCPURawSamplesDeleted = totalCPURawSamplesDeleted
    self.totalCPUOneMinuteBucketsDeleted = totalCPUOneMinuteBucketsDeleted
    self.totalCPUFiveMinuteBucketsDeleted = totalCPUFiveMinuteBucketsDeleted
    self.logicalCPUOneMinuteBucketsUpserted =
      logicalCPUOneMinuteBucketsUpserted
    self.logicalCPUFiveMinuteBucketsUpserted =
      logicalCPUFiveMinuteBucketsUpserted
    self.logicalCPURawSamplesDeleted = logicalCPURawSamplesDeleted
    self.logicalCPUGapsDeleted = logicalCPUGapsDeleted
    self.logicalCPUOneMinuteBucketsDeleted =
      logicalCPUOneMinuteBucketsDeleted
    self.logicalCPUFiveMinuteBucketsDeleted =
      logicalCPUFiveMinuteBucketsDeleted
  }
}
