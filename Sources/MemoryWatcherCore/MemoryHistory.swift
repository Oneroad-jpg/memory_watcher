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

public enum MemoryHistoryRetentionPolicy {
  public static let rawSampleRetention: TimeInterval = 24 * 60 * 60
  public static let oneMinuteRetention: TimeInterval = 7 * 24 * 60 * 60
  public static let fiveMinuteRetention: TimeInterval = 30 * 24 * 60 * 60
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

  public init(
    oneMinuteBucketsUpserted: Int,
    fiveMinuteBucketsUpserted: Int,
    rawSamplesDeleted: Int,
    oneMinuteBucketsDeleted: Int,
    fiveMinuteBucketsDeleted: Int,
    pressureObservationsDeleted: Int,
    samplingGapsDeleted: Int,
    lifecycleEventsDeleted: Int
  ) {
    self.oneMinuteBucketsUpserted = oneMinuteBucketsUpserted
    self.fiveMinuteBucketsUpserted = fiveMinuteBucketsUpserted
    self.rawSamplesDeleted = rawSamplesDeleted
    self.oneMinuteBucketsDeleted = oneMinuteBucketsDeleted
    self.fiveMinuteBucketsDeleted = fiveMinuteBucketsDeleted
    self.pressureObservationsDeleted = pressureObservationsDeleted
    self.samplingGapsDeleted = samplingGapsDeleted
    self.lifecycleEventsDeleted = lifecycleEventsDeleted
  }
}
