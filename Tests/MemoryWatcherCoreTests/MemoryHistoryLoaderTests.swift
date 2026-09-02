import Foundation
import XCTest

@testable import MemoryWatcherCore

final class MemoryHistoryLoaderTests: XCTestCase {
  func testAutomaticRefreshRequiresVisibleWindowAndFiveMinuteInterval() {
    let policy = MemoryHistoryRefreshPolicy()
    let now = Date(timeIntervalSince1970: 200_000)

    XCTAssertFalse(
      policy.shouldAutomaticallyReload(
        period: .twentyFourHours,
        isWindowVisible: false,
        isLoading: false,
        lastReloadAt: now.addingTimeInterval(-600),
        now: now
      )
    )
    XCTAssertFalse(
      policy.shouldAutomaticallyReload(
        period: .twentyFourHours,
        isWindowVisible: true,
        isLoading: false,
        lastReloadAt: now.addingTimeInterval(-299),
        now: now
      )
    )
    XCTAssertTrue(
      policy.shouldAutomaticallyReload(
        period: .twelveHours,
        isWindowVisible: true,
        isLoading: false,
        lastReloadAt: now.addingTimeInterval(-300),
        now: now
      )
    )
    XCTAssertTrue(
      policy.shouldAutomaticallyReload(
        period: .threeDays,
        isWindowVisible: true,
        isLoading: false,
        lastReloadAt: now.addingTimeInterval(-600),
        now: now
      )
    )
  }

  func testEachPeriodUsesItsRequiredStorageResolution() throws {
    let database = try makeDatabase()
    let day: TimeInterval = 24 * 60 * 60
    let now = Date(timeIntervalSince1970: 40 * day)
    let dates = [
      now.addingTimeInterval(-2.5 * day),
      now.addingTimeInterval(-23 * 60 * 60),
      now.addingTimeInterval(-11 * 60 * 60),
      now.addingTimeInterval(-5 * 60),
    ]
    try database.insert(
      samples: dates.enumerated().map { index, date in
        sample(at: date, value: UInt64(index))
      }
    )
    _ = try database.performHistoryMaintenance(now: now)
    let loader = MemoryHistoryLoader(database: database)

    let twelveHourSnapshot = try loader.load(period: .twelveHours, now: now)
    let daySnapshot = try loader.load(period: .twentyFourHours, now: now)
    let threeDaySnapshot = try loader.load(period: .threeDays, now: now)

    XCTAssertEqual(
      twelveHourSnapshot.points.map(\.timestampUTC),
      Array(dates.suffix(2))
    )
    XCTAssertEqual(Set(twelveHourSnapshot.points.map(\.source)), [.raw])
    XCTAssertEqual(daySnapshot.points.map(\.timestampUTC), Array(dates.suffix(3)))
    XCTAssertEqual(Set(daySnapshot.points.map(\.source)), [.raw])
    XCTAssertEqual(threeDaySnapshot.points.map(\.timestampUTC), dates)
    XCTAssertEqual(Set(threeDaySnapshot.points.map(\.source)), [.oneMinute])
  }

  func testLifecycleGapAndLongIntervalCreateSeparateContinuitySegments() throws {
    let database = try makeDatabase()
    let now = Date(timeIntervalSince1970: 200_000)
    let offsets: [TimeInterval] = [-50, -45, -40, -35, -30, -10]
    try database.insert(
      samples: offsets.enumerated().map { index, offset in
        sample(at: now.addingTimeInterval(offset), value: UInt64(index))
      }
    )
    try database.insert(
      lifecycleEvents: [
        lifecycle(at: now.addingTimeInterval(-44), kind: .sleep, uptime: 1),
        lifecycle(at: now.addingTimeInterval(-41), kind: .wake, uptime: 2),
        lifecycle(
          at: now.addingTimeInterval(-33),
          kind: .clockChanged,
          uptime: 3
        ),
      ]
    )
    try database.insert(
      gaps: [gap(at: now.addingTimeInterval(-37), uptime: 3)]
    )

    let snapshot = try MemoryHistoryLoader(database: database).load(
      period: .twentyFourHours,
      now: now
    )

    XCTAssertEqual(
      snapshot.points.map(\.continuitySegment),
      [0, 0, 1, 2, 3, 4]
    )
    XCTAssertEqual(
      snapshot.sleepIntervals,
      [
        SystemSleepInterval(
          startUTC: now.addingTimeInterval(-44),
          endUTC: now.addingTimeInterval(-41)
        )
      ]
    )
  }

  func testPressureIntervalsCarryKnownStateAndPreserveUnknown() throws {
    let database = try makeDatabase()
    let now = Date(timeIntervalSince1970: 200_000)
    let start = now.addingTimeInterval(-24 * 60 * 60)
    try database.insert(
      pressureObservations: [
        pressure(at: start.addingTimeInterval(-60), level: .normal, uptime: 1),
        pressure(at: start.addingTimeInterval(10), level: .warning, uptime: 2),
        pressure(at: start.addingTimeInterval(20), level: .critical, uptime: 3),
      ]
    )

    let snapshot = try MemoryHistoryLoader(database: database).load(
      period: .twentyFourHours,
      now: now
    )

    XCTAssertEqual(snapshot.pressureIntervals.count, 3)
    XCTAssertEqual(
      snapshot.pressureIntervals.map(\.level),
      [
        .normal,
        .warning,
        .critical,
      ])
    XCTAssertEqual(snapshot.pressureIntervals[0].startUTC, start)
    XCTAssertEqual(
      snapshot.pressureIntervals[0].endUTC,
      start.addingTimeInterval(10)
    )

    let unknownDatabase = try makeDatabase()
    let unknown = try MemoryHistoryLoader(database: unknownDatabase).load(
      period: .twentyFourHours,
      now: now
    )
    XCTAssertEqual(
      unknown.pressureIntervals,
      [
        MemoryPressureInterval(startUTC: start, endUTC: now, level: .unknown)
      ])
  }

  func testThreeDaySnapshotWithFourThousandThreeHundredTwentyPointsLoadsUnderTwoSeconds() throws {
    let database = try makeDatabase()
    let now = Date(timeIntervalSince1970: 40 * 24 * 60 * 60)
    let start = now.addingTimeInterval(-3 * 24 * 60 * 60)
    let samples = (0..<4_320).map { index in
      sample(
        at: start.addingTimeInterval(Double(index) * 60),
        value: UInt64(index % 1_000)
      )
    }
    try database.insert(samples: samples)
    _ = try database.performHistoryMaintenance(now: now)

    let startedAt = Date()
    let snapshot = try MemoryHistoryLoader(database: database).load(
      period: .threeDays,
      now: now
    )
    let elapsed = Date().timeIntervalSince(startedAt)

    XCTAssertEqual(snapshot.points.count, 4_320)
    XCTAssertEqual(Set(snapshot.points.map(\.source)), [.oneMinute])
    XCTAssertLessThan(elapsed, 2)
  }

  func testHistoryPointCompositionAddsBackToEstimatedUsed() throws {
    let database = try makeDatabase()
    let now = Date(timeIntervalSince1970: 200_000)
    try database.insert(
      samples: [sample(at: now.addingTimeInterval(-5), value: 0)]
    )

    let point = try XCTUnwrap(
      MemoryHistoryLoader(database: database).load(
        period: .twentyFourHours,
        now: now
      ).points.first
    )

    XCTAssertEqual(
      point.estimatedOtherUsedBytes + point.wiredBytes + point.compressedBytes,
      point.estimatedMemoryUsedBytes,
      accuracy: 0.000_001
    )
  }

  private func makeDatabase() throws -> MemoryWatcherDatabase {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
    }
    return try MemoryWatcherDatabase(
      url: directory.appendingPathComponent("history-loader.sqlite3")
    )
  }

  private func sample(at date: Date, value: UInt64) -> MemorySample {
    MemorySample(
      timestampUTC: date,
      systemUptimeSeconds: max(0, date.timeIntervalSince1970),
      physicalMemoryBytes: 1_000_000 + value,
      estimatedMemoryUsedBytes: 500_000 + value,
      wiredBytes: 100_000,
      compressedBytes: 50_000,
      estimatedCachedFilesBytes: 200_000,
      swapUsedBytes: 10_000 + value,
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

  private func pressure(
    at date: Date,
    level: MemoryPressureLevel,
    uptime: TimeInterval
  ) -> MemoryPressureObservation {
    MemoryPressureObservation(
      timestampUTC: date,
      systemUptimeSeconds: uptime,
      level: level
    )
  }

  private func lifecycle(
    at date: Date,
    kind: SystemLifecycleEventKind,
    uptime: TimeInterval
  ) -> SystemLifecycleEvent {
    SystemLifecycleEvent(
      timestampUTC: date,
      systemUptimeSeconds: uptime,
      kind: kind
    )
  }

  private func gap(at date: Date, uptime: TimeInterval) -> MemorySamplingGap {
    MemorySamplingGap(
      timestampUTC: date,
      systemUptimeSeconds: uptime,
      acquisitionAttemptCount: 3,
      lastInconsistency: MemoryCounterInconsistency(
        reason: .classifiedExceedsEstimatedUsed,
        physicalMemoryBytes: 100 * 4_096,
        pageSizeBytes: 4_096,
        counters: RawMemoryPageCounts(
          free: 20,
          active: 20,
          inactive: 10,
          wired: 20,
          speculative: 0,
          purgeable: 0,
          compressor: 20,
          external: 10,
          internalPages: 60
        ),
        estimatedMemoryUsedBytes: 70 * 4_096,
        classifiedMemoryUsedBytes: 100 * 4_096,
        excessBytes: 30 * 4_096
      )
    )
  }
}
