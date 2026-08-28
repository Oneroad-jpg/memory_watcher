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
  public let memoryUsedBytes: UInt64
  public let wiredBytes: UInt64
  public let compressedBytes: UInt64
  public let cachedBytes: UInt64
  public let swapUsedBytes: UInt64
  public let pageSizeBytes: UInt64
  public let rawPageCounts: RawMemoryPageCounts
  public let calculationVersion: String

  public init(
    timestampUTC: Date,
    systemUptimeSeconds: TimeInterval,
    physicalMemoryBytes: UInt64,
    memoryUsedBytes: UInt64,
    wiredBytes: UInt64,
    compressedBytes: UInt64,
    cachedBytes: UInt64,
    swapUsedBytes: UInt64,
    pageSizeBytes: UInt64,
    rawPageCounts: RawMemoryPageCounts,
    calculationVersion: String
  ) {
    self.timestampUTC = timestampUTC
    self.systemUptimeSeconds = systemUptimeSeconds
    self.physicalMemoryBytes = physicalMemoryBytes
    self.memoryUsedBytes = memoryUsedBytes
    self.wiredBytes = wiredBytes
    self.compressedBytes = compressedBytes
    self.cachedBytes = cachedBytes
    self.swapUsedBytes = swapUsedBytes
    self.pageSizeBytes = pageSizeBytes
    self.rawPageCounts = rawPageCounts
    self.calculationVersion = calculationVersion
  }
}

public struct DerivedMemoryMetrics: Equatable, Sendable {
  public let memoryUsedBytes: UInt64
  public let wiredBytes: UInt64
  public let compressedBytes: UInt64
  public let cachedBytes: UInt64
}

public enum MemorySamplingError: Error, Equatable, Sendable {
  case hostPageSize(Int32)
  case hostStatistics(Int32)
  case swapUsage(Int32)
  case invalidCounterRelationship
  case arithmeticOverflow
  case derivedValueExceedsPhysicalMemory
  case invalidSample
}

public enum MemoryMetricsCalculator {
  public static let calculationVersion = "phase-02-v1"

  public static func calculate(
    physicalMemoryBytes: UInt64,
    pageSizeBytes: UInt64,
    counters: RawMemoryPageCounts
  ) throws -> DerivedMemoryMetrics {
    guard physicalMemoryBytes > 0, pageSizeBytes > 0 else {
      throw MemorySamplingError.invalidSample
    }
    guard counters.internalPages >= counters.purgeable else {
      throw MemorySamplingError.invalidCounterRelationship
    }

    let applicationPages = counters.internalPages - counters.purgeable
    let usedPages = try checkedSum(
      applicationPages,
      counters.wired,
      counters.compressor
    )
    let cachedPages = try checkedSum(counters.external, counters.purgeable)

    let metrics = DerivedMemoryMetrics(
      memoryUsedBytes: try checkedProduct(usedPages, pageSizeBytes),
      wiredBytes: try checkedProduct(counters.wired, pageSizeBytes),
      compressedBytes: try checkedProduct(counters.compressor, pageSizeBytes),
      cachedBytes: try checkedProduct(cachedPages, pageSizeBytes)
    )

    guard
      metrics.memoryUsedBytes <= physicalMemoryBytes,
      metrics.wiredBytes <= physicalMemoryBytes,
      metrics.compressedBytes <= physicalMemoryBytes,
      metrics.cachedBytes <= physicalMemoryBytes
    else {
      throw MemorySamplingError.derivedValueExceedsPhysicalMemory
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
}

public enum MemorySampleValidator {
  public static func validate(_ sample: MemorySample) throws {
    guard
      sample.systemUptimeSeconds.isFinite,
      sample.systemUptimeSeconds >= 0,
      sample.physicalMemoryBytes > 0,
      sample.pageSizeBytes > 0,
      sample.memoryUsedBytes <= sample.physicalMemoryBytes,
      sample.wiredBytes <= sample.physicalMemoryBytes,
      sample.compressedBytes <= sample.physicalMemoryBytes,
      sample.cachedBytes <= sample.physicalMemoryBytes,
      sample.calculationVersion == MemoryMetricsCalculator.calculationVersion
    else {
      throw MemorySamplingError.invalidSample
    }
  }
}
