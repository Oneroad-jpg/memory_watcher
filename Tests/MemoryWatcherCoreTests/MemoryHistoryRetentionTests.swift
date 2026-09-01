import CSQLite
import Foundation
import XCTest

@testable import MemoryWatcherCore

final class MemoryHistoryRetentionTests: XCTestCase {
  func testVersionTwoDatabaseMigratesThroughVersionFiveWithoutLosingRawSamples() throws {
    let directory = try makeTemporaryDirectory()
    let databaseURL = directory.appendingPathComponent("migration.sqlite3")
    let preservedSample = sample(
      at: Date(timeIntervalSince1970: 120_005),
      value: 77
    )
    var database: MemoryWatcherDatabase? = try MemoryWatcherDatabase(
      url: databaseURL
    )
    try database?.insert(samples: [preservedSample])
    database = nil

    try convertVersionThreeFixtureToVersionTwo(at: databaseURL)

    let migrated = try MemoryWatcherDatabase(url: databaseURL)
    XCTAssertEqual(try migrated.schemaVersion(), 5)
    XCTAssertEqual(try migrated.fetchSamples(), [preservedSample])
    XCTAssertEqual(try migrated.aggregateCount(resolution: .oneMinute), 0)
    XCTAssertEqual(try migrated.aggregateCount(resolution: .fiveMinutes), 0)
    XCTAssertEqual(try migrated.totalCPUSampleCount(), 0)
    XCTAssertEqual(try migrated.integrityCheck(), "ok")
  }

  func testVersionThreeDatabaseMigratesToVersionFiveWithoutLosingMemoryHistory()
    throws
  {
    let directory = try makeTemporaryDirectory()
    let databaseURL = directory.appendingPathComponent("migration-v3.sqlite3")
    let preservedSample = sample(
      at: Date(timeIntervalSince1970: 180_005),
      value: 88
    )
    var database: MemoryWatcherDatabase? = try MemoryWatcherDatabase(
      url: databaseURL
    )
    try database?.insert(samples: [preservedSample])
    database = nil

    try convertVersionFourFixtureToVersionThree(at: databaseURL)

    let migrated = try MemoryWatcherDatabase(url: databaseURL)
    XCTAssertEqual(try migrated.schemaVersion(), 5)
    XCTAssertEqual(try migrated.fetchSamples(), [preservedSample])
    XCTAssertEqual(try migrated.totalCPUSampleCount(), 0)
    XCTAssertEqual(try migrated.integrityCheck(), "ok")
  }

  func testOneMinuteAggregationUsesExactAverageAndLeavesNoSyntheticBuckets() throws {
    let database = try makeDatabase()
    let bucketStart = Date(timeIntervalSince1970: 120_000)
    try database.insert(
      samples: [
        sample(at: bucketStart.addingTimeInterval(5), value: 100),
        sample(at: bucketStart.addingTimeInterval(10), value: 300),
        sample(at: bucketStart.addingTimeInterval(125), value: 900),
      ]
    )

    _ = try database.performHistoryMaintenance(
      now: bucketStart.addingTimeInterval(180)
    )

    let aggregates = try database.fetchAggregates(resolution: .oneMinute)
    XCTAssertEqual(aggregates.count, 2)
    XCTAssertEqual(aggregates[0].bucketStartUTC, bucketStart)
    XCTAssertEqual(aggregates[0].sampleCount, 2)
    XCTAssertEqual(aggregates[0].averagePhysicalMemoryBytes, 1_000_200)
    XCTAssertEqual(
      aggregates[0].averageEstimatedMemoryUsedBytes,
      500_200,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      aggregates[0].averageSwapUsedBytes,
      10_200,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      aggregates[1].bucketStartUTC,
      bucketStart.addingTimeInterval(120)
    )
    XCTAssertEqual(aggregates[1].sampleCount, 1)
  }

  func testFiveMinuteAggregationUsesSampleCountWeightedAverage() throws {
    let database = try makeDatabase()
    let bucketStart = Date(timeIntervalSince1970: 120_000)
    try database.insert(
      samples: [
        sample(at: bucketStart.addingTimeInterval(5), value: 100),
        sample(at: bucketStart.addingTimeInterval(10), value: 100),
        sample(at: bucketStart.addingTimeInterval(15), value: 100),
        sample(at: bucketStart.addingTimeInterval(65), value: 400),
      ]
    )

    _ = try database.performHistoryMaintenance(
      now: bucketStart.addingTimeInterval(600)
    )

    let minuteAggregates = try database.fetchAggregates(
      resolution: .oneMinute
    )
    let fiveMinuteAggregates = try database.fetchAggregates(
      resolution: .fiveMinutes
    )
    XCTAssertEqual(minuteAggregates.map(\.sampleCount), [3, 1])
    XCTAssertEqual(fiveMinuteAggregates.count, 1)
    XCTAssertEqual(fiveMinuteAggregates[0].sampleCount, 4)
    XCTAssertEqual(
      fiveMinuteAggregates[0].averageEstimatedMemoryUsedBytes,
      500_175,
      accuracy: 0.000_001
    )
  }

  func testTotalCPUAggregationSumsTicksInsteadOfAveragingPercentages() throws {
    let database = try makeDatabase()
    let bucketStart = Date(timeIntervalSince1970: 240_000)
    try database.insert(
      totalCPUSamples: [
        totalCPUSample(
          endingAt: bucketStart.addingTimeInterval(5),
          busy: 90,
          idle: 10
        ),
        totalCPUSample(
          endingAt: bucketStart.addingTimeInterval(10),
          busy: 10,
          idle: 190
        ),
        unknownTotalCPUSample(
          endingAt: bucketStart.addingTimeInterval(15),
          quality: .unavailable
        ),
      ]
    )

    _ = try database.performHistoryMaintenance(
      now: bucketStart.addingTimeInterval(600)
    )

    let oneMinute = try XCTUnwrap(
      database.fetchTotalCPUAggregates(resolution: .oneMinute).first
    )
    let fiveMinutes = try XCTUnwrap(
      database.fetchTotalCPUAggregates(resolution: .fiveMinutes).first
    )
    XCTAssertEqual(oneMinute.sampleCount, 2)
    XCTAssertEqual(oneMinute.summedBusyTicks, 100)
    XCTAssertEqual(oneMinute.summedIdleTicks, 200)
    XCTAssertEqual(oneMinute.summedTotalTicks, 300)
    XCTAssertEqual(oneMinute.utilizationPercent, 100.0 / 3.0, accuracy: 0.000_001)
    XCTAssertEqual(fiveMinutes.sampleCount, 2)
    XCTAssertEqual(fiveMinutes.summedTotalTicks, 300)
    XCTAssertEqual(fiveMinutes.utilizationPercent, 100.0 / 3.0, accuracy: 0.000_001)
  }

  func testTotalCPUThreeDayFixtureHonorsRawAndAggregateBoundaries() throws {
    let database = try makeDatabase()
    let day: TimeInterval = 24 * 60 * 60
    let now = Date(timeIntervalSince1970: 50 * day)
    try database.insert(
      totalCPUSamples: [
        totalCPUSample(endingAt: now.addingTimeInterval(-4 * day), busy: 10, idle: 90),
        unknownTotalCPUSample(
          endingAt: now.addingTimeInterval(-4 * day + 5),
          quality: .wakeBoundary
        ),
        totalCPUSample(
          endingAt: now.addingTimeInterval(-3 * day + 5),
          busy: 20,
          idle: 80
        ),
        totalCPUSample(endingAt: now.addingTimeInterval(-day), busy: 30, idle: 70),
        totalCPUSample(endingAt: now, busy: 40, idle: 60),
      ]
    )

    _ = try database.performHistoryMaintenance(now: now)

    XCTAssertEqual(
      try database.fetchTotalCPUSamples().map(\.intervalEndUTC),
      [now.addingTimeInterval(-day), now]
    )
    XCTAssertEqual(
      try database.fetchTotalCPUAggregates(resolution: .oneMinute).first?
        .bucketStartUTC,
      now.addingTimeInterval(-3 * day)
    )
    XCTAssertEqual(
      try database.totalCPUAggregateCount(resolution: .oneMinute),
      3
    )
    XCTAssertEqual(
      try database.totalCPUAggregateCount(resolution: .fiveMinutes),
      3
    )
    XCTAssertEqual(try database.integrityCheck(), "ok")
  }

  func testFourDayDataHonorsEveryRetentionBoundary() throws {
    let database = try makeDatabase()
    let day: TimeInterval = 24 * 60 * 60
    let now = Date(timeIntervalSince1970: 40 * day)
    let samples = (0...4).map { ageInDays in
      sample(
        at: now.addingTimeInterval(-Double(ageInDays) * day),
        value: UInt64(ageInDays)
      )
    }
    try database.insert(samples: samples)

    let expiredDate = now.addingTimeInterval(-4 * day)
    let boundaryDate = now.addingTimeInterval(-3 * day)
    try database.insert(
      pressureObservations: [
        pressure(at: expiredDate, uptime: 1, level: .warning),
        pressure(at: boundaryDate, uptime: 2, level: .normal),
      ]
    )
    try database.insert(
      gaps: [
        gap(at: expiredDate, uptime: 3),
        gap(at: boundaryDate, uptime: 4),
      ]
    )
    try database.insert(
      lifecycleEvents: [
        lifecycle(at: expiredDate, uptime: 5),
        lifecycle(at: boundaryDate, uptime: 6),
      ]
    )

    _ = try database.performHistoryMaintenance(now: now)

    XCTAssertEqual(
      try database.fetchSamples().map(\.timestampUTC),
      [
        now.addingTimeInterval(-day),
        now,
      ])
    XCTAssertEqual(try database.aggregateCount(resolution: .oneMinute), 3)
    XCTAssertEqual(try database.aggregateCount(resolution: .fiveMinutes), 3)
    XCTAssertEqual(
      try database.fetchAggregates(resolution: .oneMinute).first?.bucketStartUTC,
      boundaryDate
    )
    XCTAssertEqual(
      try database.fetchAggregates(resolution: .fiveMinutes).first?.bucketStartUTC,
      boundaryDate
    )
    XCTAssertEqual(try database.pressureObservationCount(), 1)
    XCTAssertEqual(try database.fetchPressureObservations().first?.timestampUTC, boundaryDate)
    XCTAssertEqual(try database.samplingGapCount(), 1)
    XCTAssertEqual(try database.fetchSamplingGaps().first?.timestampUTC, boundaryDate)
    XCTAssertEqual(try database.lifecycleEventCount(), 1)
    XCTAssertEqual(try database.fetchLifecycleEvents().first?.timestampUTC, boundaryDate)
    XCTAssertEqual(try database.integrityCheck(), "ok")
  }

  func testFailureBeforeDeletionRollsBackAggregatesAndPreservesRawSamples() throws {
    let database = try makeDatabase()
    let now = Date(timeIntervalSince1970: 40 * 24 * 60 * 60)
    try database.insert(
      samples: [sample(at: now.addingTimeInterval(-2 * 24 * 60 * 60), value: 1)]
    )
    let cpuSample = totalCPUSample(
      endingAt: now.addingTimeInterval(-2 * 24 * 60 * 60),
      busy: 50,
      idle: 50
    )
    try database.insert(totalCPUSamples: [cpuSample])
    let logicalTopology = LogicalCPUTopology(
      epochKey: "rollback-logical-1",
      bootSessionStartUTC: Date(timeIntervalSince1970: 1),
      logicalCPUCount: 1
    )
    let logicalSample = LogicalCPUSample(
      topology: logicalTopology,
      cpuIndex: 0,
      intervalStartUTC: now.addingTimeInterval(-2 * 24 * 60 * 60 - 5),
      intervalEndUTC: now.addingTimeInterval(-2 * 24 * 60 * 60),
      intervalStartUptimeSeconds: 95,
      intervalEndUptimeSeconds: 100,
      delta: CPUCounterDelta(
        userTicks: 20,
        systemTicks: 10,
        idleTicks: 70,
        niceTicks: 0,
        busyTicks: 30,
        totalTicks: 100
      ),
      quality: .measured
    )
    try database.insert(logicalCPUSamples: [logicalSample])

    XCTAssertThrowsError(
      try database.performHistoryMaintenance(
        now: now,
        beforeSourceDeletion: { throw ExpectedFailure.stop }
      )
    ) { error in
      XCTAssertEqual(error as? ExpectedFailure, .stop)
    }

    XCTAssertEqual(try database.sampleCount(), 1)
    XCTAssertEqual(try database.aggregateCount(resolution: .oneMinute), 0)
    XCTAssertEqual(try database.aggregateCount(resolution: .fiveMinutes), 0)
    XCTAssertEqual(try database.fetchTotalCPUSamples(), [cpuSample])
    XCTAssertEqual(
      try database.totalCPUAggregateCount(resolution: .oneMinute),
      0
    )
    XCTAssertEqual(
      try database.totalCPUAggregateCount(resolution: .fiveMinutes),
      0
    )
    XCTAssertEqual(try database.fetchLogicalCPUSamples(), [logicalSample])
    XCTAssertEqual(
      try database.logicalCPUAggregateCount(resolution: .oneMinute),
      0
    )
    XCTAssertEqual(
      try database.logicalCPUAggregateCount(resolution: .fiveMinutes),
      0
    )
    XCTAssertEqual(try database.integrityCheck(), "ok")
  }

  func testMaintenanceIsIdempotent() throws {
    let database = try makeDatabase()
    let bucketStart = Date(timeIntervalSince1970: 120_000)
    try database.insert(
      samples: [sample(at: bucketStart.addingTimeInterval(5), value: 42)]
    )
    let now = bucketStart.addingTimeInterval(600)

    _ = try database.performHistoryMaintenance(now: now)
    let firstMinute = try database.fetchAggregates(resolution: .oneMinute)
    let firstFiveMinute = try database.fetchAggregates(resolution: .fiveMinutes)
    _ = try database.performHistoryMaintenance(now: now)

    XCTAssertEqual(
      try database.fetchAggregates(resolution: .oneMinute),
      firstMinute
    )
    XCTAssertEqual(
      try database.fetchAggregates(resolution: .fiveMinutes),
      firstFiveMinute
    )
    XCTAssertEqual(try database.sampleCount(), 1)
  }

  func testRetentionPolicyMatchesFrozenRequirements() {
    XCTAssertEqual(MemoryHistoryRetentionPolicy.rawSampleRetention, 24 * 60 * 60)
    XCTAssertEqual(
      MemoryHistoryRetentionPolicy.oneMinuteRetention,
      3 * 24 * 60 * 60
    )
    XCTAssertEqual(
      MemoryHistoryRetentionPolicy.fiveMinuteRetention,
      3 * 24 * 60 * 60
    )
  }

  private func makeDatabase() throws -> MemoryWatcherDatabase {
    let directory = try makeTemporaryDirectory()
    return try MemoryWatcherDatabase(
      url: directory.appendingPathComponent("history.sqlite3")
    )
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
    }
    return directory
  }

  private func convertVersionThreeFixtureToVersionTwo(at url: URL) throws {
    try convertVersionFourFixtureToVersionThree(at: url)
    try executeFixtureSQL(
      """
      DROP TABLE memory_aggregates_1m;
      DROP TABLE memory_aggregates_5m;
      DELETE FROM schema_migrations WHERE version = 3;
      PRAGMA user_version = 2;
      """,
      at: url
    )
  }

  private func convertVersionFourFixtureToVersionThree(at url: URL) throws {
    try convertVersionFiveFixtureToVersionFour(at: url)
    try executeFixtureSQL(
      """
      DROP TABLE total_cpu_aggregates_5m;
      DROP TABLE total_cpu_aggregates_1m;
      DROP TABLE total_cpu_samples;
      DELETE FROM schema_migrations WHERE version = 4;
      PRAGMA user_version = 3;
      """,
      at: url
    )
  }

  private func convertVersionFiveFixtureToVersionFour(at url: URL) throws {
    try executeFixtureSQL(
      """
      DROP TABLE logical_cpu_aggregates_5m;
      DROP TABLE logical_cpu_aggregates_1m;
      DROP TABLE logical_cpu_sampling_gaps;
      DROP TABLE logical_cpu_samples;
      DROP TABLE logical_cpu_topologies;
      DELETE FROM schema_migrations WHERE version = 5;
      PRAGMA user_version = 4;
      """,
      at: url
    )
  }

  private func executeFixtureSQL(_ sql: String, at url: URL) throws {
    var connection: OpaquePointer?
    let openCode = sqlite3_open_v2(
      url.path,
      &connection,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard openCode == SQLITE_OK, let connection else {
      if let connection {
        sqlite3_close_v2(connection)
      }
      throw HistoryFixtureError.sqlite(code: openCode)
    }
    defer { sqlite3_close_v2(connection) }
    var errorMessage: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
    if let errorMessage {
      sqlite3_free(errorMessage)
    }
    guard code == SQLITE_OK else {
      throw HistoryFixtureError.sqlite(code: code)
    }
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

  private func totalCPUSample(
    endingAt end: Date,
    busy: UInt64,
    idle: UInt64
  ) -> TotalCPUSample {
    TotalCPUSample(
      intervalStartUTC: end.addingTimeInterval(-5),
      intervalEndUTC: end,
      intervalStartUptimeSeconds: max(0, end.timeIntervalSince1970 - 5),
      intervalEndUptimeSeconds: max(5, end.timeIntervalSince1970),
      delta: CPUCounterDelta(
        userTicks: busy,
        systemTicks: 0,
        idleTicks: idle,
        niceTicks: 0,
        busyTicks: busy,
        totalTicks: busy + idle
      ),
      quality: .measured
    )
  }

  private func unknownTotalCPUSample(
    endingAt end: Date,
    quality: CPUUtilizationQuality
  ) -> TotalCPUSample {
    TotalCPUSample(
      intervalStartUTC: nil,
      intervalEndUTC: end,
      intervalStartUptimeSeconds: nil,
      intervalEndUptimeSeconds: max(0, end.timeIntervalSince1970),
      delta: nil,
      quality: quality
    )
  }

  private func pressure(
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

  private func lifecycle(
    at date: Date,
    uptime: TimeInterval
  ) -> SystemLifecycleEvent {
    SystemLifecycleEvent(
      timestampUTC: date,
      systemUptimeSeconds: uptime,
      kind: .sleep
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

private enum ExpectedFailure: Error, Equatable {
  case stop
}

private enum HistoryFixtureError: Error {
  case sqlite(code: Int32)
}
