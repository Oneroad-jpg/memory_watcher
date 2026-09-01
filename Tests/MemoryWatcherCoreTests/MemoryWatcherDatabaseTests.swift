import Dispatch
import Foundation
import XCTest

@testable import MemoryWatcherCore

final class MemoryWatcherDatabaseTests: XCTestCase {
  func testNewDatabaseMigratesToCurrentSchemaAndPassesIntegrityCheck() throws {
    let database = try makeDatabase()

    XCTAssertEqual(
      try database.schemaVersion(),
      MemoryWatcherDatabase.currentSchemaVersion
    )
    XCTAssertEqual(try database.sampleCount(), 0)
    XCTAssertEqual(try database.pressureObservationCount(), 0)
    XCTAssertEqual(try database.samplingGapCount(), 0)
    XCTAssertEqual(try database.lifecycleEventCount(), 0)
    XCTAssertEqual(try database.totalCPUSampleCount(), 0)
    XCTAssertEqual(
      try database.totalCPUAggregateCount(resolution: .oneMinute),
      0
    )
    XCTAssertEqual(
      try database.totalCPUAggregateCount(resolution: .fiveMinutes),
      0
    )
    XCTAssertEqual(try database.integrityCheck(), "ok")
  }

  func testDatabaseRoundTripsSamplePressureAndGapRecords() throws {
    let database = try makeDatabase()
    let samples = [Self.sample(index: 0), Self.sample(index: 1)]
    let pressureObservations = MemoryPressureLevel.allCases.enumerated().map {
      index, level in
      MemoryPressureObservation(
        timestampUTC: Date(timeIntervalSince1970: 10_000 + Double(index)),
        systemUptimeSeconds: 8_000 + Double(index),
        level: level
      )
    }
    let gaps = [Self.samplingGap()]
    let lifecycleEvents = SystemLifecycleEventKind.allCases.enumerated().map {
      index, kind in
      SystemLifecycleEvent(
        timestampUTC: Date(timeIntervalSince1970: 40_000 + Double(index)),
        systemUptimeSeconds: 30_000 + Double(index),
        kind: kind
      )
    }

    try database.insert(samples: samples)
    try database.insert(pressureObservations: pressureObservations)
    try database.insert(gaps: gaps)
    try database.insert(lifecycleEvents: lifecycleEvents)

    XCTAssertEqual(try database.fetchSamples(), samples)
    XCTAssertEqual(
      try database.fetchPressureObservations(),
      pressureObservations
    )
    XCTAssertEqual(try database.fetchSamplingGaps(), gaps)
    XCTAssertEqual(try database.fetchLifecycleEvents(), lifecycleEvents)
    XCTAssertEqual(
      try database.latestSampleAnchor(),
      SystemTimelineAnchor(
        timestampUTC: samples[1].timestampUTC,
        systemUptimeSeconds: samples[1].systemUptimeSeconds
      )
    )
    XCTAssertEqual(try database.integrityCheck(), "ok")
  }

  func testDuplicateSampleRollsBackTheWholeBatch() throws {
    let database = try makeDatabase()
    let sample = Self.sample(index: 0)

    XCTAssertThrowsError(try database.insert(samples: [sample, sample]))
    XCTAssertEqual(try database.sampleCount(), 0)

    try database.insert(samples: [sample])
    XCTAssertThrowsError(try database.insert(samples: [sample]))
    XCTAssertEqual(try database.sampleCount(), 1)
    XCTAssertEqual(try database.fetchSamples(), [sample])
  }

  func testDatabaseRoundTripsMeasuredAndUnknownTotalCPUSamples() throws {
    let database = try makeDatabase()
    let samples = [
      Self.totalCPUSample(end: 10_005, uptime: 8_005, busy: 60, idle: 40),
      Self.unknownTotalCPUSample(
        end: 10_010,
        uptime: 8_010,
        quality: .wakeBoundary
      ),
    ]

    try database.insert(totalCPUSamples: samples)

    XCTAssertEqual(try database.totalCPUSampleCount(), 2)
    XCTAssertEqual(try database.fetchTotalCPUSamples(), samples)
    XCTAssertEqual(try database.integrityCheck(), "ok")
  }

  func testDuplicateTotalCPUSampleRollsBackTheWholeBatch() throws {
    let database = try makeDatabase()
    let sample = Self.totalCPUSample(
      end: 20_005,
      uptime: 18_005,
      busy: 50,
      idle: 50
    )

    XCTAssertThrowsError(
      try database.insert(totalCPUSamples: [sample, sample])
    )
    XCTAssertEqual(try database.totalCPUSampleCount(), 0)

    try database.insert(totalCPUSamples: [sample])
    XCTAssertThrowsError(try database.insert(totalCPUSamples: [sample]))
    XCTAssertEqual(try database.fetchTotalCPUSamples(), [sample])
    XCTAssertEqual(try database.integrityCheck(), "ok")
  }

  func testDuplicatePressureAndGapRecordsRollBackTheirBatches() throws {
    let database = try makeDatabase()
    let pressure = MemoryPressureObservation(
      timestampUTC: Date(timeIntervalSince1970: 25_000),
      systemUptimeSeconds: 15_000,
      level: .normal
    )
    let gap = Self.samplingGap()

    XCTAssertThrowsError(
      try database.insert(pressureObservations: [pressure, pressure])
    )
    XCTAssertThrowsError(try database.insert(gaps: [gap, gap]))

    XCTAssertEqual(try database.pressureObservationCount(), 0)
    XCTAssertEqual(try database.samplingGapCount(), 0)

    let changedPressure = MemoryPressureObservation(
      timestampUTC: pressure.timestampUTC,
      systemUptimeSeconds: pressure.systemUptimeSeconds,
      level: .warning
    )
    try database.insert(
      pressureObservations: [pressure, changedPressure]
    )
    XCTAssertEqual(
      try database.fetchPressureObservations(),
      [pressure, changedPressure]
    )
    XCTAssertEqual(try database.integrityCheck(), "ok")
  }

  func testUnrepresentableIntegerRollsBackTheWholeBatch() throws {
    let database = try makeDatabase()
    let valid = Self.sample(index: 0)
    let invalid = Self.sample(index: 1, swapUsedBytes: UInt64.max)

    XCTAssertThrowsError(try database.insert(samples: [valid, invalid])) { error in
      XCTAssertEqual(
        error as? MemoryWatcherDatabaseError,
        .invalidValue(field: "swap used")
      )
    }
    XCTAssertEqual(try database.sampleCount(), 0)
    XCTAssertEqual(try database.integrityCheck(), "ok")
  }

  func testDatabaseStoresAndReadsOneHundredThousandSamples() throws {
    let database = try makeDatabase()
    let samples = (0..<100_000).map { Self.sample(index: $0) }

    try database.insert(samples: samples)
    let readback = try database.fetchSamples()

    XCTAssertEqual(try database.sampleCount(), 100_000)
    XCTAssertEqual(readback.count, 100_000)
    XCTAssertEqual(readback.first, samples.first)
    XCTAssertEqual(readback.last, samples.last)
    XCTAssertEqual(
      zip(readback, samples).first(where: { $0 != $1 })?.0,
      nil
    )
    XCTAssertEqual(try database.integrityCheck(), "ok")
  }

  func testDatabaseHistorySurvivesConnectionReopen() throws {
    let directory = try makeTemporaryDirectory()
    let databaseURL = directory.appendingPathComponent("history.sqlite3")
    var database: MemoryWatcherDatabase? = try MemoryWatcherDatabase(
      url: databaseURL
    )
    try database?.insert(samples: [Self.sample(index: 42)])
    try database?.insert(
      pressureObservations: [
        MemoryPressureObservation(
          timestampUTC: Date(timeIntervalSince1970: 20_000),
          systemUptimeSeconds: 10_000,
          level: .warning
        )
      ]
    )
    database = nil

    let reopened = try MemoryWatcherDatabase(url: databaseURL)

    XCTAssertEqual(try reopened.fetchSamples(), [Self.sample(index: 42)])
    XCTAssertEqual(try reopened.pressureObservationCount(), 1)
    XCTAssertEqual(try reopened.integrityCheck(), "ok")
  }

  func testSecondConnectionCanReadCommittedHistory() throws {
    let directory = try makeTemporaryDirectory()
    let databaseURL = directory.appendingPathComponent("concurrent.sqlite3")
    let writer = try MemoryWatcherDatabase(url: databaseURL)
    try writer.insert(samples: [Self.sample(index: 7)])

    let reader = try MemoryWatcherDatabase(url: databaseURL)

    XCTAssertEqual(try reader.fetchSamples(), [Self.sample(index: 7)])
    XCTAssertEqual(try reader.integrityCheck(), "ok")
  }

  func testConcurrentWritesAreSerializedWithoutLoss() throws {
    let database = try makeDatabase()
    let errors = DatabaseTestErrorCollector()

    DispatchQueue.concurrentPerform(iterations: 100) { index in
      do {
        try database.insert(samples: [Self.sample(index: index)])
      } catch {
        errors.append(error)
      }
    }

    XCTAssertEqual(errors.count, 0)
    XCTAssertEqual(try database.sampleCount(), 100)
    XCTAssertEqual(try database.fetchSamples().count, 100)
    XCTAssertEqual(try database.integrityCheck(), "ok")
  }

  private func makeDatabase() throws -> MemoryWatcherDatabase {
    let directory = try makeTemporaryDirectory()
    return try MemoryWatcherDatabase(
      url: directory.appendingPathComponent("memory-watcher.sqlite3")
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

  private static func sample(
    index: Int,
    swapUsedBytes: UInt64? = nil
  ) -> MemorySample {
    MemorySample(
      timestampUTC: Date(
        timeIntervalSince1970: 1_000 + Double(index * 5)
      ),
      systemUptimeSeconds: 500 + Double(index * 5),
      physicalMemoryBytes: 220 * 4_096,
      estimatedMemoryUsedBytes: 130 * 4_096,
      wiredBytes: 20 * 4_096,
      compressedBytes: 5 * 4_096,
      estimatedCachedFilesBytes: 40 * 4_096,
      swapUsedBytes: swapUsedBytes ?? UInt64(index % 100) * 4_096,
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

  private static func samplingGap() -> MemorySamplingGap {
    MemorySamplingGap(
      timestampUTC: Date(timeIntervalSince1970: 30_000),
      systemUptimeSeconds: 20_000,
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

  private static func totalCPUSample(
    end: TimeInterval,
    uptime: TimeInterval,
    busy: UInt64,
    idle: UInt64
  ) -> TotalCPUSample {
    TotalCPUSample(
      intervalStartUTC: Date(timeIntervalSince1970: end - 5),
      intervalEndUTC: Date(timeIntervalSince1970: end),
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

  private static func unknownTotalCPUSample(
    end: TimeInterval,
    uptime: TimeInterval,
    quality: CPUUtilizationQuality
  ) -> TotalCPUSample {
    TotalCPUSample(
      intervalStartUTC: nil,
      intervalEndUTC: Date(timeIntervalSince1970: end),
      intervalStartUptimeSeconds: nil,
      intervalEndUptimeSeconds: uptime,
      delta: nil,
      quality: quality
    )
  }
}

private final class DatabaseTestErrorCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var errors: [Error] = []

  var count: Int {
    lock.withLock { errors.count }
  }

  func append(_ error: Error) {
    lock.withLock {
      errors.append(error)
    }
  }
}
