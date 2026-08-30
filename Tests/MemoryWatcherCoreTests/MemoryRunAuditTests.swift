import Foundation
import XCTest

@testable import MemoryWatcherCore

final class MemoryRunAuditTests: XCTestCase {
  func testCompleteRunWithSleepAndComparisonsPassesAfterDatabaseReopen() throws {
    let fixture = try makeFixture()
    let database = try MemoryWatcherDatabase(url: fixture.databaseURL)
    try database.insert(samples: [sample(at: fixture.checkpointTime)])
    let checkpoint = try MemoryRunAuditor(database: database).makeCheckpoint(
      now: fixture.checkpointTime
    )
    let sleepStart = checkpoint.auditStartUTC.addingTimeInterval(12 * 60 * 60)
    let sleepEnd = sleepStart.addingTimeInterval(10 * 60)
    try database.insert(
      lifecycleEvents: [
        lifecycle(at: sleepStart, kind: .sleep, uptime: 50_000),
        lifecycle(at: sleepEnd, kind: .wake, uptime: 50_600),
      ]
    )
    try database.insert(
      samples: samples(
        from: checkpoint.auditStartUTC,
        to: checkpoint.requiredEndUTC,
        excluding: sleepStart..<sleepEnd
      )
    )
    _ = try database.performHistoryMaintenance(now: checkpoint.requiredEndUTC)

    let reopened = try MemoryWatcherDatabase(url: fixture.databaseURL)
    let report = try MemoryRunAuditor(database: reopened).makeReport(
      checkpoint: checkpoint,
      now: checkpoint.requiredEndUTC,
      activityMonitorComparisons: comparisons(for: checkpoint)
    )

    XCTAssertEqual(report.disposition, .passed)
    XCTAssertEqual(report.unexplainedMissingSlotCount, 0)
    XCTAssertEqual(report.samplesInsideSleepCount, 0)
    XCTAssertEqual(report.completedSleepIntervalCount, 1)
    XCTAssertTrue(report.historyMarkerReadable)
    XCTAssertEqual(report.integrityCheck, "ok")
  }

  func testMissingSamplesAndSampleInsideSleepCauseHold() throws {
    let fixture = try makeFixture()
    let database = try MemoryWatcherDatabase(url: fixture.databaseURL)
    try database.insert(samples: [sample(at: fixture.checkpointTime)])
    let checkpoint = try MemoryRunAuditor(database: database).makeCheckpoint(
      now: fixture.checkpointTime
    )
    let sleepStart = checkpoint.auditStartUTC.addingTimeInterval(12 * 60 * 60)
    let sleepEnd = sleepStart.addingTimeInterval(10 * 60)
    try database.insert(
      lifecycleEvents: [
        lifecycle(at: sleepStart, kind: .sleep, uptime: 50_000),
        lifecycle(at: sleepEnd, kind: .wake, uptime: 50_600),
      ]
    )
    var values = samples(
      from: checkpoint.auditStartUTC,
      to: checkpoint.requiredEndUTC,
      excluding: sleepStart..<sleepEnd
    )
    values.removeFirst(8)
    values.append(sample(at: sleepStart.addingTimeInterval(120)))
    try database.insert(samples: values)
    _ = try database.performHistoryMaintenance(now: checkpoint.requiredEndUTC)

    let report = try MemoryRunAuditor(database: database).makeReport(
      checkpoint: checkpoint,
      now: checkpoint.requiredEndUTC,
      activityMonitorComparisons: comparisons(for: checkpoint)
    )

    XCTAssertEqual(report.disposition, .hold)
    XCTAssertGreaterThan(report.unexplainedMissingSlotCount, 0)
    XCTAssertGreaterThan(report.samplesInsideSleepCount, 0)
  }

  func testIncompleteDurationAndMissingObservationsRemainPending() throws {
    let fixture = try makeFixture()
    let database = try MemoryWatcherDatabase(url: fixture.databaseURL)
    try database.insert(samples: [sample(at: fixture.checkpointTime)])
    let auditor = MemoryRunAuditor(database: database)
    let checkpoint = try auditor.makeCheckpoint(now: fixture.checkpointTime)
    try database.insert(
      samples: samples(
        from: checkpoint.auditStartUTC,
        to: checkpoint.auditStartUTC.addingTimeInterval(60),
        excluding: checkpoint.requiredEndUTC..<checkpoint.requiredEndUTC
      )
    )

    let report = try auditor.makeReport(
      checkpoint: checkpoint,
      now: checkpoint.auditStartUTC.addingTimeInterval(60),
      activityMonitorComparisons: []
    )

    XCTAssertEqual(report.disposition, .pending)
    XCTAssertTrue(report.awaitingRequirements.contains("24-hour duration"))
    XCTAssertTrue(
      report.awaitingRequirements.contains("completed sleep and wake interval")
    )
    XCTAssertTrue(
      report.awaitingRequirements.contains("three Activity Monitor comparisons")
    )
  }

  private func samples(
    from start: Date,
    to end: Date,
    excluding sleep: Range<Date>
  ) -> [MemorySample] {
    var values: [MemorySample] = []
    var cursor = start
    while cursor < end {
      if !sleep.contains(cursor) {
        values.append(sample(at: cursor))
      }
      cursor = cursor.addingTimeInterval(5)
    }
    return values
  }

  private func sample(at date: Date) -> MemorySample {
    MemorySample(
      timestampUTC: date,
      systemUptimeSeconds: max(0, date.timeIntervalSince1970),
      physicalMemoryBytes: 1_000_000,
      estimatedMemoryUsedBytes: 500_000,
      wiredBytes: 100_000,
      compressedBytes: 50_000,
      estimatedCachedFilesBytes: 200_000,
      swapUsedBytes: 10_000,
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

  private func comparisons(
    for checkpoint: MemoryRunAuditCheckpoint
  ) -> [MemoryActivityMonitorComparison] {
    [60.0, 12 * 60 * 60, 24 * 60 * 60 - 60].map { offset in
      let date = checkpoint.auditStartUTC.addingTimeInterval(offset)
      let values = MemoryAuditMetricValues(
        physicalMemoryBytes: 1_000_000,
        memoryUsedBytes: 500_000,
        wiredBytes: 100_000,
        compressedBytes: 50_000,
        cachedFilesBytes: 200_000,
        swapUsedBytes: 10_000
      )
      return MemoryActivityMonitorComparison(
        label: "comparison-\(Int(offset))",
        observedAtUTC: date,
        memoryWatcherSampleUTC: date,
        activityMonitor: values,
        memoryWatcher: values,
        differencesExplained: true,
        explanation: "Values use the same fixture counters."
      )
    }
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

  private func makeFixture() throws -> AuditFixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
    }
    return AuditFixture(
      databaseURL: directory.appendingPathComponent("audit.sqlite3"),
      checkpointTime: Date(timeIntervalSince1970: 4_000_000.5)
    )
  }
}

private struct AuditFixture {
  let databaseURL: URL
  let checkpointTime: Date
}
