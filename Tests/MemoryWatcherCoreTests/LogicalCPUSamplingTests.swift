import Foundation
import XCTest

@testable import MemoryWatcherCore

final class LogicalCPUSamplingTests: XCTestCase {
  func testOneEightSixteenAndThirtyTwoCPUFixturesPreserveEveryIndex() throws {
    for count in [1, 8, 16, 32] {
      let sequence = LogicalCPUObservationSequence([
        .success(Self.observation(timestamp: 1_000, uptime: 500, count: count, total: 100)),
        .success(Self.observation(timestamp: 1_005, uptime: 505, count: count, total: 200)),
      ])
      let sampler = Self.sampler(sequence: sequence)

      let first = try Self.samples(from: sampler.sample())
      let measured = try Self.samples(from: sampler.sample())

      XCTAssertEqual(first.count, count)
      XCTAssertEqual(first.map(\.cpuIndex), Array(0..<count))
      XCTAssertEqual(Set(first.map(\.quality)), [.firstDeltaUnknown])
      XCTAssertEqual(measured.count, count)
      XCTAssertEqual(measured.map(\.cpuIndex), Array(0..<count))
      XCTAssertEqual(Set(measured.map(\.quality)), [.measured])
      XCTAssertTrue(
        measured.allSatisfy {
          abs(($0.utilizationPercent ?? -1) - 50) < 0.000_001
        }
      )
      XCTAssertNoThrow(try LogicalCPUSampleValidator.validate(batch: measured))
    }
  }

  func testTopologyChangeStartsANewExplicitUnknownEpoch() throws {
    let sequence = LogicalCPUObservationSequence([
      .success(Self.observation(timestamp: 2_000, uptime: 1_000, count: 8, total: 100)),
      .success(Self.observation(timestamp: 2_005, uptime: 1_005, count: 16, total: 200)),
      .success(Self.observation(timestamp: 2_010, uptime: 1_010, count: 16, total: 300)),
    ])
    let sampler = Self.sampler(sequence: sequence)

    _ = sampler.sample()
    let boundary = try Self.samples(from: sampler.sample())
    let measured = try Self.samples(from: sampler.sample())

    XCTAssertEqual(boundary.count, 16)
    XCTAssertEqual(Set(boundary.map(\.quality)), [.topologyChangeBoundary])
    XCTAssertTrue(boundary.allSatisfy { $0.delta == nil })
    XCTAssertEqual(Set(measured.map(\.quality)), [.measured])
  }

  func testRebootResetCreatesExplicitUnknownBeforeMeasurementResumes() throws {
    let sequence = LogicalCPUObservationSequence([
      .success(Self.observation(timestamp: 3_000, uptime: 2_000, count: 8, total: 100)),
      .success(Self.observation(timestamp: 3_005, uptime: 5, count: 8, total: 200)),
      .success(Self.observation(timestamp: 3_010, uptime: 10, count: 8, total: 300)),
    ])
    let sampler = Self.sampler(sequence: sequence)

    _ = sampler.sample()
    sampler.reset(for: .reboot)
    XCTAssertEqual(
      Set(try Self.samples(from: sampler.sample()).map(\.quality)),
      [.rebootBoundary]
    )
    XCTAssertEqual(
      Set(try Self.samples(from: sampler.sample()).map(\.quality)),
      [.measured]
    )
  }

  func testUnavailableProducesOneGapAndNoFabricatedCPUValues() throws {
    let fallback = Date(timeIntervalSince1970: 4_005)
    let sequence = LogicalCPUObservationSequence([
      .success(Self.observation(timestamp: 4_000, uptime: 3_000, count: 8, total: 100)),
      .failure(.unavailable),
      .success(Self.observation(timestamp: 4_010, uptime: 3_010, count: 8, total: 300)),
    ])
    let sampler = SystemLogicalCPUSampler(
      observationProvider: { try sequence.next() },
      timestampProvider: { fallback },
      uptimeProvider: { 3_005 }
    )

    let first = try Self.samples(from: sampler.sample())
    XCTAssertEqual(first.count, 8)
    guard case .gap(let gap) = sampler.sample() else {
      return XCTFail("expected a gap instead of fabricated per-CPU values")
    }
    XCTAssertEqual(gap.timestampUTC, fallback)
    XCTAssertEqual(gap.quality, .unavailable)
    XCTAssertEqual(gap.previousTopology?.logicalCPUCount, 8)
    XCTAssertNoThrow(try LogicalCPUSampleValidator.validate(gap))
    XCTAssertEqual(
      Set(try Self.samples(from: sampler.sample()).map(\.quality)),
      [.firstDeltaUnknown]
    )
  }

  func testOneCounterRegressionDoesNotClampOrInvalidateOtherCPUs() throws {
    let topology = Self.topology(count: 2)
    let sequence = LogicalCPUObservationSequence([
      .success(
        LogicalCPUCounterObservation(
          timestampUTC: Date(timeIntervalSince1970: 5_000),
          systemUptimeSeconds: 4_000,
          topology: topology,
          countersByCPUIndex: [Self.counter(total: 100), Self.counter(total: 100)]
        )
      ),
      .success(
        LogicalCPUCounterObservation(
          timestampUTC: Date(timeIntervalSince1970: 5_005),
          systemUptimeSeconds: 4_005,
          topology: topology,
          countersByCPUIndex: [Self.counter(total: 50), Self.counter(total: 200)]
        )
      ),
    ])
    let sampler = Self.sampler(sequence: sequence)

    _ = sampler.sample()
    let samples = try Self.samples(from: sampler.sample())

    XCTAssertEqual(samples[0].quality, .counterRegression)
    XCTAssertNil(samples[0].delta)
    XCTAssertEqual(samples[1].quality, .measured)
    XCTAssertEqual(samples[1].utilizationPercent ?? -1, 50, accuracy: 0.000_001)
  }

  func testLiveHostProcessorInfoReturnsEveryLogicalCPUIndex() throws {
    let outcome = SystemLogicalCPUSampler().sample()
    let samples = try Self.samples(from: outcome)

    XCTAssertGreaterThan(samples.count, 0)
    XCTAssertEqual(samples.map(\.cpuIndex), Array(0..<samples.count))
    XCTAssertEqual(Set(samples.map(\.quality)), [.firstDeltaUnknown])
    XCTAssertNoThrow(try LogicalCPUSampleValidator.validate(batch: samples))
  }

  private static func sampler(
    sequence: LogicalCPUObservationSequence
  ) -> SystemLogicalCPUSampler {
    SystemLogicalCPUSampler(
      observationProvider: { try sequence.next() },
      timestampProvider: { Date(timeIntervalSince1970: 1) },
      uptimeProvider: { 1 }
    )
  }

  private static func samples(
    from outcome: LogicalCPUSamplingOutcome
  ) throws -> [LogicalCPUSample] {
    guard case .samples(let samples) = outcome else {
      throw LogicalCPUObservationTestError.unavailable
    }
    return samples
  }

  private static func topology(count: Int) -> LogicalCPUTopology {
    LogicalCPUTopology(
      epochKey: "boot-100-logical-\(count)",
      bootSessionStartUTC: Date(timeIntervalSince1970: 100),
      logicalCPUCount: count
    )
  }

  private static func observation(
    timestamp: TimeInterval,
    uptime: TimeInterval,
    count: Int,
    total: UInt64
  ) -> LogicalCPUCounterObservation {
    LogicalCPUCounterObservation(
      timestampUTC: Date(timeIntervalSince1970: timestamp),
      systemUptimeSeconds: uptime,
      topology: topology(count: count),
      countersByCPUIndex: Array(repeating: counter(total: total), count: count)
    )
  }

  private static func counter(total: UInt64) -> CPUCounterSnapshot {
    CPUCounterSnapshot(
      userTicks: total / 4,
      systemTicks: total / 4,
      idleTicks: total / 2,
      niceTicks: 0
    )
  }
}

private enum LogicalCPUObservationTestError: Error {
  case unavailable
  case exhausted
}

private final class LogicalCPUObservationSequence: @unchecked Sendable {
  private let lock = NSLock()
  private let outcomes: [Result<LogicalCPUCounterObservation, LogicalCPUObservationTestError>]
  private var index = 0

  init(
    _ outcomes:
      [Result<LogicalCPUCounterObservation, LogicalCPUObservationTestError>]
  ) {
    self.outcomes = outcomes
  }

  func next() throws -> LogicalCPUCounterObservation {
    try lock.withLock {
      guard index < outcomes.count else {
        throw LogicalCPUObservationTestError.exhausted
      }
      defer { index += 1 }
      return try outcomes[index].get()
    }
  }
}
