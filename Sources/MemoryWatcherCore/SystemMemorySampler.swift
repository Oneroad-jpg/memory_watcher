import Darwin
import Foundation

public struct SystemMemorySampler: Sendable {
  public init() {}

  public func sample(
    timestampUTC: Date = Date(),
    systemUptimeSeconds: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) throws -> MemorySample {
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
    let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    let pageSizeBytes = UInt64(pageSize)
    let metrics = try MemoryMetricsCalculator.calculate(
      physicalMemoryBytes: physicalMemoryBytes,
      pageSizeBytes: pageSizeBytes,
      counters: counters
    )

    let sample = MemorySample(
      timestampUTC: timestampUTC,
      systemUptimeSeconds: systemUptimeSeconds,
      physicalMemoryBytes: physicalMemoryBytes,
      memoryUsedBytes: metrics.memoryUsedBytes,
      wiredBytes: metrics.wiredBytes,
      compressedBytes: metrics.compressedBytes,
      cachedBytes: metrics.cachedBytes,
      swapUsedBytes: try swapUsedBytes(),
      pageSizeBytes: pageSizeBytes,
      rawPageCounts: counters,
      calculationVersion: MemoryMetricsCalculator.calculationVersion
    )
    try MemorySampleValidator.validate(sample)
    return sample
  }

  private func swapUsedBytes() throws -> UInt64 {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.stride
    let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
    guard result == 0 else {
      throw MemorySamplingError.swapUsage(errno)
    }
    return UInt64(usage.xsu_used)
  }
}
