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

  func testEachSamplingSlotPersistsMemoryAndTotalCPUWithoutAnotherTimer() throws {
    let database = try makeDatabase()
    let memorySequence = MonitoringOutcomeSequence([
      .sample(Self.sample(timestamp: 10_000, uptime: 8_000)),
      .sample(Self.sample(timestamp: 10_005, uptime: 8_005)),
    ])
    let cpuSequence = TotalCPUSampleSequence([
      Self.unknownCPUSample(timestamp: 10_000, uptime: 8_000),
      Self.measuredCPUSample(timestamp: 10_005, uptime: 8_005),
    ])
    let engine = makeEngine(
      database: database,
      sequence: memorySequence,
      totalCPUSequence: cpuSequence
    )
    defer { engine.stop() }

    try engine.start()
    XCTAssertTrue(engine.recordSampleNow())

    XCTAssertEqual(try database.sampleCount(), 2)
    XCTAssertEqual(try database.totalCPUSampleCount(), 2)
    XCTAssertEqual(
      try database.fetchTotalCPUSamples().map(\.quality),
      [.firstDeltaUnknown, .measured]
    )
  }

  func testMemoryFailureDoesNotPreventIndependentTotalCPUStorage() throws {
    let database = try makeDatabase()
    let cpuSample = Self.unknownCPUSample(timestamp: 20_000, uptime: 18_000)
    let engine = makeEngine(
      database: database,
      sequence: MonitoringOutcomeSequence([]),
      totalCPUSequence: TotalCPUSampleSequence([cpuSample])
    )
    defer { engine.stop() }

    try engine.start()

    XCTAssertEqual(try database.sampleCount(), 0)
    XCTAssertEqual(try database.fetchTotalCPUSamples(), [cpuSample])
  }

  func testWakeResetsCPUChainAndStoresExplicitUnknownBoundary() throws {
    let database = try makeDatabase()
    let resetRecorder = CPUResetRecorder()
    let engine = makeEngine(
      database: database,
      sequence: MonitoringOutcomeSequence([
        .sample(Self.sample(timestamp: 30_000, uptime: 28_000)),
        .sample(Self.sample(timestamp: 30_065, uptime: 28_065)),
      ]),
      totalCPUSequence: TotalCPUSampleSequence([
        Self.unknownCPUSample(timestamp: 30_000, uptime: 28_000),
        Self.unknownCPUSample(
          timestamp: 30_065,
          uptime: 28_065,
          quality: .wakeBoundary
        ),
      ]),
      resetRecorder: resetRecorder
    )
    defer { engine.stop() }

    try engine.start()
    engine.prepareForSleep()
    engine.resumeAfterWake()

    XCTAssertEqual(resetRecorder.values.count, 3)
    XCTAssertNil(resetRecorder.values[0])
    XCTAssertEqual(resetRecorder.values[1], .sleep)
    XCTAssertEqual(resetRecorder.values[2], .wake)
    XCTAssertEqual(
      try database.fetchTotalCPUSamples().map(\.quality),
      [.firstDeltaUnknown, .wakeBoundary]
    )
  }

  func testEachSamplingSlotPersistsLogicalCPUBatchOrGapWithoutAnotherTimer()
    throws
  {
    let database = try makeDatabase()
    let topology = Self.logicalTopology(count: 8)
    let first = Self.logicalCPUBatch(
      topology: topology,
      timestamp: 40_000,
      uptime: 38_000,
      quality: .firstDeltaUnknown
    )
    let gap = LogicalCPUSamplingGap(
      timestampUTC: Date(timeIntervalSince1970: 40_005),
      systemUptimeSeconds: 38_005,
      previousTopology: topology
    )
    let engine = makeEngine(
      database: database,
      sequence: MonitoringOutcomeSequence([
        .sample(Self.sample(timestamp: 40_000, uptime: 38_000)),
        .sample(Self.sample(timestamp: 40_005, uptime: 38_005)),
      ]),
      logicalCPUSequence: LogicalCPUSampleSequence([
        .samples(first),
        .gap(gap),
      ])
    )
    defer { engine.stop() }

    try engine.start()
    XCTAssertTrue(engine.recordSampleNow())

    XCTAssertEqual(try database.logicalCPUSampleCount(), 8)
    XCTAssertEqual(try database.fetchLogicalCPUSamples(), first)
    XCTAssertEqual(try database.fetchLogicalCPUSamplingGaps(), [gap])
  }

  func testLogicalCPUResetFollowsLaunchSleepAndWakeBoundaries() throws {
    let database = try makeDatabase()
    let resetRecorder = CPUResetRecorder()
    let topology = Self.logicalTopology(count: 1)
    let engine = makeEngine(
      database: database,
      sequence: MonitoringOutcomeSequence([
        .sample(Self.sample(timestamp: 50_000, uptime: 48_000)),
        .sample(Self.sample(timestamp: 50_065, uptime: 48_065)),
      ]),
      logicalCPUSequence: LogicalCPUSampleSequence([
        .samples(
          Self.logicalCPUBatch(
            topology: topology,
            timestamp: 50_000,
            uptime: 48_000,
            quality: .firstDeltaUnknown
          )
        ),
        .samples(
          Self.logicalCPUBatch(
            topology: topology,
            timestamp: 50_065,
            uptime: 48_065,
            quality: .wakeBoundary
          )
        ),
      ]),
      logicalResetRecorder: resetRecorder
    )
    defer { engine.stop() }

    try engine.start()
    engine.prepareForSleep()
    engine.resumeAfterWake()

    XCTAssertEqual(resetRecorder.values.count, 3)
    XCTAssertNil(resetRecorder.values[0])
    XCTAssertEqual(resetRecorder.values[1], .sleep)
    XCTAssertEqual(resetRecorder.values[2], .wake)
    XCTAssertEqual(
      try database.fetchLogicalCPUSamples().map(\.quality),
      [.firstDeltaUnknown, .wakeBoundary]
    )
  }

  private func makeEngine(
    database: MemoryWatcherDatabase,
    sequence: MonitoringOutcomeSequence,
    clock: TestMonitoringClock = TestMonitoringClock(
      timestamp: 2_000,
      uptime: 1_000
    ),
    totalCPUSequence: TotalCPUSampleSequence? = nil,
    resetRecorder: CPUResetRecorder? = nil,
    logicalCPUSequence: LogicalCPUSampleSequence? = nil,
    logicalResetRecorder: CPUResetRecorder? = nil
  ) -> MemoryMonitoringEngine {
    let totalCPUProvider: (@Sendable () -> TotalCPUSample)?
    if let totalCPUSequence {
      totalCPUProvider = { totalCPUSequence.next() }
    } else {
      totalCPUProvider = nil
    }
    let resetTotalCPUProvider: (@Sendable (CPUIntervalContinuity?) -> Void)?
    if let resetRecorder {
      resetTotalCPUProvider = { continuity in
        resetRecorder.append(continuity)
      }
    } else {
      resetTotalCPUProvider = nil
    }
    let logicalCPUProvider: (@Sendable () -> LogicalCPUSamplingOutcome)?
    if let logicalCPUSequence {
      logicalCPUProvider = { logicalCPUSequence.next() }
    } else {
      logicalCPUProvider = nil
    }
    let resetLogicalCPUProvider: (@Sendable (CPUIntervalContinuity?) -> Void)?
    if let logicalResetRecorder {
      resetLogicalCPUProvider = { continuity in
        logicalResetRecorder.append(continuity)
      }
    } else {
      resetLogicalCPUProvider = nil
    }
    return MemoryMonitoringEngine(
      database: database,
      sampleProvider: { try sequence.next() },
      timestampProvider: { clock.timestamp },
      uptimeProvider: { clock.uptime },
      sampleInterval: 3_600,
      totalCPUSampleProvider: totalCPUProvider,
      resetTotalCPUSampler: resetTotalCPUProvider,
      logicalCPUSampleProvider: logicalCPUProvider,
      resetLogicalCPUSampler: resetLogicalCPUProvider
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

  private static func unknownCPUSample(
    timestamp: TimeInterval,
    uptime: TimeInterval,
    quality: CPUUtilizationQuality = .firstDeltaUnknown
  ) -> TotalCPUSample {
    TotalCPUSample(
      intervalStartUTC: nil,
      intervalEndUTC: Date(timeIntervalSince1970: timestamp),
      intervalStartUptimeSeconds: nil,
      intervalEndUptimeSeconds: uptime,
      delta: nil,
      quality: quality
    )
  }

  private static func measuredCPUSample(
    timestamp: TimeInterval,
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

  private static func logicalTopology(count: Int) -> LogicalCPUTopology {
    LogicalCPUTopology(
      epochKey: "engine-logical-\(count)",
      bootSessionStartUTC: Date(timeIntervalSince1970: 100),
      logicalCPUCount: count
    )
  }

  private static func logicalCPUBatch(
    topology: LogicalCPUTopology,
    timestamp: TimeInterval,
    uptime: TimeInterval,
    quality: CPUUtilizationQuality
  ) -> [LogicalCPUSample] {
    (0..<topology.logicalCPUCount).map { cpuIndex in
      LogicalCPUSample(
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

private final class TotalCPUSampleSequence: @unchecked Sendable {
  private let lock = NSLock()
  private let samples: [TotalCPUSample]
  private var index = 0

  init(_ samples: [TotalCPUSample]) {
    self.samples = samples
  }

  func next() -> TotalCPUSample {
    lock.withLock {
      precondition(index < samples.count)
      defer { index += 1 }
      return samples[index]
    }
  }
}

private final class LogicalCPUSampleSequence: @unchecked Sendable {
  private let lock = NSLock()
  private let outcomes: [LogicalCPUSamplingOutcome]
  private var index = 0

  init(_ outcomes: [LogicalCPUSamplingOutcome]) {
    self.outcomes = outcomes
  }

  func next() -> LogicalCPUSamplingOutcome {
    lock.withLock {
      precondition(index < outcomes.count)
      defer { index += 1 }
      return outcomes[index]
    }
  }
}

private final class CPUResetRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [CPUIntervalContinuity?] = []

  var values: [CPUIntervalContinuity?] {
    lock.withLock { storedValues }
  }

  func append(_ value: CPUIntervalContinuity?) {
    lock.withLock {
      storedValues.append(value)
    }
  }
}
