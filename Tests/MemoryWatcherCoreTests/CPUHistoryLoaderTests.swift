import Foundation
import XCTest

@testable import MemoryWatcherCore

final class CPUHistoryLoaderTests: XCTestCase {
  func testEveryPeriodUsesRawThenOneMinuteCPUStorage() throws {
    let database = try makeDatabase()
    let day: TimeInterval = 24 * 60 * 60
    let now = Date(timeIntervalSince1970: 60 * day)
    let dates = [
      now.addingTimeInterval(-2.5 * day),
      now.addingTimeInterval(-23 * 60 * 60),
      now.addingTimeInterval(-11 * 60 * 60),
      now.addingTimeInterval(-5 * 60),
    ]
    let topology = Self.topology(epoch: "periods-8", count: 8)
    try database.insert(
      totalCPUSamples: dates.enumerated().map { index, date in
        Self.totalSample(endingAt: date, uptime: 10_000 + Double(index) * 5)
      }
    )
    for (index, date) in dates.enumerated() {
      try database.insert(
        logicalCPUSamples: Self.logicalBatch(
          topology: topology,
          endingAt: date,
          uptime: 10_000 + Double(index) * 5
        )
      )
    }
    _ = try database.performHistoryMaintenance(now: now)
    let loader = MemoryHistoryLoader(database: database)

    let twelveHours = try loader.load(period: .twelveHours, now: now)
    let twentyFourHours = try loader.load(period: .twentyFourHours, now: now)
    let threeDays = try loader.load(period: .threeDays, now: now)

    XCTAssertEqual(twelveHours.cpuHistory.totalPoints.map(\.timestampUTC), Array(dates.suffix(2)))
    XCTAssertEqual(Set(twelveHours.cpuHistory.totalPoints.map(\.source)), [.raw])
    XCTAssertEqual(twelveHours.cpuHistory.logicalPoints.count, 16)
    XCTAssertEqual(
      twentyFourHours.cpuHistory.totalPoints.map(\.timestampUTC), Array(dates.suffix(3)))
    XCTAssertEqual(twentyFourHours.cpuHistory.logicalPoints.count, 24)
    XCTAssertEqual(threeDays.cpuHistory.totalPoints.count, 4)
    XCTAssertEqual(Set(threeDays.cpuHistory.totalPoints.map(\.source)), [.oneMinute])
    XCTAssertEqual(threeDays.cpuHistory.logicalPoints.count, 32)
    XCTAssertEqual(Set(threeDays.cpuHistory.logicalPoints.map(\.source)), [.oneMinute])
  }

  func testUnknownSleepAndUnavailableBoundariesRemainUnfilled() throws {
    let database = try makeDatabase()
    let now = Date(timeIntervalSince1970: 500_000)
    let topology = Self.topology(epoch: "gaps-2", count: 2)
    let measuredDates = [-50.0, -45.0, -35.0, -30.0, -10.0].map {
      now.addingTimeInterval($0)
    }
    try database.insert(
      totalCPUSamples: [
        Self.totalSample(endingAt: measuredDates[0], uptime: 1_000),
        Self.totalSample(endingAt: measuredDates[1], uptime: 1_005),
        Self.unknownTotalSample(
          endingAt: now.addingTimeInterval(-40),
          uptime: 1_010,
          quality: .unavailable
        ),
        Self.totalSample(endingAt: measuredDates[2], uptime: 1_015),
        Self.totalSample(endingAt: measuredDates[3], uptime: 1_020),
        Self.totalSample(endingAt: measuredDates[4], uptime: 1_040),
      ]
    )
    for (index, date) in measuredDates.enumerated() {
      try database.insert(
        logicalCPUSamples: Self.logicalBatch(
          topology: topology,
          endingAt: date,
          uptime: 2_000 + Double(index) * 5
        )
      )
    }
    try database.insert(
      logicalCPUGaps: [
        LogicalCPUSamplingGap(
          timestampUTC: now.addingTimeInterval(-40),
          systemUptimeSeconds: 2_010,
          previousTopology: topology
        )
      ]
    )
    try database.insert(
      lifecycleEvents: [
        SystemLifecycleEvent(
          timestampUTC: now.addingTimeInterval(-29),
          systemUptimeSeconds: 3_000,
          kind: .sleep
        ),
        SystemLifecycleEvent(
          timestampUTC: now.addingTimeInterval(-20),
          systemUptimeSeconds: 3_009,
          kind: .wake
        ),
      ]
    )

    let snapshot = try MemoryHistoryLoader(database: database).load(
      period: .twelveHours,
      now: now
    )

    XCTAssertEqual(
      snapshot.cpuHistory.totalPoints.map(\.continuitySegment),
      [0, 0, 1, 1, 2]
    )
    let logicalCPUZero = snapshot.cpuHistory.logicalPoints.filter {
      $0.cpuIndex == 0
    }
    XCTAssertEqual(
      logicalCPUZero.map(\.continuitySegment),
      [0, 0, 1, 1, 2]
    )
    XCTAssertFalse(
      snapshot.cpuHistory.totalPoints.contains {
        $0.timestampUTC == now.addingTimeInterval(-40)
      }
    )
    XCTAssertEqual(snapshot.sleepIntervals.count, 1)
  }

  func testTopologyEpochsNeverJoinTheSameLogicalSeries() throws {
    let database = try makeDatabase()
    let now = Date(timeIntervalSince1970: 600_000)
    let oldTopology = Self.topology(epoch: "old-8", count: 8)
    let newTopology = Self.topology(epoch: "new-16", count: 16)
    try database.insert(
      logicalCPUSamples: Self.logicalBatch(
        topology: oldTopology,
        endingAt: now.addingTimeInterval(-15),
        uptime: 4_000
      )
    )
    try database.insert(
      logicalCPUSamples: Self.logicalUnknownBatch(
        topology: newTopology,
        endingAt: now.addingTimeInterval(-10),
        uptime: 4_005,
        quality: .topologyChangeBoundary
      )
    )
    try database.insert(
      logicalCPUSamples: Self.logicalBatch(
        topology: newTopology,
        endingAt: now.addingTimeInterval(-5),
        uptime: 4_010
      )
    )

    let points = try MemoryHistoryLoader(database: database).load(
      period: .twelveHours,
      now: now
    ).cpuHistory.logicalPoints

    XCTAssertEqual(points.filter { $0.topology == oldTopology }.count, 8)
    XCTAssertEqual(points.filter { $0.topology == newTopology }.count, 16)
    XCTAssertTrue(
      Set(points.map(\.seriesIdentifier)).allSatisfy {
        $0.contains("old-8") || $0.contains("new-16")
      }
    )
  }

  func testCPUTickCompositionIsRenderedAsExactPercentages() throws {
    let database = try makeDatabase()
    let now = Date(timeIntervalSince1970: 700_000)
    let sample = TotalCPUSample(
      intervalStartUTC: now.addingTimeInterval(-10),
      intervalEndUTC: now.addingTimeInterval(-5),
      intervalStartUptimeSeconds: 4_000,
      intervalEndUptimeSeconds: 4_005,
      delta: CPUCounterDelta(
        userTicks: 20,
        systemTicks: 10,
        idleTicks: 60,
        niceTicks: 10,
        busyTicks: 40,
        totalTicks: 100
      ),
      quality: .measured
    )
    try database.insert(totalCPUSamples: [sample])

    let point = try XCTUnwrap(
      MemoryHistoryLoader(database: database).load(
        period: .twelveHours,
        now: now
      ).cpuHistory.totalPoints.first
    )

    XCTAssertEqual(point.userPercent, 20, accuracy: 0.000_001)
    XCTAssertEqual(point.systemPercent, 10, accuracy: 0.000_001)
    XCTAssertEqual(point.nicePercent, 10, accuracy: 0.000_001)
    XCTAssertEqual(point.idlePercent, 60, accuracy: 0.000_001)
    XCTAssertEqual(point.utilizationPercent, 40, accuracy: 0.000_001)
    XCTAssertEqual(
      point.userPercent + point.systemPercent + point.nicePercent,
      point.utilizationPercent,
      accuracy: 0.000_001
    )
  }

  func testUnknownMarkersRemainAvailableForThreeDayGapRendering() throws {
    let database = try makeDatabase()
    let day: TimeInterval = 24 * 60 * 60
    let now = Date(timeIntervalSince1970: 80 * day)
    let unknownDate = now.addingTimeInterval(-2 * day)
    let topology = Self.topology(epoch: "unknown-retention-1", count: 1)
    let unknownTotal = Self.unknownTotalSample(
      endingAt: unknownDate,
      uptime: 5_000,
      quality: .unavailable
    )
    let unknownLogical = Self.logicalUnknownBatch(
      topology: topology,
      endingAt: unknownDate,
      uptime: 5_000,
      quality: .unavailable
    )
    try database.insert(totalCPUSamples: [unknownTotal])
    try database.insert(logicalCPUSamples: unknownLogical)

    _ = try database.performHistoryMaintenance(now: now)

    XCTAssertEqual(
      try database.fetchTotalCPUUnknownSamples(
        from: now.addingTimeInterval(-3 * day),
        through: now
      ),
      [unknownTotal]
    )
    XCTAssertEqual(
      try database.fetchLogicalCPUUnknownSamples(
        from: now.addingTimeInterval(-3 * day),
        through: now
      ),
      unknownLogical
    )
  }

  func testThirtyTwoCPUThreeDaySnapshotLoadsUnderTwoSeconds() throws {
    let database = try makeDatabase()
    let now = Date(timeIntervalSince1970: 100 * 24 * 60 * 60)
    let start = now.addingTimeInterval(-3 * 24 * 60 * 60)
    let topology = Self.topology(epoch: "performance-32", count: 32)
    let minuteCount = 3 * 24 * 60
    try database.insert(
      totalCPUSamples: (0..<minuteCount).map { index in
        Self.totalSample(
          endingAt: start.addingTimeInterval(Double(index) * 60 + 5),
          uptime: 10_000 + Double(index) * 60
        )
      }
    )
    for index in 0..<minuteCount {
      try database.insert(
        logicalCPUSamples: Self.logicalBatch(
          topology: topology,
          endingAt: start.addingTimeInterval(Double(index) * 60 + 5),
          uptime: 10_000 + Double(index) * 60
        )
      )
    }
    _ = try database.performHistoryMaintenance(now: now)

    let startedAt = Date()
    let snapshot = try MemoryHistoryLoader(database: database).load(
      period: .threeDays,
      now: now
    )
    let elapsed = Date().timeIntervalSince(startedAt)

    XCTAssertEqual(snapshot.cpuHistory.totalPoints.count, minuteCount)
    XCTAssertEqual(
      snapshot.cpuHistory.logicalPoints.count,
      minuteCount * topology.logicalCPUCount
    )
    XCTAssertEqual(Set(snapshot.cpuHistory.totalPoints.map(\.source)), [.oneMinute])
    XCTAssertEqual(Set(snapshot.cpuHistory.logicalPoints.map(\.source)), [.oneMinute])
    XCTAssertLessThan(elapsed, 2)
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
      url: directory.appendingPathComponent("cpu-history.sqlite3")
    )
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

  private static func totalSample(
    endingAt date: Date,
    uptime: TimeInterval
  ) -> TotalCPUSample {
    TotalCPUSample(
      intervalStartUTC: date.addingTimeInterval(-5),
      intervalEndUTC: date,
      intervalStartUptimeSeconds: uptime - 5,
      intervalEndUptimeSeconds: uptime,
      delta: delta(busy: 40, idle: 60),
      quality: .measured
    )
  }

  private static func unknownTotalSample(
    endingAt date: Date,
    uptime: TimeInterval,
    quality: CPUUtilizationQuality
  ) -> TotalCPUSample {
    TotalCPUSample(
      intervalStartUTC: nil,
      intervalEndUTC: date,
      intervalStartUptimeSeconds: nil,
      intervalEndUptimeSeconds: uptime,
      delta: nil,
      quality: quality
    )
  }

  private static func logicalBatch(
    topology: LogicalCPUTopology,
    endingAt date: Date,
    uptime: TimeInterval
  ) -> [LogicalCPUSample] {
    (0..<topology.logicalCPUCount).map { cpuIndex in
      LogicalCPUSample(
        topology: topology,
        cpuIndex: cpuIndex,
        intervalStartUTC: date.addingTimeInterval(-5),
        intervalEndUTC: date,
        intervalStartUptimeSeconds: uptime - 5,
        intervalEndUptimeSeconds: uptime,
        delta: delta(
          busy: UInt64(20 + cpuIndex % 70),
          idle: UInt64(80 - cpuIndex % 70)
        ),
        quality: .measured
      )
    }
  }

  private static func logicalUnknownBatch(
    topology: LogicalCPUTopology,
    endingAt date: Date,
    uptime: TimeInterval,
    quality: CPUUtilizationQuality
  ) -> [LogicalCPUSample] {
    (0..<topology.logicalCPUCount).map { cpuIndex in
      LogicalCPUSample(
        topology: topology,
        cpuIndex: cpuIndex,
        intervalStartUTC: nil,
        intervalEndUTC: date,
        intervalStartUptimeSeconds: nil,
        intervalEndUptimeSeconds: uptime,
        delta: nil,
        quality: quality
      )
    }
  }

  private static func delta(busy: UInt64, idle: UInt64) -> CPUCounterDelta {
    let user = busy / 2
    let system = busy - user
    return CPUCounterDelta(
      userTicks: user,
      systemTicks: system,
      idleTicks: idle,
      niceTicks: 0,
      busyTicks: busy,
      totalTicks: busy + idle
    )
  }
}
