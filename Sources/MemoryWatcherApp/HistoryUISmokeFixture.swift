import Foundation
import MemoryWatcherCore

enum HistoryUISmokeFixture {
  static func populate(
    database: MemoryWatcherDatabase,
    now: Date
  ) throws {
    let oneMinute: TimeInterval = 60
    let start = now.addingTimeInterval(-3 * 24 * 60 * 60)
    let sleepStartIndex = 2_160
    let sleepEndIndex = sleepStartIndex + 120

    let samples = (0..<4_320).compactMap { index -> MemorySample? in
      guard !(sleepStartIndex..<sleepEndIndex).contains(index) else {
        return nil
      }
      let dayPosition = UInt64(index % 288)
      let used = 6_000_000_000 + dayPosition * 6_000_000
      let compressed = 350_000_000 + UInt64(index % 96) * 5_000_000
      return MemorySample(
        timestampUTC: start.addingTimeInterval(Double(index) * oneMinute),
        systemUptimeSeconds: 100_000 + Double(index) * oneMinute,
        physicalMemoryBytes: 16_000_000_000,
        estimatedMemoryUsedBytes: used,
        wiredBytes: 1_200_000_000,
        compressedBytes: compressed,
        estimatedCachedFilesBytes: 3_000_000_000,
        swapUsedBytes: UInt64(index % 144) * 4_000_000,
        pageSizeBytes: 4_096,
        rawPageCounts: RawMemoryPageCounts(
          free: 50,
          active: 40,
          inactive: 30,
          wired: 20,
          speculative: 5,
          purgeable: 10,
          compressor: 5,
          external: 30,
          internalPages: 100
        ),
        calculationVersion: MemoryMetricsCalculator.calculationVersion,
        acquisitionQuality: .firstPass,
        acquisitionAttemptCount: 1
      )
    }
    try database.insert(samples: samples)

    let sleepStart = start.addingTimeInterval(
      Double(sleepStartIndex) * oneMinute
    )
    let sleepEnd = start.addingTimeInterval(
      Double(sleepEndIndex) * oneMinute
    )
    try database.insert(
      lifecycleEvents: [
        SystemLifecycleEvent(
          timestampUTC: sleepStart,
          systemUptimeSeconds: 100_000 + Double(sleepStartIndex) * oneMinute,
          kind: .sleep
        ),
        SystemLifecycleEvent(
          timestampUTC: sleepEnd,
          systemUptimeSeconds: 100_000 + Double(sleepEndIndex) * oneMinute,
          kind: .wake
        ),
      ]
    )
    try database.insert(
      pressureObservations: [
        pressure(at: start, uptime: 100_000, level: .normal),
        pressure(
          at: start.addingTimeInterval(24 * 60 * 60),
          uptime: 186_400,
          level: .warning
        ),
        pressure(
          at: start.addingTimeInterval(30 * 60 * 60),
          uptime: 208_000,
          level: .critical
        ),
        pressure(
          at: start.addingTimeInterval(36 * 60 * 60),
          uptime: 229_600,
          level: .normal
        ),
      ]
    )
    let cpuIndexes = (0..<4_320).filter {
      !(sleepStartIndex..<sleepEndIndex).contains($0)
    }
    try database.insert(
      totalCPUSamples: cpuIndexes.map { index in
        totalCPUSample(at: start, index: index)
      }
    )
    let topology = LogicalCPUTopology(
      epochKey: "history-smoke-logical-8",
      bootSessionStartUTC: start.addingTimeInterval(-1_000),
      logicalCPUCount: 8
    )
    for index in cpuIndexes {
      try database.insert(
        logicalCPUSamples: logicalCPUSamples(
          topology: topology,
          at: start,
          index: index
        )
      )
    }
    _ = try database.performHistoryMaintenance(now: now)
  }

  private static func totalCPUSample(
    at start: Date,
    index: Int
  ) -> TotalCPUSample {
    let end = start.addingTimeInterval(Double(index) * 60 + 5)
    let busy = UInt64(20 + index % 70)
    return TotalCPUSample(
      intervalStartUTC: end.addingTimeInterval(-5),
      intervalEndUTC: end,
      intervalStartUptimeSeconds: 100_000 + Double(index) * 60,
      intervalEndUptimeSeconds: 100_005 + Double(index) * 60,
      delta: cpuDelta(busy: busy, idle: 100 - busy),
      quality: .measured
    )
  }

  private static func logicalCPUSamples(
    topology: LogicalCPUTopology,
    at start: Date,
    index: Int
  ) -> [LogicalCPUSample] {
    let end = start.addingTimeInterval(Double(index) * 60 + 5)
    return (0..<topology.logicalCPUCount).map { cpuIndex in
      let busy = UInt64(10 + (index * (cpuIndex + 1)) % 85)
      return LogicalCPUSample(
        topology: topology,
        cpuIndex: cpuIndex,
        intervalStartUTC: end.addingTimeInterval(-5),
        intervalEndUTC: end,
        intervalStartUptimeSeconds: 100_000 + Double(index) * 60,
        intervalEndUptimeSeconds: 100_005 + Double(index) * 60,
        delta: cpuDelta(busy: busy, idle: 100 - busy),
        quality: .measured
      )
    }
  }

  private static func cpuDelta(busy: UInt64, idle: UInt64) -> CPUCounterDelta {
    let user = busy * 2 / 3
    let system = busy - user
    let result = CPUUtilizationCalculator.calculate(
      previous: CPUCounterSnapshot(
        userTicks: 0,
        systemTicks: 0,
        idleTicks: 0,
        niceTicks: 0
      ),
      current: CPUCounterSnapshot(
        userTicks: user,
        systemTicks: system,
        idleTicks: idle,
        niceTicks: 0
      )
    )
    guard case .measured(let delta) = result else {
      preconditionFailure("The fixed smoke-test counters must produce a measured CPU delta")
    }
    return delta
  }

  private static func pressure(
    at date: Date,
    uptime: TimeInterval,
    level: MemoryPressureLevel
  ) -> MemoryPressureObservation {
    MemoryPressureObservation(
      timestampUTC: date,
      systemUptimeSeconds: uptime,
      level: level
    )
  }
}
