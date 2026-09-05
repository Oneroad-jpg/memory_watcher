import Foundation
import XCTest

@testable import MemoryWatcherCore

final class UnifiedDashboardTests: XCTestCase {
  func testRuntimeAuditCountsCompleteExplicitGapsAsObservedSlots() {
    XCTAssertEqual(
      DashboardMemoryGapAuditEvaluator.observedSlotCount(
        sampleDelta: 155,
        explicitGapCount: 26
      ),
      181
    )
    XCTAssertNil(
      DashboardMemoryGapAuditEvaluator.observedSlotCount(
        sampleDelta: -1,
        explicitGapCount: 1
      )
    )
    XCTAssertNil(
      DashboardMemoryGapAuditEvaluator.observedSlotCount(
        sampleDelta: Int.max,
        explicitGapCount: 1
      )
    )
  }

  func testRuntimeAuditAcceptsOnlyCompleteExplicitGapDiagnostics() {
    let completeGap = memoryGap(attemptCount: 3)
    let accepted = DashboardMemoryGapAuditEvaluator.evaluate(
      allGaps: [completeGap],
      initialGapCount: 0,
      initialMonitoringFailureCount: 4,
      finalMonitoringFailureCount: 4
    )
    XCTAssertTrue(accepted.isValid)
    XCTAssertEqual(accepted.explicitGapCount, 1)
    XCTAssertEqual(
      accepted.reasonCounts,
      [MemoryCounterInconsistencyReason.classifiedExceedsEstimatedUsed.rawValue: 1]
    )
    XCTAssertEqual(accepted.monitoringFailureDelta, 0)

    XCTAssertFalse(
      DashboardMemoryGapAuditEvaluator.evaluate(
        allGaps: [memoryGap(attemptCount: 2)],
        initialGapCount: 0,
        initialMonitoringFailureCount: 4,
        finalMonitoringFailureCount: 4
      ).isValid
    )
    XCTAssertFalse(
      DashboardMemoryGapAuditEvaluator.evaluate(
        allGaps: [completeGap],
        initialGapCount: 0,
        initialMonitoringFailureCount: 4,
        finalMonitoringFailureCount: 5
      ).isValid
    )
  }

  func testCurrentCPUSeparatesMeasuredUnknownAndInvalidWithoutClamping() {
    let now = Date(timeIntervalSince1970: 100_000)
    for percent in [0.0, 50.0, 100.0] {
      var tracker = DashboardCPUTracker()
      tracker.receive(
        percent: percent,
        intervalStartUTC: now.addingTimeInterval(-5),
        intervalEndUTC: now,
        quality: .measured
      )
      let value = tracker.presentation(at: now, runState: .running)
      XCTAssertEqual(value.status, .current)
      XCTAssertEqual(value.percent, percent)
    }

    var unknown = DashboardCPUTracker()
    unknown.receive(
      percent: 50,
      intervalStartUTC: now.addingTimeInterval(-10),
      intervalEndUTC: now.addingTimeInterval(-5),
      quality: .measured
    )
    unknown.receive(
      percent: nil,
      intervalStartUTC: nil,
      intervalEndUTC: now,
      quality: .wakeBoundary
    )
    let unknownValue = unknown.presentation(at: now, runState: .running)
    XCTAssertEqual(unknownValue.status, .unknown)
    XCTAssertEqual(unknownValue.percent, 50)
    XCTAssertTrue(unknownValue.showsFinalValue)

    for invalidPercent in [-0.1, 100.1, Double.infinity] {
      var invalid = DashboardCPUTracker()
      invalid.receive(
        percent: invalidPercent,
        intervalStartUTC: now.addingTimeInterval(-5),
        intervalEndUTC: now,
        quality: .measured
      )
      XCTAssertEqual(
        invalid.presentation(at: now, runState: .running).status,
        .invalid
      )
    }
  }

  func testCurrentValueStalenessUsesExactFifteenSecondBoundary() {
    let measuredAt = Date(timeIntervalSince1970: 200_000)
    var cpu = DashboardCPUTracker()
    cpu.receive(
      percent: 50,
      intervalStartUTC: measuredAt.addingTimeInterval(-5),
      intervalEndUTC: measuredAt,
      quality: .measured
    )
    XCTAssertEqual(
      cpu.presentation(
        at: measuredAt.addingTimeInterval(14.999),
        runState: .running
      ).status,
      .current
    )
    XCTAssertEqual(
      cpu.presentation(
        at: measuredAt.addingTimeInterval(15),
        runState: .running
      ).status,
      .stale
    )
    XCTAssertEqual(
      cpu.presentation(at: measuredAt, runState: .sleeping).status,
      .stale
    )

    var memory = DashboardMemoryTracker()
    memory.receive(sample(at: measuredAt, usedBytes: 8_000_000_000))
    XCTAssertEqual(
      memory.presentation(
        at: measuredAt.addingTimeInterval(14.999),
        runState: .running
      ).status,
      .current
    )
    XCTAssertEqual(
      memory.presentation(
        at: measuredAt.addingTimeInterval(15),
        runState: .running
      ).status,
      .stale
    )
  }

  func testOneUnknownLogicalCPUDoesNotChangeOtherCPUOrMemory() {
    let now = Date(timeIntervalSince1970: 300_000)
    var cpu0 = DashboardCPUTracker()
    var cpu1 = DashboardCPUTracker()
    cpu0.receive(
      percent: nil,
      intervalStartUTC: nil,
      intervalEndUTC: now,
      quality: .unavailable
    )
    cpu1.receive(
      percent: 50,
      intervalStartUTC: now.addingTimeInterval(-5),
      intervalEndUTC: now,
      quality: .measured
    )
    var memory = DashboardMemoryTracker()
    memory.receive(sample(at: now, usedBytes: 7_000_000_000))

    XCTAssertEqual(
      cpu0.presentation(at: now, runState: .running).status,
      .unavailable
    )
    XCTAssertEqual(
      cpu1.presentation(at: now, runState: .running).percent,
      50
    )
    XCTAssertEqual(
      memory.presentation(at: now, runState: .running).usedBytes,
      7_000_000_000
    )
  }

  func testGenerationGateRejectsEveryOlderLoadResult() {
    var gate = DashboardHistoryGenerationGate()
    let first = gate.issue()
    var latest = first
    for _ in 0..<10 {
      latest = gate.issue()
    }
    XCTAssertFalse(gate.accepts(first))
    XCTAssertTrue(gate.accepts(latest))
  }

  func testLayoutAndDownsamplingPreserveEverySegmentBoundary() {
    XCTAssertEqual(
      DashboardLayoutPolicy.mode(forAvailableWidth: 1_280),
      .columns
    )
    XCTAssertEqual(
      DashboardLayoutPolicy.mode(forAvailableWidth: 1_024),
      .columns
    )
    XCTAssertEqual(
      DashboardLayoutPolicy.mode(forAvailableWidth: 900),
      .stacked
    )

    let segments = (0..<1_000).map { index in
      index < 250 ? "a" : index < 500 ? "b" : index < 750 ? "c" : "d"
    }
    let retained = DashboardDownsamplingPolicy.retainedIndices(
      segmentIdentifiers: segments,
      limit: 50
    )
    XCTAssertTrue(retained.contains(0))
    XCTAssertTrue(retained.contains(249))
    XCTAssertTrue(retained.contains(250))
    XCTAssertTrue(retained.contains(499))
    XCTAssertTrue(retained.contains(500))
    XCTAssertTrue(retained.contains(749))
    XCTAssertTrue(retained.contains(750))
    XCTAssertTrue(retained.contains(999))

    XCTAssertEqual(
      DashboardChartPointBudget.logicalPerSeriesLimit(seriesCount: 1),
      400
    )
    XCTAssertEqual(
      DashboardChartPointBudget.logicalPerSeriesLimit(seriesCount: 8),
      50
    )
    XCTAssertEqual(
      DashboardChartPointBudget.logicalPerSeriesLimit(seriesCount: 16),
      25
    )
    XCTAssertEqual(
      DashboardChartPointBudget.logicalPerSeriesLimit(seriesCount: 32),
      12
    )
  }

  func testRenderSnapshotBoundsChartsInputBeforeTheViewReceivesIt() {
    let start = Date(timeIntervalSince1970: 350_000)
    let memory = (0..<1_000).map { index in
      memoryPoint(
        at: start.addingTimeInterval(TimeInterval(index * 5)),
        source: .raw
      )
    }
    let total = (0..<1_000).map { index in
      let intervalStart = start.addingTimeInterval(TimeInterval(index * 5))
      return totalPoint(
        start: intervalStart,
        end: intervalStart.addingTimeInterval(5),
        source: .raw
      )
    }
    let topology = LogicalCPUTopology(
      epochKey: "render-8",
      bootSessionStartUTC: start.addingTimeInterval(-1_000),
      logicalCPUCount: 8
    )
    let logical = (0..<8).flatMap { cpuIndex in
      (0..<1_000).map { index in
        let intervalStart = start.addingTimeInterval(
          TimeInterval(index * 5)
        )
        return LogicalCPUHistoryPoint(
          topology: topology,
          cpuIndex: cpuIndex,
          timestampUTC: intervalStart.addingTimeInterval(5),
          intervalStartUTC: intervalStart,
          intervalEndUTC: intervalStart.addingTimeInterval(5),
          source: .raw,
          sampleCount: 1,
          continuitySegment: index < 500 ? 0 : 1,
          userPercent: 30,
          systemPercent: 15,
          nicePercent: 5,
          idlePercent: 50,
          utilizationPercent: 50
        )
      }
    }
    let source = snapshot(
      period: .twelveHours,
      start: start,
      end: start.addingTimeInterval(5_000),
      memory: memory,
      total: total,
      logical: logical
    )

    let render = DashboardHistoryRenderSnapshot(snapshot: source)

    XCTAssertLessThanOrEqual(
      render.memoryPoints.count,
      DashboardChartPointBudget.primarySeriesLimit + 4
    )
    XCTAssertLessThanOrEqual(
      render.totalCPUPoints.count,
      DashboardChartPointBudget.primarySeriesLimit + 4
    )
    XCTAssertEqual(render.logicalCPUSeries.map(\.cpuIndex), Array(0..<8))
    XCTAssertTrue(
      render.logicalCPUSeries.allSatisfy {
        $0.points.count
          <= DashboardChartPointBudget.logicalPerSeriesLimit(seriesCount: 8) + 4
      }
    )
    XCTAssertLessThanOrEqual(
      render.logicalCPUSeries.reduce(0) { $0 + $1.points.count },
      DashboardChartPointBudget.logicalTotalLimit + 8 * 4
    )
    XCTAssertEqual(render.logicalCPUSeries.first?.points.first, logical.first)
    XCTAssertEqual(
      render.logicalCPUSeries.last?.points.last,
      logical.last
    )
  }

  func testRawSelectionUsesPreviousFiveSecondValueAndRejectsGap() {
    let start = Date(timeIntervalSince1970: 400_000)
    let memory = memoryPoint(at: start.addingTimeInterval(10), source: .raw)
    let total = totalPoint(
      start: start.addingTimeInterval(5),
      end: start.addingTimeInterval(10),
      source: .raw
    )
    let logical = logicalPoint(
      start: start.addingTimeInterval(5),
      end: start.addingTimeInterval(10),
      source: .raw
    )
    let baseSnapshot = snapshot(
      period: .twelveHours,
      start: start,
      end: start.addingTimeInterval(100),
      memory: [memory],
      total: [total],
      logical: [logical]
    )

    let accepted = DashboardHistorySelectionResolver.resolve(
      snapshot: baseSnapshot,
      at: start.addingTimeInterval(15)
    )
    XCTAssertEqual(accepted.memory, memory)
    XCTAssertEqual(accepted.totalCPU, total)
    XCTAssertEqual(accepted.logicalCPUs, [logical])

    let gapDate = start.addingTimeInterval(12)
    let gapSnapshot = snapshot(
      period: .twelveHours,
      start: start,
      end: start.addingTimeInterval(100),
      memory: [memory],
      total: [total],
      logical: [logical],
      memoryDiscontinuities: [gapDate],
      totalDiscontinuities: [gapDate],
      logicalDiscontinuities: [gapDate]
    )
    let rejected = DashboardHistorySelectionResolver.resolve(
      snapshot: gapSnapshot,
      at: start.addingTimeInterval(13)
    )
    XCTAssertNil(rejected.memory)
    XCTAssertNil(rejected.totalCPU)
    XCTAssertTrue(rejected.logicalCPUs.isEmpty)
  }

  func testRawSelectionUsesLaterMemoryTimestampWithoutRelaxingFiveSeconds() {
    let start = Date(timeIntervalSince1970: 450_000)
    let cpuEnd = start.addingTimeInterval(10)
    let memoryTime = cpuEnd.addingTimeInterval(0.001)
    let memory = memoryPoint(at: memoryTime, source: .raw)
    let total = totalPoint(
      start: start.addingTimeInterval(5),
      end: cpuEnd,
      source: .raw
    )
    let logical = logicalPoint(
      start: start.addingTimeInterval(5),
      end: cpuEnd,
      source: .raw
    )
    let value = snapshot(
      period: .twelveHours,
      start: start,
      end: start.addingTimeInterval(100),
      memory: [memory],
      total: [total],
      logical: [logical]
    )

    let atCPUTime = DashboardHistorySelectionResolver.resolve(
      snapshot: value,
      at: cpuEnd
    )
    XCTAssertNil(atCPUTime.memory)
    XCTAssertEqual(atCPUTime.totalCPU, total)

    let atMemoryTime = DashboardHistorySelectionResolver.resolve(
      snapshot: value,
      at: memoryTime
    )
    XCTAssertEqual(atMemoryTime.memory, memory)
    XCTAssertEqual(atMemoryTime.totalCPU, total)
    XCTAssertEqual(atMemoryTime.logicalCPUs, [logical])

    let outsideTolerance = DashboardHistorySelectionResolver.resolve(
      snapshot: value,
      at: cpuEnd.addingTimeInterval(5.001)
    )
    XCTAssertNil(outsideTolerance.totalCPU)
    XCTAssertTrue(outsideTolerance.logicalCPUs.isEmpty)
  }

  func testAggregateSelectionUsesHalfOpenIntervalAndRejectsSleep() {
    let start = Date(timeIntervalSince1970: 500_000)
    let memory = memoryPoint(at: start, source: .oneMinute)
    let total = totalPoint(
      start: start,
      end: start.addingTimeInterval(60),
      source: .oneMinute
    )
    let logical = logicalPoint(
      start: start,
      end: start.addingTimeInterval(60),
      source: .oneMinute
    )
    let baseSnapshot = snapshot(
      period: .threeDays,
      start: start,
      end: start.addingTimeInterval(120),
      memory: [memory],
      total: [total],
      logical: [logical]
    )
    let inside = DashboardHistorySelectionResolver.resolve(
      snapshot: baseSnapshot,
      at: start.addingTimeInterval(59.999)
    )
    XCTAssertEqual(inside.memory, memory)
    XCTAssertEqual(inside.totalCPU, total)
    XCTAssertEqual(inside.logicalCPUs, [logical])

    let atEnd = DashboardHistorySelectionResolver.resolve(
      snapshot: baseSnapshot,
      at: start.addingTimeInterval(60)
    )
    XCTAssertNil(atEnd.memory)
    XCTAssertNil(atEnd.totalCPU)
    XCTAssertTrue(atEnd.logicalCPUs.isEmpty)

    let sleeping = snapshot(
      period: .threeDays,
      start: start,
      end: start.addingTimeInterval(120),
      memory: [memory],
      total: [total],
      logical: [logical],
      sleep: [
        SystemSleepInterval(
          startUTC: start.addingTimeInterval(20),
          endUTC: start.addingTimeInterval(30)
        )
      ]
    )
    let insideSleep = DashboardHistorySelectionResolver.resolve(
      snapshot: sleeping,
      at: start.addingTimeInterval(25)
    )
    XCTAssertNil(insideSleep.memory)
    XCTAssertNil(insideSleep.totalCPU)
    XCTAssertTrue(insideSleep.logicalCPUs.isEmpty)
  }

  private func snapshot(
    period: MemoryHistoryPeriod,
    start: Date,
    end: Date,
    memory: [MemoryHistoryPoint],
    total: [TotalCPUHistoryPoint],
    logical: [LogicalCPUHistoryPoint],
    memoryDiscontinuities: [Date] = [],
    totalDiscontinuities: [Date] = [],
    logicalDiscontinuities: [Date] = [],
    sleep: [SystemSleepInterval] = []
  ) -> MemoryHistorySnapshot {
    MemoryHistorySnapshot(
      period: period,
      startUTC: start,
      endUTC: end,
      points: memory,
      pressureIntervals: [
        MemoryPressureInterval(startUTC: start, endUTC: end, level: .normal)
      ],
      sleepIntervals: sleep,
      memoryDiscontinuityDates: memoryDiscontinuities,
      cpuHistory: CPUHistorySnapshot(
        totalPoints: total,
        logicalPoints: logical,
        totalDiscontinuityDates: totalDiscontinuities,
        logicalGlobalDiscontinuityDates: logicalDiscontinuities
      )
    )
  }

  private func memoryPoint(
    at date: Date,
    source: MemoryHistoryPointSource
  ) -> MemoryHistoryPoint {
    let intervalEnd = source == .raw ? date : date.addingTimeInterval(60)
    return MemoryHistoryPoint(
      timestampUTC: date,
      intervalStartUTC: date,
      intervalEndUTC: intervalEnd,
      source: source,
      sampleCount: source == .raw ? 1 : 12,
      continuitySegment: 0,
      physicalMemoryBytes: 16_000_000_000,
      estimatedMemoryUsedBytes: 8_000_000_000,
      estimatedOtherUsedBytes: 5_000_000_000,
      wiredBytes: 2_000_000_000,
      compressedBytes: 1_000_000_000,
      estimatedCachedFilesBytes: 3_000_000_000,
      swapUsedBytes: 500_000_000
    )
  }

  private func totalPoint(
    start: Date,
    end: Date,
    source: MemoryHistoryPointSource
  ) -> TotalCPUHistoryPoint {
    TotalCPUHistoryPoint(
      timestampUTC: source == .raw ? end : start,
      intervalStartUTC: start,
      intervalEndUTC: end,
      source: source,
      sampleCount: source == .raw ? 1 : 12,
      continuitySegment: 0,
      userPercent: 30,
      systemPercent: 15,
      nicePercent: 5,
      idlePercent: 50,
      utilizationPercent: 50
    )
  }

  private func logicalPoint(
    start: Date,
    end: Date,
    source: MemoryHistoryPointSource
  ) -> LogicalCPUHistoryPoint {
    LogicalCPUHistoryPoint(
      topology: LogicalCPUTopology(
        epochKey: "selection-8",
        bootSessionStartUTC: start.addingTimeInterval(-1_000),
        logicalCPUCount: 8
      ),
      cpuIndex: 0,
      timestampUTC: source == .raw ? end : start,
      intervalStartUTC: start,
      intervalEndUTC: end,
      source: source,
      sampleCount: source == .raw ? 1 : 12,
      continuitySegment: 0,
      userPercent: 30,
      systemPercent: 15,
      nicePercent: 5,
      idlePercent: 50,
      utilizationPercent: 50
    )
  }

  private func sample(at date: Date, usedBytes: UInt64) -> MemorySample {
    MemorySample(
      timestampUTC: date,
      systemUptimeSeconds: 1_000,
      physicalMemoryBytes: 16_000_000_000,
      estimatedMemoryUsedBytes: usedBytes,
      wiredBytes: 2_000_000_000,
      compressedBytes: 1_000_000_000,
      estimatedCachedFilesBytes: 3_000_000_000,
      swapUsedBytes: 0,
      pageSizeBytes: 4_096,
      rawPageCounts: RawMemoryPageCounts(
        free: 1,
        active: 1,
        inactive: 1,
        wired: 1,
        speculative: 0,
        purgeable: 0,
        compressor: 1,
        external: 1,
        internalPages: 2
      ),
      calculationVersion: MemoryMetricsCalculator.calculationVersion,
      acquisitionQuality: .firstPass,
      acquisitionAttemptCount: 1
    )
  }

  private func memoryGap(attemptCount: Int) -> MemorySamplingGap {
    MemorySamplingGap(
      timestampUTC: Date(timeIntervalSince1970: 10_000),
      systemUptimeSeconds: 1_000,
      acquisitionAttemptCount: attemptCount,
      lastInconsistency: MemoryCounterInconsistency(
        reason: .classifiedExceedsEstimatedUsed,
        physicalMemoryBytes: 16_000_000_000,
        pageSizeBytes: 4_096,
        counters: RawMemoryPageCounts(
          free: 1,
          active: 1,
          inactive: 1,
          wired: 1,
          speculative: 0,
          purgeable: 0,
          compressor: 1,
          external: 1,
          internalPages: 2
        ),
        estimatedMemoryUsedBytes: 8_000_000_000,
        classifiedMemoryUsedBytes: 8_000_004_096,
        excessBytes: 4_096
      )
    )
  }
}
