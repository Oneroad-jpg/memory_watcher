import Foundation
import XCTest

@testable import MemoryWatcherCore

final class MemoryMonitoringEngineTests: XCTestCase {
  func testStartPersistsLaunchPressureAndImmediateSample() throws {
    let database = try makeDatabase()
    let sequence = MonitoringOutcomeSequence([
      .sample(Self.sample(timestamp: 1_000, uptime: 500))
    ])
    let engine = makeEngine(database: database, sequence: sequence)
    defer { engine.stop() }

    try engine.start()

    XCTAssertEqual(engine.state, .running)
    XCTAssertEqual(try database.sampleCount(), 1)
    XCTAssertGreaterThanOrEqual(try database.pressureObservationCount(), 1)
    XCTAssertEqual(
      try database.fetchLifecycleEvents().map(\.kind),
      [.launch]
    )
  }

  func testSleepStopsSamplingAndWakeResumesImmediately() throws {
    let database = try makeDatabase()
    let sequence = MonitoringOutcomeSequence([
      .sample(Self.sample(timestamp: 1_000, uptime: 500)),
      .sample(Self.sample(timestamp: 1_005, uptime: 505)),
    ])
    let clock = TestMonitoringClock(timestamp: 2_000, uptime: 1_000)
    let engine = makeEngine(
      database: database,
      sequence: sequence,
      clock: clock
    )
    defer { engine.stop() }
    try engine.start()

    engine.prepareForSleep()
    let countAtSleep = try database.sampleCount()
    XCTAssertEqual(engine.state, .sleeping)
    XCTAssertFalse(engine.recordSampleNow())
    XCTAssertEqual(try database.sampleCount(), countAtSleep)

    clock.advance(seconds: 60)
    engine.resumeAfterWake()

    XCTAssertEqual(engine.state, .running)
    XCTAssertEqual(try database.sampleCount(), countAtSleep + 1)
    XCTAssertEqual(
      try database.fetchLifecycleEvents().map(\.kind),
      [.launch, .sleep, .wake]
    )
  }

  func testClockChangeBetweenSamplesIsPersisted() throws {
    let database = try makeDatabase()
    let sequence = MonitoringOutcomeSequence([
      .sample(Self.sample(timestamp: 1_000, uptime: 500)),
      .sample(Self.sample(timestamp: 1_065, uptime: 505)),
    ])
    let engine = makeEngine(database: database, sequence: sequence)
    defer { engine.stop() }
    try engine.start()

    XCTAssertTrue(engine.recordSampleNow())

    XCTAssertEqual(try database.sampleCount(), 2)
    XCTAssertEqual(
      try database.fetchLifecycleEvents().map(\.kind),
      [.launch, .clockChanged]
    )
  }

  func testLowerLaunchUptimePersistsRebootBeforeLaunch() throws {
    let database = try makeDatabase()
    try database.insert(
      samples: [Self.sample(timestamp: 1_000, uptime: 50_000)]
    )
    let sequence = MonitoringOutcomeSequence([
      .sample(Self.sample(timestamp: 2_000, uptime: 100))
    ])
    let clock = TestMonitoringClock(timestamp: 2_000, uptime: 100)
    let engine = makeEngine(
      database: database,
      sequence: sequence,
      clock: clock
    )
    defer { engine.stop() }

    try engine.start()

    XCTAssertEqual(
      try database.fetchLifecycleEvents().map(\.kind),
      [.rebootDetected, .launch]
    )
  }

  func testStartAutomaticallyMaintainsExpiredHistory() throws {
    let database = try makeDatabase()
    let day: TimeInterval = 24 * 60 * 60
    let now = 40 * day
    try database.insert(
      samples: [Self.sample(timestamp: now - 2 * day, uptime: 100)]
    )
    let sequence = MonitoringOutcomeSequence([
      .sample(Self.sample(timestamp: now, uptime: 1_000))
    ])
    let clock = TestMonitoringClock(timestamp: now, uptime: 1_000)
    let engine = makeEngine(
      database: database,
      sequence: sequence,
      clock: clock
    )
    defer { engine.stop() }

    try engine.start()

    XCTAssertEqual(try database.sampleCount(), 1)
    XCTAssertEqual(try database.aggregateCount(resolution: .oneMinute), 1)
    XCTAssertEqual(try database.aggregateCount(resolution: .fiveMinutes), 1)
  }

  func testAutomaticMaintenanceWaitsOneHourBetweenSuccessfulSamples() throws {
    let database = try makeDatabase()
    let day: TimeInterval = 24 * 60 * 60
    let now = 40 * day
    let expiredTimestamp = now - 2 * day
    let sequence = MonitoringOutcomeSequence([
      .sample(Self.sample(timestamp: now, uptime: 1_000)),
      .sample(Self.sample(timestamp: now + 5, uptime: 1_005)),
      .sample(Self.sample(timestamp: now + 3_605, uptime: 4_605)),
    ])
    let clock = TestMonitoringClock(timestamp: now, uptime: 1_000)
    let engine = makeEngine(
      database: database,
      sequence: sequence,
      clock: clock
    )
    defer { engine.stop() }
    try engine.start()
    try database.insert(
      samples: [Self.sample(timestamp: expiredTimestamp, uptime: 100)]
    )

    XCTAssertTrue(engine.recordSampleNow())
    XCTAssertTrue(
      try database.fetchSamples().contains {
        $0.timestampUTC == Date(timeIntervalSince1970: expiredTimestamp)
      }
    )

    XCTAssertTrue(engine.recordSampleNow())
    XCTAssertFalse(
      try database.fetchSamples().contains {
        $0.timestampUTC == Date(timeIntervalSince1970: expiredTimestamp)
      }
    )
  }

  func testDuplicateStartIsRejected() throws {
    let database = try makeDatabase()
    let sequence = MonitoringOutcomeSequence([
      .sample(Self.sample(timestamp: 1_000, uptime: 500))
    ])
    let engine = makeEngine(database: database, sequence: sequence)
    defer { engine.stop() }
    try engine.start()

    XCTAssertThrowsError(try engine.start()) { error in
      XCTAssertEqual(
        error as? MemoryMonitoringEngineError,
        .alreadyStarted
      )
    }
  }

  private func makeEngine(
    database: MemoryWatcherDatabase,
    sequence: MonitoringOutcomeSequence,
    clock: TestMonitoringClock = TestMonitoringClock(
      timestamp: 2_000,
      uptime: 1_000
    )
  ) -> MemoryMonitoringEngine {
    MemoryMonitoringEngine(
      database: database,
      sampleProvider: { try sequence.next() },
      timestampProvider: { clock.timestamp },
      uptimeProvider: { clock.uptime },
      sampleInterval: 3_600
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
      url: directory.appendingPathComponent("monitoring.sqlite3")
    )
  }

  private static func sample(
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

private final class MonitoringOutcomeSequence: @unchecked Sendable {
  private let lock = NSLock()
  private let outcomes: [MemorySamplingOutcome]
  private var index = 0

  init(_ outcomes: [MemorySamplingOutcome]) {
    self.outcomes = outcomes
  }

  func next() throws -> MemorySamplingOutcome {
    try lock.withLock {
      guard index < outcomes.count else {
        throw MemorySamplingError.invalidSample
      }
      defer { index += 1 }
      return outcomes[index]
    }
  }
}

private final class TestMonitoringClock: @unchecked Sendable {
  private let lock = NSLock()
  private var storedTimestamp: TimeInterval
  private var storedUptime: TimeInterval

  init(timestamp: TimeInterval, uptime: TimeInterval) {
    storedTimestamp = timestamp
    storedUptime = uptime
  }

  var timestamp: Date {
    lock.withLock {
      Date(timeIntervalSince1970: storedTimestamp)
    }
  }

  var uptime: TimeInterval {
    lock.withLock { storedUptime }
  }

  func advance(seconds: TimeInterval) {
    lock.withLock {
      storedTimestamp += seconds
      storedUptime += seconds
    }
  }
}
