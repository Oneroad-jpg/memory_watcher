import Foundation

public enum DashboardFinalAuditPolicy {
  public static let warmUpSeconds: TimeInterval = 60
  public static let phaseDurationSeconds: TimeInterval = 30 * 60
  public static let checkpointIntervalSeconds: TimeInterval = 5 * 60
  public static let minimumRecordedSlots = 350
  public static let expectedVisibleHistoryReloads: UInt64 = 6

  public static var checkpointMinutes: [Int] {
    stride(
      from: 0,
      through: Int(phaseDurationSeconds / 60),
      by: Int(checkpointIntervalSeconds / 60)
    ).map { $0 }
  }

  public static func phaseRecordCount(
    timestamps: [Date],
    from startUTC: Date,
    through endUTC: Date
  ) -> Int {
    timestamps.filter { $0 >= startUTC && $0 <= endUTC }.count
  }
}
