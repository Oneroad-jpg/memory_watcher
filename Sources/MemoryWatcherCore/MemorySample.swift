import Foundation

public struct RawMemoryPageCounts: Codable, Equatable, Sendable {
  public let free: UInt64
  public let active: UInt64
  public let inactive: UInt64
  public let wired: UInt64
  public let speculative: UInt64
  public let purgeable: UInt64
  public let compressor: UInt64
  public let external: UInt64
  public let internalPages: UInt64

  public init(
    free: UInt64,
    active: UInt64,
    inactive: UInt64,
    wired: UInt64,
    speculative: UInt64,
    purgeable: UInt64,
    compressor: UInt64,
    external: UInt64,
    internalPages: UInt64
  ) {
    self.free = free
    self.active = active
    self.inactive = inactive
    self.wired = wired
    self.speculative = speculative
    self.purgeable = purgeable
    self.compressor = compressor
    self.external = external
    self.internalPages = internalPages
  }
}

public struct MemorySample: Codable, Equatable, Sendable {
  public let timestampUTC: Date
  public let systemUptimeSeconds: TimeInterval
  public let physicalMemoryBytes: UInt64
  public let estimatedMemoryUsedBytes: UInt64
  public let wiredBytes: UInt64
  public let compressedBytes: UInt64
  public let estimatedCachedFilesBytes: UInt64
  public let swapUsedBytes: UInt64
  public let pageSizeBytes: UInt64
  public let rawPageCounts: RawMemoryPageCounts
  public let calculationVersion: String
  public let acquisitionQuality: MemorySampleAcquisitionQuality
  public let acquisitionAttemptCount: Int

  public init(
    timestampUTC: Date,
    systemUptimeSeconds: TimeInterval,
    physicalMemoryBytes: UInt64,
    estimatedMemoryUsedBytes: UInt64,
    wiredBytes: UInt64,
    compressedBytes: UInt64,
    estimatedCachedFilesBytes: UInt64,
    swapUsedBytes: UInt64,
    pageSizeBytes: UInt64,
    rawPageCounts: RawMemoryPageCounts,
    calculationVersion: String,
    acquisitionQuality: MemorySampleAcquisitionQuality,
    acquisitionAttemptCount: Int
  ) {
    self.timestampUTC = timestampUTC
    self.systemUptimeSeconds = systemUptimeSeconds
    self.physicalMemoryBytes = physicalMemoryBytes
    self.estimatedMemoryUsedBytes = estimatedMemoryUsedBytes
    self.wiredBytes = wiredBytes
    self.compressedBytes = compressedBytes
    self.estimatedCachedFilesBytes = estimatedCachedFilesBytes
    self.swapUsedBytes = swapUsedBytes
    self.pageSizeBytes = pageSizeBytes
    self.rawPageCounts = rawPageCounts
    self.calculationVersion = calculationVersion
    self.acquisitionQuality = acquisitionQuality
    self.acquisitionAttemptCount = acquisitionAttemptCount
  }
}

public enum MemorySampleAcquisitionQuality: String, Codable, Equatable, Sendable {
  case firstPass
  case retried
}

public struct DerivedMemoryMetrics: Equatable, Sendable {
  public let estimatedApplicationMemoryBytes: UInt64
  public let estimatedMemoryUsedBytes: UInt64
  public let unclassifiedMemoryUsedBytes: UInt64
  public let wiredBytes: UInt64
  public let compressedBytes: UInt64
  public let estimatedCachedFilesBytes: UInt64
}

public enum MemorySamplingError: Error, Equatable, Sendable {
  case hostPageSize(Int32)
  case hostStatistics(Int32)
  case swapUsage(Int32)
  case inconsistentSnapshot(MemoryCounterInconsistency)
  case samplingAttemptsExhausted(MemorySamplingGap)
  case arithmeticOverflow
  case invalidSample

  public var isRetryableCounterInconsistency: Bool {
    if case .inconsistentSnapshot = self {
      return true
    }
    return false
  }
}

public enum MemoryCounterInconsistencyReason: String, Codable, Equatable, Sendable {
  case internalPagesBelowPurgeable
  case reclaimableExceedsPhysicalMemory
  case classifiedExceedsEstimatedUsed
  case componentExceedsPhysicalMemory
}

public struct MemoryCounterInconsistency: Codable, Equatable, Sendable {
  public let reason: MemoryCounterInconsistencyReason
  public let physicalMemoryBytes: UInt64
  public let pageSizeBytes: UInt64
  public let counters: RawMemoryPageCounts
  public let estimatedMemoryUsedBytes: UInt64?
  public let classifiedMemoryUsedBytes: UInt64?
  public let excessBytes: UInt64

  public init(
    reason: MemoryCounterInconsistencyReason,
    physicalMemoryBytes: UInt64,
    pageSizeBytes: UInt64,
    counters: RawMemoryPageCounts,
    estimatedMemoryUsedBytes: UInt64?,
    classifiedMemoryUsedBytes: UInt64?,
    excessBytes: UInt64
  ) {
    self.reason = reason
    self.physicalMemoryBytes = physicalMemoryBytes
    self.pageSizeBytes = pageSizeBytes
    self.counters = counters
    self.estimatedMemoryUsedBytes = estimatedMemoryUsedBytes
    self.classifiedMemoryUsedBytes = classifiedMemoryUsedBytes
    self.excessBytes = excessBytes
  }
}

public struct MemorySamplingGap: Codable, Equatable, Sendable {
  public let timestampUTC: Date
  public let systemUptimeSeconds: TimeInterval
  public let acquisitionAttemptCount: Int
  public let lastInconsistency: MemoryCounterInconsistency

  public init(
    timestampUTC: Date,
    systemUptimeSeconds: TimeInterval,
    acquisitionAttemptCount: Int,
    lastInconsistency: MemoryCounterInconsistency
  ) {
    self.timestampUTC = timestampUTC
    self.systemUptimeSeconds = systemUptimeSeconds
    self.acquisitionAttemptCount = acquisitionAttemptCount
    self.lastInconsistency = lastInconsistency
  }
}

public enum MemorySamplingOutcome: Codable, Equatable, Sendable {
  case sample(MemorySample)
  case gap(MemorySamplingGap)
}

public enum MemoryMetricsCalculator {
  public static let calculationVersion = "phase-03-v2"

  public static func calculate(
    physicalMemoryBytes: UInt64,
    pageSizeBytes: UInt64,
    counters: RawMemoryPageCounts
  ) throws -> DerivedMemoryMetrics {
    guard physicalMemoryBytes > 0, pageSizeBytes > 0 else {
      throw MemorySamplingError.invalidSample
    }
    guard counters.internalPages >= counters.purgeable else {
      throw inconsistentSnapshot(
        reason: .internalPagesBelowPurgeable,
        physicalMemoryBytes: physicalMemoryBytes,
        pageSizeBytes: pageSizeBytes,
        counters: counters,
        excessBytes: try checkedProduct(
          counters.purgeable - counters.internalPages,
          pageSizeBytes
        )
      )
    }

    let applicationPages = counters.internalPages - counters.purgeable
    let cachedPages = try checkedSum(counters.external, counters.purgeable)
    let estimatedApplicationMemoryBytes = try checkedProduct(
      applicationPages,
      pageSizeBytes
    )
    let wiredBytes = try checkedProduct(counters.wired, pageSizeBytes)
    let compressedBytes = try checkedProduct(
      counters.compressor,
      pageSizeBytes
    )
    let estimatedCachedFilesBytes = try checkedProduct(
      cachedPages,
      pageSizeBytes
    )
    let freeBytes = try checkedProduct(counters.free, pageSizeBytes)
    let reclaimableBytes = try checkedSum(
      freeBytes,
      estimatedCachedFilesBytes
    )
    guard reclaimableBytes <= physicalMemoryBytes else {
      throw inconsistentSnapshot(
        reason: .reclaimableExceedsPhysicalMemory,
        physicalMemoryBytes: physicalMemoryBytes,
        pageSizeBytes: pageSizeBytes,
        counters: counters,
        excessBytes: reclaimableBytes - physicalMemoryBytes
      )
    }
    let estimatedMemoryUsedBytes = physicalMemoryBytes - reclaimableBytes
    let classifiedMemoryUsedBytes = try checkedSum(
      estimatedApplicationMemoryBytes,
      wiredBytes,
      compressedBytes
    )
    guard classifiedMemoryUsedBytes <= estimatedMemoryUsedBytes else {
      throw inconsistentSnapshot(
        reason: .classifiedExceedsEstimatedUsed,
        physicalMemoryBytes: physicalMemoryBytes,
        pageSizeBytes: pageSizeBytes,
        counters: counters,
        estimatedMemoryUsedBytes: estimatedMemoryUsedBytes,
        classifiedMemoryUsedBytes: classifiedMemoryUsedBytes,
        excessBytes: classifiedMemoryUsedBytes - estimatedMemoryUsedBytes
      )
    }
    let metrics = DerivedMemoryMetrics(
      estimatedApplicationMemoryBytes: estimatedApplicationMemoryBytes,
      estimatedMemoryUsedBytes: estimatedMemoryUsedBytes,
      unclassifiedMemoryUsedBytes:
        estimatedMemoryUsedBytes - classifiedMemoryUsedBytes,
      wiredBytes: wiredBytes,
      compressedBytes: compressedBytes,
      estimatedCachedFilesBytes: estimatedCachedFilesBytes
    )

    guard
      metrics.estimatedApplicationMemoryBytes <= physicalMemoryBytes,
      metrics.estimatedMemoryUsedBytes <= physicalMemoryBytes,
      metrics.wiredBytes <= physicalMemoryBytes,
      metrics.compressedBytes <= physicalMemoryBytes,
      metrics.estimatedCachedFilesBytes <= physicalMemoryBytes,
      try checkedSum(
        metrics.estimatedMemoryUsedBytes,
        metrics.estimatedCachedFilesBytes
      ) <= physicalMemoryBytes
    else {
      let maximumComponent = max(
        metrics.estimatedApplicationMemoryBytes,
        metrics.estimatedMemoryUsedBytes,
        metrics.wiredBytes,
        metrics.compressedBytes,
        metrics.estimatedCachedFilesBytes
      )
      throw inconsistentSnapshot(
        reason: .componentExceedsPhysicalMemory,
        physicalMemoryBytes: physicalMemoryBytes,
        pageSizeBytes: pageSizeBytes,
        counters: counters,
        estimatedMemoryUsedBytes: estimatedMemoryUsedBytes,
        classifiedMemoryUsedBytes: classifiedMemoryUsedBytes,
        excessBytes: maximumComponent > physicalMemoryBytes
          ? maximumComponent - physicalMemoryBytes
          : 0
      )
    }
    return metrics
  }

  private static func checkedSum(_ values: UInt64...) throws -> UInt64 {
    try values.reduce(0) { partial, value in
      let result = partial.addingReportingOverflow(value)
      guard !result.overflow else {
        throw MemorySamplingError.arithmeticOverflow
      }
      return result.partialValue
    }
  }

  private static func checkedProduct(
    _ value: UInt64,
    _ multiplier: UInt64
  ) throws -> UInt64 {
    let result = value.multipliedReportingOverflow(by: multiplier)
    guard !result.overflow else {
      throw MemorySamplingError.arithmeticOverflow
    }
    return result.partialValue
  }

  private static func inconsistentSnapshot(
    reason: MemoryCounterInconsistencyReason,
    physicalMemoryBytes: UInt64,
    pageSizeBytes: UInt64,
    counters: RawMemoryPageCounts,
    estimatedMemoryUsedBytes: UInt64? = nil,
    classifiedMemoryUsedBytes: UInt64? = nil,
    excessBytes: UInt64
  ) -> MemorySamplingError {
    .inconsistentSnapshot(
      MemoryCounterInconsistency(
        reason: reason,
        physicalMemoryBytes: physicalMemoryBytes,
        pageSizeBytes: pageSizeBytes,
        counters: counters,
        estimatedMemoryUsedBytes: estimatedMemoryUsedBytes,
        classifiedMemoryUsedBytes: classifiedMemoryUsedBytes,
        excessBytes: excessBytes
      )
    )
  }
}

public enum MemorySampleValidator {
  public static func validate(_ sample: MemorySample) throws {
    let residentSystemComponents = sample.wiredBytes.addingReportingOverflow(
      sample.compressedBytes
    )
    let accountedMemory = sample.estimatedMemoryUsedBytes.addingReportingOverflow(
      sample.estimatedCachedFilesBytes
    )
    guard
      !residentSystemComponents.overflow,
      !accountedMemory.overflow,
      sample.systemUptimeSeconds.isFinite,
      sample.systemUptimeSeconds >= 0,
      sample.physicalMemoryBytes > 0,
      sample.pageSizeBytes > 0,
      sample.estimatedMemoryUsedBytes <= sample.physicalMemoryBytes,
      residentSystemComponents.partialValue <= sample.estimatedMemoryUsedBytes,
      sample.wiredBytes <= sample.physicalMemoryBytes,
      sample.compressedBytes <= sample.physicalMemoryBytes,
      sample.estimatedCachedFilesBytes <= sample.physicalMemoryBytes,
      accountedMemory.partialValue <= sample.physicalMemoryBytes,
      sample.calculationVersion == MemoryMetricsCalculator.calculationVersion,
      (1...MemorySamplingRetryPolicy.phase03.maximumAttempts).contains(
        sample.acquisitionAttemptCount
      ),
      sample.acquisitionQuality == .firstPass
        ? sample.acquisitionAttemptCount == 1
        : sample.acquisitionAttemptCount > 1
    else {
      throw MemorySamplingError.invalidSample
    }
  }
}
