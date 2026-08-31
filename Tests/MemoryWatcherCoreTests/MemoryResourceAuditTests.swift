import Foundation
import XCTest

@testable import MemoryWatcherCore

final class MemoryResourceAuditTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 2_000_000_000)

  func testCompleteEfficientRunPasses() {
    let auditor = MemoryResourceAuditor()
    let checkpoint = auditor.makeCheckpoint(
      processIdentifier: 42,
      forbiddenNetworkAPIMatchCount: 0,
      forbiddenNotificationAPIMatchCount: 0,
      initialIntegrityCheck: "ok",
      now: start
    )
    let report = auditor.makeReport(
      checkpoint: checkpoint,
      observations: [
        observation(hours: 0, cpuSeconds: 10, residentBytes: 100),
        observation(hours: 8, cpuSeconds: 40, residentBytes: 120),
        observation(hours: 16, cpuSeconds: 70, residentBytes: 110),
        observation(hours: 24, cpuSeconds: 90, residentBytes: 115),
      ],
      currentIntegrityCheck: "ok",
      now: start.addingTimeInterval(24 * 60 * 60)
    )

    XCTAssertEqual(report.disposition, .passed)
    XCTAssertLessThan(report.averageCPUPercent ?? .infinity, 1)
    XCTAssertEqual(report.residentMemoryMonotonicallyGrowing, false)
    XCTAssertEqual(report.maximumInternetSocketCount, 0)
    XCTAssertEqual(report.integrityCheck, "ok")
    XCTAssertTrue(report.awaitingRequirements.isEmpty)
    XCTAssertTrue(report.holdReasons.isEmpty)
  }

  func testIncompleteRunRemainsPending() {
    let auditor = MemoryResourceAuditor()
    let checkpoint = auditor.makeCheckpoint(
      processIdentifier: 42,
      forbiddenNetworkAPIMatchCount: 0,
      forbiddenNotificationAPIMatchCount: 0,
      initialIntegrityCheck: "ok",
      now: start
    )
    let report = auditor.makeReport(
      checkpoint: checkpoint,
      observations: [
        observation(hours: 0, cpuSeconds: 10, residentBytes: 100),
        observation(hours: 8, cpuSeconds: 20, residentBytes: 110),
      ],
      currentIntegrityCheck: "ok",
      now: start.addingTimeInterval(8 * 60 * 60)
    )

    XCTAssertEqual(report.disposition, .pending)
    XCTAssertTrue(report.awaitingRequirements.contains("24-hour duration"))
    XCTAssertTrue(
      report.awaitingRequirements.contains("four resource observations")
    )
    XCTAssertTrue(
      report.awaitingRequirements.contains("24-hour observation span")
    )
  }

  func testAuditHoldsEarlyWhenCPUTargetCannotBeRecoveredWithinDay() {
    let auditor = MemoryResourceAuditor()
    let checkpoint = auditor.makeCheckpoint(
      processIdentifier: 42,
      forbiddenNetworkAPIMatchCount: 0,
      forbiddenNotificationAPIMatchCount: 0,
      initialIntegrityCheck: "ok",
      now: start
    )
    let report = auditor.makeReport(
      checkpoint: checkpoint,
      observations: [
        observation(hours: 0, cpuSeconds: 0, residentBytes: 100),
        observation(hours: 8, cpuSeconds: 900, residentBytes: 110),
      ],
      currentIntegrityCheck: "ok",
      now: start.addingTimeInterval(8 * 60 * 60)
    )

    XCTAssertEqual(report.disposition, .hold)
    XCTAssertTrue(
      report.holdReasons.contains(
        "average idle CPU target is no longer reachable"
      )
    )
  }

  func testHighCPUAndMonotonicResidentMemoryCauseHold() {
    let auditor = MemoryResourceAuditor()
    let checkpoint = auditor.makeCheckpoint(
      processIdentifier: 42,
      forbiddenNetworkAPIMatchCount: 0,
      forbiddenNotificationAPIMatchCount: 0,
      initialIntegrityCheck: "ok",
      now: start
    )
    let report = auditor.makeReport(
      checkpoint: checkpoint,
      observations: [
        observation(hours: 0, cpuSeconds: 0, residentBytes: 100),
        observation(hours: 8, cpuSeconds: 300, residentBytes: 110),
        observation(hours: 16, cpuSeconds: 600, residentBytes: 120),
        observation(hours: 24, cpuSeconds: 900, residentBytes: 130),
      ],
      currentIntegrityCheck: "ok",
      now: start.addingTimeInterval(24 * 60 * 60)
    )

    XCTAssertEqual(report.disposition, .hold)
    XCTAssertTrue(
      report.holdReasons.contains("average idle CPU target was not met")
    )
    XCTAssertTrue(report.holdReasons.contains("resident memory grew monotonically"))
  }

  func testCommunicationAndIntegrityFailuresHoldImmediately() {
    let auditor = MemoryResourceAuditor()
    let checkpoint = auditor.makeCheckpoint(
      processIdentifier: 42,
      forbiddenNetworkAPIMatchCount: 1,
      forbiddenNotificationAPIMatchCount: 1,
      initialIntegrityCheck: "not ok",
      now: start
    )
    let connectedObservation = observation(
      hours: 0,
      cpuSeconds: 0,
      residentBytes: 100,
      internetSocketCount: 1
    )
    let report = auditor.makeReport(
      checkpoint: checkpoint,
      observations: [connectedObservation],
      currentIntegrityCheck: "not ok",
      now: start
    )

    XCTAssertEqual(report.disposition, .hold)
    XCTAssertTrue(report.holdReasons.contains("SQLite integrity check failed"))
    XCTAssertTrue(report.holdReasons.contains("network API exists in product source"))
    XCTAssertTrue(
      report.holdReasons.contains("notification API exists in product source")
    )
    XCTAssertTrue(report.holdReasons.contains("target process opened an Internet socket"))
  }

  func testDatabaseProjectionUsesRetentionMaximumAndCapacityLimit() {
    // 24 hours of 5-second samples plus 3 days of 1- and 5-minute buckets.
    let maximumRows = 17_280 + 4_320 + 864
    let remainingRowBytes = UInt64(maximumRows - 300) * 1_024
    let capacityLimit = MemoryResourceAuditor.databaseCapacityLimitBytes
    let withinLimit = observation(
      hours: 0,
      cpuSeconds: 0,
      residentBytes: 100,
      databaseBytes: 1_000_000
    )
    let overLimit = observation(
      hours: 0,
      cpuSeconds: 0,
      residentBytes: 100,
      databaseBytes: capacityLimit - remainingRowBytes + 1
    )

    XCTAssertEqual(
      MemoryResourceAuditor.projectedRetainedDatabaseBytes(from: withinLimit),
      1_000_000 + remainingRowBytes
    )
    XCTAssertLessThan(
      MemoryResourceAuditor.projectedRetainedDatabaseBytes(from: withinLimit),
      MemoryResourceAuditor.databaseCapacityLimitBytes
    )
    XCTAssertGreaterThan(
      MemoryResourceAuditor.projectedRetainedDatabaseBytes(from: overLimit),
      MemoryResourceAuditor.databaseCapacityLimitBytes
    )
  }

  func testCapacityBoundaryAllowsLimitAndHoldsOneByteAbove() {
    let auditor = MemoryResourceAuditor()
    let checkpoint = auditor.makeCheckpoint(
      processIdentifier: 42,
      forbiddenNetworkAPIMatchCount: 0,
      forbiddenNotificationAPIMatchCount: 0,
      initialIntegrityCheck: "ok",
      now: start
    )
    let remainingRowBytes = UInt64(17_280 + 4_320 + 864 - 300) * 1_024
    let atLimitBytes =
      MemoryResourceAuditor.databaseCapacityLimitBytes - remainingRowBytes

    for excessBytes in UInt64(0)...1 {
      let report = auditor.makeReport(
        checkpoint: checkpoint,
        observations: [
          observation(
            hours: 0,
            cpuSeconds: 0,
            residentBytes: 100,
            databaseBytes: atLimitBytes + excessBytes
          )
        ],
        currentIntegrityCheck: "ok",
        now: start
      )

      XCTAssertEqual(
        report.projectedRetainedDatabaseBytes,
        MemoryResourceAuditor.databaseCapacityLimitBytes + excessBytes
      )
      XCTAssertEqual(report.disposition, excessBytes == 0 ? .pending : .hold)
      XCTAssertEqual(
        report.holdReasons,
        excessBytes == 0 ? [] : ["projected retained database exceeds capacity limit"]
      )
    }
  }

  private func observation(
    hours: TimeInterval,
    cpuSeconds: TimeInterval,
    residentBytes: UInt64,
    internetSocketCount: Int = 0,
    databaseBytes: UInt64 = 1_000_000
  ) -> MemoryResourceObservation {
    MemoryResourceObservation(
      observedAtUTC: start.addingTimeInterval(hours * 60 * 60),
      processIdentifier: 42,
      cumulativeCPUSeconds: cpuSeconds,
      residentMemoryBytes: residentBytes,
      internetSocketCount: internetSocketCount,
      databaseFileSetBytes: databaseBytes,
      rawSampleCount: 100,
      oneMinuteAggregateCount: 100,
      fiveMinuteAggregateCount: 100
    )
  }
}
