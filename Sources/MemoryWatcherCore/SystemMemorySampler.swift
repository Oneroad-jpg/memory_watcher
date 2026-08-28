import Darwin
import Foundation

public struct MemoryCounterSnapshot: Equatable, Sendable {
  public let timestampUTC: Date
  public let systemUptimeSeconds: TimeInterval
  public let physicalMemoryBytes: UInt64
  public let pageSizeBytes: UInt64
  public let counters: RawMemoryPageCounts
  public let swapUsedBytes: UInt64

  public init(
    timestampUTC: Date,
    systemUptimeSeconds: TimeInterval,
    physicalMemoryBytes: UInt64,
    pageSizeBytes: UInt64,
    counters: RawMemoryPageCounts,
    swapUsedBytes: UInt64
  ) {
    self.timestampUTC = timestampUTC
    self.systemUptimeSeconds = systemUptimeSeconds
    self.physicalMemoryBytes = physicalMemoryBytes
    self.pageSizeBytes = pageSizeBytes
    self.counters = counters
    self.swapUsedBytes = swapUsedBytes
  }
}

public struct MemorySamplingRetryPolicy: Equatable, Sendable {
  public static let phase03 = MemorySamplingRetryPolicy(
    maximumAttempts: 3,
    delaySeconds: 0.05
  )

  public let maximumAttempts: Int
  public let delaySeconds: TimeInterval

  public init(maximumAttempts: Int, delaySeconds: TimeInterval) {
    precondition(maximumAttempts > 0)
    precondition(delaySeconds >= 0)
    self.maximumAttempts = maximumAttempts
    self.delaySeconds = delaySeconds
  }
}

public struct SystemMemorySampler: Sendable {
  private let snapshotProvider: @Sendable () throws -> MemoryCounterSnapshot
  private let retryPolicy: MemorySamplingRetryPolicy
  private let sleep: @Sendable (TimeInterval) -> Void

  public init() {
    snapshotProvider = Self.readSystemSnapshot
    retryPolicy = .phase03
    sleep = { Thread.sleep(forTimeInterval: $0) }
  }

  init(
    snapshotProvider: @escaping @Sendable () throws -> MemoryCounterSnapshot,
    retryPolicy: MemorySamplingRetryPolicy = .phase03,
    sleep: @escaping @Sendable (TimeInterval) -> Void = {
      Thread.sleep(forTimeInterval: $0)
    }
  ) {
    self.snapshotProvider = snapshotProvider
    self.retryPolicy = retryPolicy
    self.sleep = sleep
  }

  public func sample() throws -> MemorySample {
    var lastSnapshot: MemoryCounterSnapshot?
    var lastInconsistency: MemoryCounterInconsistency?

    for attempt in 1...retryPolicy.maximumAttempts {
      let snapshot = try snapshotProvider()
      do {
        let metrics = try MemoryMetricsCalculator.calculate(
          physicalMemoryBytes: snapshot.physicalMemoryBytes,
          pageSizeBytes: snapshot.pageSizeBytes,
          counters: snapshot.counters
        )
        let sample = MemorySample(
          timestampUTC: snapshot.timestampUTC,
          systemUptimeSeconds: snapshot.systemUptimeSeconds,
          physicalMemoryBytes: snapshot.physicalMemoryBytes,
          estimatedMemoryUsedBytes: metrics.estimatedMemoryUsedBytes,
          wiredBytes: metrics.wiredBytes,
          compressedBytes: metrics.compressedBytes,
          estimatedCachedFilesBytes: metrics.estimatedCachedFilesBytes,
          swapUsedBytes: snapshot.swapUsedBytes,
          pageSizeBytes: snapshot.pageSizeBytes,
          rawPageCounts: snapshot.counters,
          calculationVersion: MemoryMetricsCalculator.calculationVersion,
          acquisitionQuality: attempt == 1 ? .firstPass : .retried,
          acquisitionAttemptCount: attempt
        )
        try MemorySampleValidator.validate(sample)
        return sample
      } catch MemorySamplingError.inconsistentSnapshot(let diagnostic) {
        lastSnapshot = snapshot
        lastInconsistency = diagnostic
        if attempt < retryPolicy.maximumAttempts {
          sleep(retryPolicy.delaySeconds)
        }
      }
    }

    guard let lastSnapshot, let lastInconsistency else {
      throw MemorySamplingError.invalidSample
    }
    throw MemorySamplingError.samplingAttemptsExhausted(
      MemorySamplingGap(
        timestampUTC: lastSnapshot.timestampUTC,
        systemUptimeSeconds: lastSnapshot.systemUptimeSeconds,
        acquisitionAttemptCount: retryPolicy.maximumAttempts,
        lastInconsistency: lastInconsistency
      )
    )
  }

  public func sampleOutcome() throws -> MemorySamplingOutcome {
    do {
      return .sample(try sample())
    } catch MemorySamplingError.samplingAttemptsExhausted(let gap) {
      return .gap(gap)
    }
  }

  private static func readSystemSnapshot() throws -> MemoryCounterSnapshot {
    let host = mach_host_self()
    defer {
      mach_port_deallocate(mach_task_self_, host)
    }
    var pageSize: vm_size_t = 0
    let pageSizeResult = host_page_size(host, &pageSize)
    guard pageSizeResult == KERN_SUCCESS else {
      throw MemorySamplingError.hostPageSize(pageSizeResult)
    }

    var statistics = vm_statistics64_data_t()
    var statisticsCount = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.stride
        / MemoryLayout<integer_t>.stride
    )
    let statisticsResult = withUnsafeMutablePointer(to: &statistics) {
      statisticsPointer in
      statisticsPointer.withMemoryRebound(
        to: integer_t.self,
        capacity: Int(statisticsCount)
      ) { reboundPointer in
        host_statistics64(
          host,
          HOST_VM_INFO64,
          reboundPointer,
          &statisticsCount
        )
      }
    }
    guard statisticsResult == KERN_SUCCESS else {
      throw MemorySamplingError.hostStatistics(statisticsResult)
    }

    let counters = RawMemoryPageCounts(
      free: UInt64(statistics.free_count),
      active: UInt64(statistics.active_count),
      inactive: UInt64(statistics.inactive_count),
      wired: UInt64(statistics.wire_count),
      speculative: UInt64(statistics.speculative_count),
      purgeable: UInt64(statistics.purgeable_count),
      compressor: UInt64(statistics.compressor_page_count),
      external: UInt64(statistics.external_page_count),
      internalPages: UInt64(statistics.internal_page_count)
    )

    return MemoryCounterSnapshot(
      timestampUTC: Date(),
      systemUptimeSeconds: ProcessInfo.processInfo.systemUptime,
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
      pageSizeBytes: UInt64(pageSize),
      counters: counters,
      swapUsedBytes: try readSwapUsedBytes()
    )
  }

  private static func readSwapUsedBytes() throws -> UInt64 {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.stride
    let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
    guard result == 0 else {
      throw MemorySamplingError.swapUsage(errno)
    }
    return UInt64(usage.xsu_used)
  }
}
