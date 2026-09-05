import Foundation
import MemoryWatcherCore

enum AuditCheckpointPrecision {
  static func restoringHistoryMarker(
    in checkpoint: MemoryRunAuditCheckpoint,
    sampleTimestamps: [Date]
  ) -> MemoryRunAuditCheckpoint {
    guard let marker = checkpoint.historyMarkerUTC else {
      return checkpoint
    }
    guard
      let restoredMarker = sampleTimestamps.min(by: {
        abs($0.timeIntervalSince(marker)) < abs($1.timeIntervalSince(marker))
      }),
      abs(restoredMarker.timeIntervalSince(marker)) < 1
    else {
      return checkpoint
    }
    return MemoryRunAuditCheckpoint(
      schemaVersion: checkpoint.schemaVersion,
      createdAtUTC: checkpoint.createdAtUTC,
      auditStartUTC: checkpoint.auditStartUTC,
      requiredEndUTC: checkpoint.requiredEndUTC,
      initialSampleCount: checkpoint.initialSampleCount,
      historyMarkerUTC: restoredMarker,
      initialIntegrityCheck: checkpoint.initialIntegrityCheck
    )
  }
}
