import Foundation
import MemoryWatcherCore

enum HistoryUISmokeFixture {
  static func populate(
    database: MemoryWatcherDatabase,
    now: Date
  ) throws {
    let fiveMinutes: TimeInterval = 5 * 60
    let start = now.addingTimeInterval(-30 * 24 * 60 * 60)
    let sleepStartIndex = 4_320
    let sleepEndIndex = sleepStartIndex + 24

    let samples = (0..<8_640).compactMap { index -> MemorySample? in
      guard !(sleepStartIndex..<sleepEndIndex).contains(index) else {
        return nil
      }
      let dayPosition = UInt64(index % 288)
      let used = 6_000_000_000 + dayPosition * 6_000_000
      let compressed = 350_000_000 + UInt64(index % 96) * 5_000_000
      return MemorySample(
        timestampUTC: start.addingTimeInterval(Double(index) * fiveMinutes),
        systemUptimeSeconds: 100_000 + Double(index) * fiveMinutes,
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
      Double(sleepStartIndex) * fiveMinutes
    )
    let sleepEnd = start.addingTimeInterval(
      Double(sleepEndIndex) * fiveMinutes
    )
    try database.insert(
      lifecycleEvents: [
        SystemLifecycleEvent(
          timestampUTC: sleepStart,
          systemUptimeSeconds: 100_000 + Double(sleepStartIndex) * fiveMinutes,
          kind: .sleep
        ),
        SystemLifecycleEvent(
          timestampUTC: sleepEnd,
          systemUptimeSeconds: 100_000 + Double(sleepEndIndex) * fiveMinutes,
          kind: .wake
        ),
      ]
    )
    try database.insert(
      pressureObservations: [
        pressure(at: start, uptime: 100_000, level: .normal),
        pressure(
          at: start.addingTimeInterval(10 * 24 * 60 * 60),
          uptime: 964_000,
          level: .warning
        ),
        pressure(
          at: start.addingTimeInterval(11 * 24 * 60 * 60),
          uptime: 1_050_400,
          level: .critical
        ),
        pressure(
          at: start.addingTimeInterval(12 * 24 * 60 * 60),
          uptime: 1_136_800,
          level: .normal
        ),
      ]
    )
    _ = try database.performHistoryMaintenance(now: now)
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
