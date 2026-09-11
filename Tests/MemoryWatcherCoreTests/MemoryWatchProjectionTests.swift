import Foundation
import XCTest
@testable import MemoryWatcherCore
import MemoryWatcherShared

final class MemoryWatchProjectionTests: XCTestCase {
  func testProjectionPreservesMeasuredValuesAndPressure() {
    let sample = MemorySample(
      timestampUTC: Date(timeIntervalSince1970: 100),
      systemUptimeSeconds: 90,
      physicalMemoryBytes: 16_000,
      estimatedMemoryUsedBytes: 12_000,
      wiredBytes: 2_000,
      compressedBytes: 1_000,
      estimatedCachedFilesBytes: 500,
      swapUsedBytes: 200,
      pageSizeBytes: 4_096,
      rawPageCounts: RawMemoryPageCounts(
        free: 1,
        active: 1,
        inactive: 1,
        wired: 1,
        speculative: 1,
        purgeable: 1,
        compressor: 1,
        external: 1,
        internalPages: 2
      ),
      calculationVersion: "test-v1",
      acquisitionQuality: .firstPass,
      acquisitionAttemptCount: 1
    )

    let observation = MemoryWatchProjection.observation(
      sample: sample,
      pressure: .warning
    )

    XCTAssertEqual(observation.capturedAtUTC, sample.timestampUTC)
    XCTAssertEqual(observation.physicalMemoryBytes, 16_000)
    XCTAssertEqual(observation.estimatedMemoryUsedBytes, 12_000)
    XCTAssertEqual(observation.swapUsedBytes, 200)
    XCTAssertEqual(observation.pressure, .warning)
    XCTAssertEqual(observation.calculationVersion, "test-v1")
  }
}
