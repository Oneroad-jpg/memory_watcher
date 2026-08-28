import Foundation
import XCTest

@testable import MemoryWatcherCore

final class MemorySamplingTests: XCTestCase {
  func testMetricCalculationUsesVersionedPageFormula() throws {
    let counters = RawMemoryPageCounts(
      free: 50,
      active: 40,
      inactive: 30,
      wired: 20,
      speculative: 5,
      purgeable: 10,
      compressor: 5,
      external: 30,
      internalPages: 100
    )

    let metrics = try MemoryMetricsCalculator.calculate(
      physicalMemoryBytes: 1_000_000,
      pageSizeBytes: 4_096,
      counters: counters
    )

    XCTAssertEqual(metrics.memoryUsedBytes, 115 * 4_096)
    XCTAssertEqual(metrics.wiredBytes, 20 * 4_096)
    XCTAssertEqual(metrics.compressedBytes, 5 * 4_096)
    XCTAssertEqual(metrics.cachedBytes, 40 * 4_096)
    XCTAssertEqual(MemoryMetricsCalculator.calculationVersion, "phase-02-v1")
  }

  func testMetricCalculationRejectsInvalidCounterRelationship() {
    let counters = RawMemoryPageCounts(
      free: 0,
      active: 0,
      inactive: 0,
      wired: 0,
      speculative: 0,
      purgeable: 2,
      compressor: 0,
      external: 0,
      internalPages: 1
    )

    XCTAssertThrowsError(
      try MemoryMetricsCalculator.calculate(
        physicalMemoryBytes: 1_000_000,
        pageSizeBytes: 4_096,
        counters: counters
      )
    ) { error in
      XCTAssertEqual(
        error as? MemorySamplingError,
        .invalidCounterRelationship
      )
    }
  }

  func testLiveSystemSampleIsWithinPhysicalBounds() throws {
    let sample = try SystemMemorySampler().sample()

    try MemorySampleValidator.validate(sample)
    XCTAssertGreaterThan(sample.timestampUTC.timeIntervalSince1970, 0)
    XCTAssertGreaterThan(sample.systemUptimeSeconds, 0)
    XCTAssertGreaterThan(sample.physicalMemoryBytes, 0)
    XCTAssertGreaterThan(sample.pageSizeBytes, 0)
    XCTAssertLessThanOrEqual(
      sample.memoryUsedBytes,
      sample.physicalMemoryBytes
    )
    XCTAssertLessThanOrEqual(sample.wiredBytes, sample.physicalMemoryBytes)
    XCTAssertLessThanOrEqual(
      sample.compressedBytes,
      sample.physicalMemoryBytes
    )
    XCTAssertLessThanOrEqual(sample.cachedBytes, sample.physicalMemoryBytes)
  }
}
