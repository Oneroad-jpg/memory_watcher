import XCTest

@testable import MemoryWatcherCore

final class DashboardFinalAuditPolicyTests: XCTestCase {
  func testFinalAuditUsesThirtyMinuteVisibleAndHiddenPhases() {
    XCTAssertEqual(DashboardFinalAuditPolicy.warmUpSeconds, 60)
    XCTAssertEqual(DashboardFinalAuditPolicy.phaseDurationSeconds, 30 * 60)
    XCTAssertEqual(
      DashboardFinalAuditPolicy.checkpointMinutes,
      [0, 5, 10, 15, 20, 25, 30]
    )
  }

  func testFinalAuditKeepsFiveSecondSamplingToleranceAndReloadCadence() {
    XCTAssertEqual(DashboardFinalAuditPolicy.minimumRecordedSlots, 350)
    XCTAssertEqual(DashboardFinalAuditPolicy.expectedVisibleHistoryReloads, 6)
  }

  func testPhaseRecordCountDoesNotDependOnRetainedTableRowDelta() {
    let start = Date(timeIntervalSince1970: 10_000)
    let timestamps =
      [start.addingTimeInterval(-5)]
      + (0..<360).map { start.addingTimeInterval(Double($0) * 5) }
    let retainedRowCountBefore = 1_440
    let retainedRowCountAfterMaintenance = 1_440

    XCTAssertEqual(
      retainedRowCountAfterMaintenance - retainedRowCountBefore,
      0
    )
    XCTAssertEqual(
      DashboardFinalAuditPolicy.phaseRecordCount(
        timestamps: timestamps,
        from: start,
        through: start.addingTimeInterval(30 * 60)
      ),
      360
    )
  }
}
