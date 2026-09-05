import Foundation
import MemoryWatcherCore
import XCTest

@testable import MemoryWatcherAudit

final class AuditCheckpointPrecisionTests: XCTestCase {
  func testRestoresFractionalMarkerLostByISO8601CheckpointEncoding() throws {
    let exactMarker = Date(timeIntervalSince1970: 4_000_000.5)
    let checkpoint = try roundTrip(
      MemoryRunAuditCheckpoint(
        createdAtUTC: exactMarker,
        auditStartUTC: exactMarker.addingTimeInterval(60),
        requiredEndUTC: exactMarker.addingTimeInterval(86_460),
        initialSampleCount: 1,
        historyMarkerUTC: exactMarker,
        initialIntegrityCheck: "ok"
      )
    )

    XCTAssertNotEqual(checkpoint.historyMarkerUTC, exactMarker)
    let restored = AuditCheckpointPrecision.restoringHistoryMarker(
      in: checkpoint,
      sampleTimestamps: [exactMarker]
    )

    XCTAssertEqual(restored.historyMarkerUTC, exactMarker)
  }

  func testDoesNotReplaceMarkerWithSampleOneSecondAway() {
    let marker = Date(timeIntervalSince1970: 4_000_000)
    let checkpoint = MemoryRunAuditCheckpoint(
      createdAtUTC: marker,
      auditStartUTC: marker.addingTimeInterval(60),
      requiredEndUTC: marker.addingTimeInterval(86_460),
      initialSampleCount: 1,
      historyMarkerUTC: marker,
      initialIntegrityCheck: "ok"
    )

    let restored = AuditCheckpointPrecision.restoringHistoryMarker(
      in: checkpoint,
      sampleTimestamps: [marker.addingTimeInterval(1)]
    )

    XCTAssertEqual(restored, checkpoint)
  }

  private func roundTrip(
    _ checkpoint: MemoryRunAuditCheckpoint
  ) throws -> MemoryRunAuditCheckpoint {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
      MemoryRunAuditCheckpoint.self,
      from: encoder.encode(checkpoint)
    )
  }
}
