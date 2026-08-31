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
      physicalMemoryBytes: 220 * 4_096,
      pageSizeBytes: 4_096,
      counters: counters
    )

    XCTAssertEqual(metrics.estimatedApplicationMemoryBytes, 90 * 4_096)
    XCTAssertEqual(metrics.estimatedMemoryUsedBytes, 130 * 4_096)
    XCTAssertEqual(metrics.unclassifiedMemoryUsedBytes, 15 * 4_096)
    XCTAssertEqual(metrics.wiredBytes, 20 * 4_096)
    XCTAssertEqual(metrics.compressedBytes, 5 * 4_096)
    XCTAssertEqual(metrics.estimatedCachedFilesBytes, 40 * 4_096)
    XCTAssertEqual(MemoryMetricsCalculator.calculationVersion, "phase-03-v2")
  }

  func testMetricCalculationIdentifiesInvalidCounterRelationship() {
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
      guard
        case .inconsistentSnapshot(let diagnostic) =
          error as? MemorySamplingError
      else {
        return XCTFail("Expected an inconsistent snapshot diagnostic")
      }
      XCTAssertEqual(diagnostic.reason, .internalPagesBelowPurgeable)
      XCTAssertEqual(diagnostic.excessBytes, 4_096)
    }
  }

  func testSamplerMarksFirstValidSnapshotAsFirstPass() throws {
    let sequence = SnapshotSequence([Self.validSnapshot()])
    let sampler = SystemMemorySampler(
      snapshotProvider: { try sequence.next() },
      sleep: { _ in }
    )

    let sample = try sampler.sample()

    XCTAssertEqual(sample.acquisitionQuality, .firstPass)
    XCTAssertEqual(sample.acquisitionAttemptCount, 1)
    XCTAssertEqual(sequence.callCount, 1)
  }

  func testSamplerRetriesOneInconsistentSnapshotWithoutClamping() throws {
    let inconsistent = Self.inconsistentSnapshot(excessPages: 30)
    let sequence = SnapshotSequence([inconsistent, Self.validSnapshot()])
    let sampler = SystemMemorySampler(
      snapshotProvider: { try sequence.next() },
      sleep: { _ in }
    )

    let sample = try sampler.sample()

    XCTAssertEqual(sample.acquisitionQuality, .retried)
    XCTAssertEqual(sample.acquisitionAttemptCount, 2)
    XCTAssertEqual(sequence.callCount, 2)
    XCTAssertEqual(sample.estimatedMemoryUsedBytes, 130 * 4_096)
  }

  func testSamplerRejectsPersistentInconsistencyAfterBoundedRetries() {
    let sequence = SnapshotSequence(
      Array(repeating: Self.inconsistentSnapshot(excessPages: 30), count: 3)
    )
    let sampler = SystemMemorySampler(
      snapshotProvider: { try sequence.next() },
      sleep: { _ in }
    )

    XCTAssertThrowsError(try sampler.sample()) { error in
      guard
        case .samplingAttemptsExhausted(let gap) =
          error as? MemorySamplingError
      else {
        return XCTFail("Expected an explicit sampling gap")
      }
      XCTAssertEqual(gap.acquisitionAttemptCount, 3)
      XCTAssertEqual(
        gap.lastInconsistency.reason,
        .classifiedExceedsEstimatedUsed
      )
      XCTAssertEqual(gap.lastInconsistency.excessBytes, 30 * 4_096)
    }
    XCTAssertEqual(sequence.callCount, 3)
  }

  func testSamplerReturnsGapOutcomeInsteadOfFabricatedSample() throws {
    let sequence = SnapshotSequence(
      Array(repeating: Self.inconsistentSnapshot(excessPages: 30), count: 3)
    )
    let sampler = SystemMemorySampler(
      snapshotProvider: { try sequence.next() },
      sleep: { _ in }
    )

    let outcome = try sampler.sampleOutcome()

    guard case .gap(let gap) = outcome else {
      return XCTFail("Expected a gap instead of a fabricated sample")
    }
    XCTAssertEqual(gap.acquisitionAttemptCount, 3)
    XCTAssertEqual(gap.timestampUTC, Date(timeIntervalSince1970: 1_001))
    XCTAssertEqual(sequence.callCount, 3)
  }

  func testLiveSystemOutcomeIsWithinDocumentedBounds() throws {
    switch try SystemMemorySampler().sampleOutcome() {
    case .sample(let sample):
      try MemorySampleValidator.validate(sample)
      XCTAssertGreaterThan(sample.timestampUTC.timeIntervalSince1970, 0)
      XCTAssertGreaterThan(sample.systemUptimeSeconds, 0)
      XCTAssertGreaterThan(sample.physicalMemoryBytes, 0)
      XCTAssertGreaterThan(sample.pageSizeBytes, 0)
      XCTAssertLessThanOrEqual(
        sample.estimatedMemoryUsedBytes,
        sample.physicalMemoryBytes
      )
      XCTAssertLessThanOrEqual(sample.wiredBytes, sample.physicalMemoryBytes)
      XCTAssertLessThanOrEqual(
        sample.compressedBytes,
        sample.physicalMemoryBytes
      )
      XCTAssertLessThanOrEqual(
        sample.estimatedCachedFilesBytes,
        sample.physicalMemoryBytes
      )
    case .gap(let gap):
      XCTAssertGreaterThan(gap.timestampUTC.timeIntervalSince1970, 0)
      XCTAssertGreaterThan(gap.systemUptimeSeconds, 0)
      XCTAssertEqual(
        gap.acquisitionAttemptCount,
        MemorySamplingRetryPolicy.phase03.maximumAttempts
      )
      XCTAssertGreaterThan(gap.lastInconsistency.physicalMemoryBytes, 0)
      XCTAssertGreaterThan(gap.lastInconsistency.pageSizeBytes, 0)
      XCTAssertGreaterThan(gap.lastInconsistency.excessBytes, 0)
    }
  }

  func testMetricCatalogDistinguishesReportedAndEstimatedValues() {
    XCTAssertEqual(
      MemoryMetricCatalog.physicalMemory.certainty,
      .systemReported
    )
    XCTAssertEqual(
      MemoryMetricCatalog.estimatedMemoryUsed.displayName,
      "使用量（推定）"
    )
    XCTAssertEqual(
      MemoryMetricCatalog.estimatedMemoryUsed.certainty,
      .derivedEstimate
    )
    XCTAssertEqual(
      MemoryMetricCatalog.estimatedCachedFiles.displayName,
      "キャッシュ相当"
    )
    XCTAssertEqual(
      MemoryMetricCatalog.estimatedCachedFiles.certainty,
      .derivedEstimate
    )
    XCTAssertEqual(MemoryMetricCatalog.wiredMemory.certainty, .systemReported)
    XCTAssertEqual(
      MemoryMetricCatalog.compressedMemory.certainty,
      .systemReported
    )
    XCTAssertEqual(MemoryMetricCatalog.swapUsed.certainty, .systemReported)
  }

  private static func validSnapshot() -> MemoryCounterSnapshot {
    MemoryCounterSnapshot(
      timestampUTC: Date(timeIntervalSince1970: 1_000),
      systemUptimeSeconds: 500,
      physicalMemoryBytes: 220 * 4_096,
      pageSizeBytes: 4_096,
      counters: RawMemoryPageCounts(
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
      swapUsedBytes: 8 * 4_096
    )
  }

  private static func inconsistentSnapshot(
    excessPages: UInt64
  ) -> MemoryCounterSnapshot {
    let usedPages: UInt64 = 70
    let applicationPages: UInt64 = 60
    let wiredPages: UInt64 = 20
    let compressorPages = usedPages + excessPages - applicationPages - wiredPages
    return MemoryCounterSnapshot(
      timestampUTC: Date(timeIntervalSince1970: 1_001),
      systemUptimeSeconds: 501,
      physicalMemoryBytes: 100 * 4_096,
      pageSizeBytes: 4_096,
      counters: RawMemoryPageCounts(
        free: 20,
        active: 20,
        inactive: 10,
        wired: wiredPages,
        speculative: 0,
        purgeable: 0,
        compressor: compressorPages,
        external: 10,
        internalPages: applicationPages
      ),
      swapUsedBytes: 8 * 4_096
    )
  }
}

private final class SnapshotSequence: @unchecked Sendable {
  private let lock = NSLock()
  private let snapshots: [MemoryCounterSnapshot]
  private var index = 0

  init(_ snapshots: [MemoryCounterSnapshot]) {
    self.snapshots = snapshots
  }

  var callCount: Int {
    lock.withLock { index }
  }

  func next() throws -> MemoryCounterSnapshot {
    try lock.withLock {
      guard index < snapshots.count else {
        throw MemorySamplingError.invalidSample
      }
      defer { index += 1 }
      return snapshots[index]
    }
  }
}
