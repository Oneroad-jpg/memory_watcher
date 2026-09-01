import CSQLite
import Foundation
import XCTest

@testable import MemoryWatcherCore

final class LogicalCPUStorageTests: XCTestCase {
  func testLogicalCPUSamplesAndUnavailableGapRoundTrip() throws {
    let database = try makeDatabase()
    let topology = Self.topology(epoch: "boot-a", count: 2)
    let unknown = Self.batch(
      topology: topology,
      endingAt: 1_000,
      uptime: 500,
      quality: .firstDeltaUnknown
    )
    let measured = Self.batch(
      topology: topology,
      endingAt: 1_005,
      uptime: 505,
      busy: 30,
      idle: 70
    )
    let gap = LogicalCPUSamplingGap(
      timestampUTC: Date(timeIntervalSince1970: 1_010),
      systemUptimeSeconds: 510,
      previousTopology: topology
    )

    try database.insert(logicalCPUSamples: unknown)
    try database.insert(logicalCPUSamples: measured)
    try database.insert(logicalCPUGaps: [gap])

    XCTAssertEqual(try database.fetchLogicalCPUSamples(), unknown + measured)
    XCTAssertEqual(try database.fetchLogicalCPUSamplingGaps(), [gap])
    XCTAssertEqual(try database.logicalCPUTopologyCount(), 1)
    XCTAssertEqual(try database.logicalCPUSampleCount(), 4)
    XCTAssertEqual(try database.logicalCPUSamplingGapCount(), 1)
    XCTAssertEqual(try database.integrityCheck(), "ok")
  }

  func testDuplicateBatchRollsBackWithoutPartialRows() throws {
    let database = try makeDatabase()
    let batch = Self.batch(
      topology: Self.topology(epoch: "boot-b", count: 8),
      endingAt: 2_000,
      uptime: 1_000,
      quality: .firstDeltaUnknown
    )

    try database.insert(logicalCPUSamples: batch)
    XCTAssertThrowsError(try database.insert(logicalCPUSamples: batch))

    XCTAssertEqual(try database.fetchLogicalCPUSamples(), batch)
    XCTAssertEqual(try database.logicalCPUSampleCount(), 8)
    XCTAssertEqual(try database.integrityCheck(), "ok")
  }

  func testSameEpochCannotBeReusedForDifferentTopology() throws {
    let database = try makeDatabase()
    try database.insert(
      logicalCPUSamples: Self.batch(
        topology: Self.topology(epoch: "fixed-epoch", count: 1),
        endingAt: 3_000,
        uptime: 2_000,
        quality: .firstDeltaUnknown
      )
    )

    XCTAssertThrowsError(
      try database.insert(
        logicalCPUSamples: Self.batch(
          topology: Self.topology(epoch: "fixed-epoch", count: 8),
          endingAt: 3_005,
          uptime: 2_005,
          quality: .firstDeltaUnknown
        )
      )
    )
    XCTAssertEqual(try database.logicalCPUSampleCount(), 1)
  }

  func testAggregationSeparatesTopologyAndCPUAndSumsTicks() throws {
    let database = try makeDatabase()
    let twoCPU = Self.topology(epoch: "boot-c-2", count: 2)
    let oneCPU = Self.topology(epoch: "boot-c-1", count: 1)
    try database.insert(
      logicalCPUSamples: Self.batch(
        topology: twoCPU,
        endingAt: 120_005,
        uptime: 10_005,
        busy: 90,
        idle: 10
      )
    )
    try database.insert(
      logicalCPUSamples: Self.batch(
        topology: twoCPU,
        endingAt: 120_010,
        uptime: 10_010,
        busy: 10,
        idle: 190
      )
    )
    try database.insert(
      logicalCPUSamples: Self.batch(
        topology: oneCPU,
        endingAt: 120_015,
        uptime: 10_015,
        busy: 50,
        idle: 50
      )
    )

    _ = try database.performHistoryMaintenance(
      now: Date(timeIntervalSince1970: 120_600)
    )

    let oneMinute = try database.fetchLogicalCPUAggregates(
      resolution: .oneMinute
    )
    let fiveMinutes = try database.fetchLogicalCPUAggregates(
      resolution: .fiveMinutes
    )
    XCTAssertEqual(oneMinute.count, 3)
    XCTAssertEqual(fiveMinutes.count, 3)
    let firstCPU = try XCTUnwrap(
      oneMinute.first {
        $0.topology == twoCPU && $0.cpuIndex == 0
      }
    )
    XCTAssertEqual(firstCPU.sampleCount, 2)
    XCTAssertEqual(firstCPU.summedBusyTicks, 100)
    XCTAssertEqual(firstCPU.summedIdleTicks, 200)
    XCTAssertEqual(firstCPU.summedTotalTicks, 300)
    XCTAssertEqual(firstCPU.utilizationPercent, 100.0 / 3.0, accuracy: 0.000_001)
  }

  func testVersionFourMigratesToFiveWithoutLosingMemoryOrTotalCPU() throws {
    let directory = try makeTemporaryDirectory()
    let url = directory.appendingPathComponent("migration-v4.sqlite3")
    let memory = Self.memorySample(timestamp: 180_005, uptime: 20_005)
    let totalCPU = Self.totalCPUSample(endingAt: 180_005, uptime: 20_005)
    var database: MemoryWatcherDatabase? = try MemoryWatcherDatabase(url: url)
    try database?.insert(samples: [memory])
    try database?.insert(totalCPUSamples: [totalCPU])
    database = nil
    try convertVersionFiveFixtureToVersionFour(at: url)

    let migrated = try MemoryWatcherDatabase(url: url)
    XCTAssertEqual(try migrated.schemaVersion(), 5)
    XCTAssertEqual(try migrated.fetchSamples(), [memory])
    XCTAssertEqual(try migrated.fetchTotalCPUSamples(), [totalCPU])
    XCTAssertEqual(try migrated.logicalCPUSampleCount(), 0)
    XCTAssertEqual(try migrated.integrityCheck(), "ok")
  }

  func testThirtyTwoCPUCapacityProjectionFitsTheFrozenBudget() throws {
    let directory = try makeTemporaryDirectory()
    let url = directory.appendingPathComponent("capacity.sqlite3")
    var database: MemoryWatcherDatabase? = try MemoryWatcherDatabase(url: url)
    let topology = Self.topology(epoch: "capacity-32", count: 32)
    let slotCount = 60 * 60 / 5
    for slot in 0..<slotCount {
      try database?.insert(
        logicalCPUSamples: Self.batch(
          topology: topology,
          endingAt: 300_000 + TimeInterval(slot * 5),
          uptime: 100_000 + TimeInterval(slot * 5),
          busy: 30,
          idle: 70
        )
      )
    }
    XCTAssertEqual(
      try database?.logicalCPUSampleCount(),
      slotCount * topology.logicalCPUCount
    )
    XCTAssertEqual(try database?.integrityCheck(), "ok")
    database = nil

    let allocatedBytes = try allocatedSize(for: url)
    let observedBytesPerRow =
      (allocatedBytes + slotCount * topology.logicalCPUCount - 1)
      / (slotCount * topology.logicalCPUCount)
    XCTAssertLessThanOrEqual(
      observedBytesPerRow,
      LogicalCPUStorageCapacity.maximumObservedBytesPerLogicalCPURow
    )
    XCTAssertLessThanOrEqual(
      LogicalCPUStorageCapacity.projectedMaximumBytes,
      LogicalCPUStorageCapacity.maximumBytes
    )
  }

  private func makeDatabase() throws -> MemoryWatcherDatabase {
    let directory = try makeTemporaryDirectory()
    return try MemoryWatcherDatabase(
      url: directory.appendingPathComponent("logical-cpu.sqlite3")
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

  private func allocatedSize(for url: URL) throws -> Int {
    let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey]
    let values = try url.resourceValues(forKeys: keys)
    return values.totalFileAllocatedSize ?? values.fileSize ?? 0
  }

  private func convertVersionFiveFixtureToVersionFour(at url: URL) throws {
    var connection: OpaquePointer?
    let openCode = sqlite3_open_v2(
      url.path,
      &connection,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard openCode == SQLITE_OK, let connection else {
      throw LogicalCPUStorageTestError.sqlite(openCode)
    }
    defer { sqlite3_close_v2(connection) }
    let sql = """
      DROP TABLE logical_cpu_aggregates_5m;
      DROP TABLE logical_cpu_aggregates_1m;
      DROP TABLE logical_cpu_sampling_gaps;
      DROP TABLE logical_cpu_samples;
      DROP TABLE logical_cpu_topologies;
      DELETE FROM schema_migrations WHERE version = 5;
      PRAGMA user_version = 4;
      """
    var errorMessage: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
    if let errorMessage { sqlite3_free(errorMessage) }
    guard code == SQLITE_OK else {
      throw LogicalCPUStorageTestError.sqlite(code)
    }
  }

  private static func topology(
    epoch: String,
    count: Int
  ) -> LogicalCPUTopology {
    LogicalCPUTopology(
      epochKey: epoch,
      bootSessionStartUTC: Date(timeIntervalSince1970: 100),
      logicalCPUCount: count
    )
  }

  private static func batch(
    topology: LogicalCPUTopology,
    endingAt timestamp: TimeInterval,
    uptime: TimeInterval,
    quality: CPUUtilizationQuality? = nil,
    busy: UInt64 = 0,
    idle: UInt64 = 0
  ) -> [LogicalCPUSample] {
    (0..<topology.logicalCPUCount).map { cpuIndex in
      if let quality {
        return LogicalCPUSample(
          topology: topology,
          cpuIndex: cpuIndex,
          intervalStartUTC: nil,
          intervalEndUTC: Date(timeIntervalSince1970: timestamp),
          intervalStartUptimeSeconds: nil,
          intervalEndUptimeSeconds: uptime,
          delta: nil,
          quality: quality
        )
      }
      return LogicalCPUSample(
        topology: topology,
        cpuIndex: cpuIndex,
        intervalStartUTC: Date(timeIntervalSince1970: timestamp - 5),
        intervalEndUTC: Date(timeIntervalSince1970: timestamp),
        intervalStartUptimeSeconds: uptime - 5,
        intervalEndUptimeSeconds: uptime,
        delta: CPUCounterDelta(
          userTicks: busy / 2,
          systemTicks: busy - busy / 2,
          idleTicks: idle,
          niceTicks: 0,
          busyTicks: busy,
          totalTicks: busy + idle
        ),
        quality: .measured
      )
    }
  }

  private static func totalCPUSample(
    endingAt timestamp: TimeInterval,
    uptime: TimeInterval
  ) -> TotalCPUSample {
    TotalCPUSample(
      intervalStartUTC: Date(timeIntervalSince1970: timestamp - 5),
      intervalEndUTC: Date(timeIntervalSince1970: timestamp),
      intervalStartUptimeSeconds: uptime - 5,
      intervalEndUptimeSeconds: uptime,
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
  }

  private static func memorySample(
    timestamp: TimeInterval,
    uptime: TimeInterval
  ) -> MemorySample {
    MemorySample(
      timestampUTC: Date(timeIntervalSince1970: timestamp),
      systemUptimeSeconds: uptime,
      physicalMemoryBytes: 220 * 4_096,
      estimatedMemoryUsedBytes: 130 * 4_096,
      wiredBytes: 20 * 4_096,
      compressedBytes: 5 * 4_096,
      estimatedCachedFilesBytes: 40 * 4_096,
      swapUsedBytes: 8 * 4_096,
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
}

private enum LogicalCPUStorageTestError: Error {
  case sqlite(Int32)
}
