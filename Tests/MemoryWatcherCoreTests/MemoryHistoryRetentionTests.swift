import CSQLite
import Foundation
import XCTest

@testable import MemoryWatcherCore

final class MemoryHistoryRetentionTests: XCTestCase {
  func testVersionTwoDatabaseMigratesWithoutLosingRawSamples() throws {
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
    XCTAssertEqual(try migrated.schemaVersion(), 3)
    XCTAssertEqual(try migrated.fetchSamples(), [preservedSample])
    XCTAssertEqual(try migrated.aggregateCount(resolution: .oneMinute), 0)
    XCTAssertEqual(try migrated.aggregateCount(resolution: .fiveMinutes), 0)
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

  func testThirtyOneDayDataHonorsEveryRetentionBoundary() throws {
    let database = try makeDatabase()
    let day: TimeInterval = 24 * 60 * 60
    let now = Date(timeIntervalSince1970: 40 * day)
    let samples = (0...31).map { ageInDays in
      sample(
        at: now.addingTimeInterval(-Double(ageInDays) * day),
        value: UInt64(ageInDays)
      )
    }
    try database.insert(samples: samples)

    let expiredDate = now.addingTimeInterval(-31 * day)
    let boundaryDate = now.addingTimeInterval(-30 * day)
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
    XCTAssertEqual(try database.aggregateCount(resolution: .oneMinute), 7)
    XCTAssertEqual(try database.aggregateCount(resolution: .fiveMinutes), 30)
    XCTAssertEqual(
      try database.fetchAggregates(resolution: .oneMinute).first?.bucketStartUTC,
      now.addingTimeInterval(-7 * day)
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
      7 * 24 * 60 * 60
    )
    XCTAssertEqual(
      MemoryHistoryRetentionPolicy.fiveMinuteRetention,
      30 * 24 * 60 * 60
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
    let sql = """
      DROP TABLE memory_aggregates_1m;
      DROP TABLE memory_aggregates_5m;
      DELETE FROM schema_migrations WHERE version = 3;
      PRAGMA user_version = 2;
      """
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
