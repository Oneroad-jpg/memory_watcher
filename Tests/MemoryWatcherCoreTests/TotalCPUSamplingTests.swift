import Foundation
import XCTest

@testable import MemoryWatcherCore

final class TotalCPUSamplingTests: XCTestCase {
  func testFirstObservationIsUnknownThenFiveSecondDeltaIsMeasured() throws {
    let sequence = CPUObservationSequence([
      .success(Self.observation(timestamp: 1_000, uptime: 500, total: 100)),
      .success(Self.observation(timestamp: 1_005, uptime: 505, total: 200)),
    ])
    let sampler = Self.sampler(sequence: sequence)

    let first = sampler.sample()
    let second = sampler.sample()

    XCTAssertEqual(first.quality, .firstDeltaUnknown)
    XCTAssertNil(first.delta)
    XCTAssertEqual(second.quality, .measured)
    XCTAssertEqual(second.intervalStartUTC, Date(timeIntervalSince1970: 1_000))
    XCTAssertEqual(second.intervalEndUTC, Date(timeIntervalSince1970: 1_005))
    XCTAssertEqual(second.delta?.userTicks, 25)
    XCTAssertEqual(second.delta?.systemTicks, 25)
    XCTAssertEqual(second.delta?.idleTicks, 50)
    XCTAssertEqual(second.utilizationPercent ?? -1, 50, accuracy: 0.000_001)
    XCTAssertNoThrow(try TotalCPUSampleValidator.validate(second))
  }

  func testOutOfRangeIntervalAndClockChangeRemainUnknown() {
    let intervalSequence = CPUObservationSequence([
      .success(Self.observation(timestamp: 2_000, uptime: 1_000, total: 100)),
      .success(Self.observation(timestamp: 2_020, uptime: 1_020, total: 200)),
    ])
    let intervalSampler = Self.sampler(sequence: intervalSequence)
    _ = intervalSampler.sample()
    XCTAssertEqual(intervalSampler.sample().quality, .intervalOutOfRange)

    let clockSequence = CPUObservationSequence([
      .success(Self.observation(timestamp: 3_000, uptime: 2_000, total: 100)),
      .success(Self.observation(timestamp: 3_065, uptime: 2_005, total: 200)),
    ])
    let clockSampler = Self.sampler(sequence: clockSequence)
    _ = clockSampler.sample()
    XCTAssertEqual(clockSampler.sample().quality, .clockChangeBoundary)
  }

  func testResetEmitsRequestedUnknownBeforeResumingMeasurement() {
    let sequence = CPUObservationSequence([
      .success(Self.observation(timestamp: 4_000, uptime: 3_000, total: 100)),
      .success(Self.observation(timestamp: 4_005, uptime: 3_005, total: 200)),
      .success(Self.observation(timestamp: 4_010, uptime: 3_010, total: 300)),
    ])
    let sampler = Self.sampler(sequence: sequence)

    XCTAssertEqual(sampler.sample().quality, .firstDeltaUnknown)
    sampler.reset(for: .wake)
    XCTAssertEqual(sampler.sample().quality, .wakeBoundary)
    XCTAssertEqual(sampler.sample().quality, .measured)
  }

  func testProviderFailureIsUnavailableAndBreaksTheDeltaChain() {
    let fallbackTimestamp = Date(timeIntervalSince1970: 5_005)
    let sequence = CPUObservationSequence([
      .success(Self.observation(timestamp: 5_000, uptime: 4_000, total: 100)),
      .failure(.unavailable),
      .success(Self.observation(timestamp: 5_010, uptime: 4_010, total: 300)),
    ])
    let sampler = SystemTotalCPUSampler(
      observationProvider: { try sequence.next() },
      timestampProvider: { fallbackTimestamp },
      uptimeProvider: { 4_005 }
    )

    XCTAssertEqual(sampler.sample().quality, .firstDeltaUnknown)
    let unavailable = sampler.sample()
    XCTAssertEqual(unavailable.quality, .unavailable)
    XCTAssertEqual(unavailable.intervalEndUTC, fallbackTimestamp)
    XCTAssertNil(unavailable.delta)
    XCTAssertEqual(sampler.sample().quality, .firstDeltaUnknown)
  }

  func testLiveHostStatisticsProducesARealFirstObservation() throws {
    let sample = SystemTotalCPUSampler().sample()

    XCTAssertEqual(sample.quality, .firstDeltaUnknown)
    XCTAssertGreaterThan(sample.intervalEndUTC.timeIntervalSince1970, 0)
    XCTAssertGreaterThan(sample.intervalEndUptimeSeconds, 0)
    XCTAssertNoThrow(try TotalCPUSampleValidator.validate(sample))
  }

  private static func sampler(
    sequence: CPUObservationSequence
  ) -> SystemTotalCPUSampler {
    SystemTotalCPUSampler(
      observationProvider: { try sequence.next() },
      timestampProvider: { Date(timeIntervalSince1970: 1) },
      uptimeProvider: { 1 }
    )
  }

  private static func observation(
    timestamp: TimeInterval,
    uptime: TimeInterval,
    total: UInt64
  ) -> TotalCPUCounterObservation {
    TotalCPUCounterObservation(
      timestampUTC: Date(timeIntervalSince1970: timestamp),
      systemUptimeSeconds: uptime,
      counters: CPUCounterSnapshot(
        userTicks: total / 4,
        systemTicks: total / 4,
        idleTicks: total / 2,
        niceTicks: 0
      )
    )
  }
}

private enum CPUObservationTestError: Error {
  case unavailable
  case exhausted
}

private final class CPUObservationSequence: @unchecked Sendable {
  private let lock = NSLock()
  private let outcomes: [Result<TotalCPUCounterObservation, CPUObservationTestError>]
  private var index = 0

  init(
    _ outcomes: [Result<TotalCPUCounterObservation, CPUObservationTestError>]
  ) {
    self.outcomes = outcomes
  }

  func next() throws -> TotalCPUCounterObservation {
    try lock.withLock {
      guard index < outcomes.count else {
        throw CPUObservationTestError.exhausted
      }
      defer { index += 1 }
      return try outcomes[index].get()
    }
  }
}
