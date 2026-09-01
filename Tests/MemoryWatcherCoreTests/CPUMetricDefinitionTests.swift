import XCTest

@testable import MemoryWatcherCore

final class CPUMetricDefinitionTests: XCTestCase {
  func testContractFixesSamplingIntervalAndFormulaVersion() {
    XCTAssertEqual(CPUUtilizationCalculator.calculationVersion, "phase-13-v1")
    XCTAssertEqual(CPUUtilizationCalculator.targetSamplingIntervalSeconds, 5)
    XCTAssertEqual(CPUUtilizationCalculator.minimumContinuousIntervalSeconds, 1)
    XCTAssertEqual(CPUUtilizationCalculator.maximumContinuousIntervalSeconds, 15)
  }

  func testFirstObservationIsUnknown() {
    XCTAssertEqual(
      CPUUtilizationCalculator.calculate(
        previous: nil,
        current: Self.snapshot(user: 10, system: 20, idle: 70, nice: 0)
      ),
      .unknown(.firstDeltaUnknown)
    )
  }

  func testFormulaUsesCounterDeltasAndCountsNiceAsBusy() throws {
    let result = CPUUtilizationCalculator.calculate(
      previous: Self.snapshot(user: 100, system: 100, idle: 800, nice: 0),
      current: Self.snapshot(user: 140, system: 120, idle: 900, nice: 40)
    )

    let delta = try XCTUnwrap(result.measurement)
    XCTAssertEqual(delta.userTicks, 40)
    XCTAssertEqual(delta.systemTicks, 20)
    XCTAssertEqual(delta.niceTicks, 40)
    XCTAssertEqual(delta.idleTicks, 100)
    XCTAssertEqual(delta.busyTicks, 100)
    XCTAssertEqual(delta.totalTicks, 200)
    XCTAssertEqual(delta.userPercent, 20, accuracy: 0.000_001)
    XCTAssertEqual(delta.systemPercent, 10, accuracy: 0.000_001)
    XCTAssertEqual(delta.nicePercent, 20, accuracy: 0.000_001)
    XCTAssertEqual(delta.idlePercent, 50, accuracy: 0.000_001)
    XCTAssertEqual(delta.utilizationPercent, 50, accuracy: 0.000_001)
  }

  func testFormulaDistinguishesZeroAndFullUtilization() throws {
    let previous = Self.snapshot(user: 10, system: 10, idle: 10, nice: 10)
    let idleOnly = CPUUtilizationCalculator.calculate(
      previous: previous,
      current: Self.snapshot(user: 10, system: 10, idle: 110, nice: 10)
    )
    let busyOnly = CPUUtilizationCalculator.calculate(
      previous: previous,
      current: Self.snapshot(user: 60, system: 40, idle: 10, nice: 20)
    )

    XCTAssertEqual(
      try XCTUnwrap(idleOnly.measurement).utilizationPercent,
      0,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      try XCTUnwrap(busyOnly.measurement).utilizationPercent,
      100,
      accuracy: 0.000_001
    )
  }

  func testTotalFormulaUsesSummedTicksInsteadOfMeanOfCPUPercentages() throws {
    let result = CPUUtilizationCalculator.calculate(
      previous: Self.snapshot(user: 0, system: 0, idle: 0, nice: 0),
      current: Self.snapshot(user: 100, system: 0, idle: 300, nice: 0)
    )

    XCTAssertEqual(
      try XCTUnwrap(result.measurement).utilizationPercent,
      25,
      accuracy: 0.000_001
    )
  }

  func testCounterRegressionAndNoProgressRemainUnknown() {
    let previous = Self.snapshot(user: 10, system: 20, idle: 30, nice: 40)

    XCTAssertEqual(
      CPUUtilizationCalculator.calculate(
        previous: previous,
        current: Self.snapshot(user: 9, system: 20, idle: 30, nice: 40)
      ),
      .unknown(.counterRegression)
    )
    XCTAssertEqual(
      CPUUtilizationCalculator.calculate(previous: previous, current: previous),
      .unknown(.noTickProgress)
    )
  }

  func testEveryDiscontinuityProducesItsExplicitUnknownQuality() {
    let previous = Self.snapshot(user: 10, system: 20, idle: 30, nice: 40)
    let current = Self.snapshot(user: 20, system: 30, idle: 40, nice: 50)
    let cases: [(CPUIntervalContinuity, CPUUtilizationQuality)] = [
      (.sleep, .sleepBoundary),
      (.wake, .wakeBoundary),
      (.reboot, .rebootBoundary),
      (.clockChange, .clockChangeBoundary),
      (.topologyChange, .topologyChangeBoundary),
      (.unavailable, .unavailable),
    ]

    for (continuity, quality) in cases {
      XCTAssertEqual(
        CPUUtilizationCalculator.calculate(
          previous: previous,
          current: current,
          continuity: continuity
        ),
        .unknown(quality)
      )
    }
  }

  func testArithmeticOverflowDoesNotProduceClampedPercent() {
    let result = CPUUtilizationCalculator.calculate(
      previous: Self.snapshot(user: 0, system: 0, idle: 0, nice: 0),
      current: Self.snapshot(user: .max, system: 1, idle: 0, nice: 0)
    )

    XCTAssertEqual(result, .unknown(.arithmeticOverflow))
  }

  private static func snapshot(
    user: UInt64,
    system: UInt64,
    idle: UInt64,
    nice: UInt64
  ) -> CPUCounterSnapshot {
    CPUCounterSnapshot(
      userTicks: user,
      systemTicks: system,
      idleTicks: idle,
      niceTicks: nice
    )
  }
}

extension CPUCounterDeltaResult {
  fileprivate var measurement: CPUCounterDelta? {
    guard case .measured(let measurement) = self else { return nil }
    return measurement
  }
}
