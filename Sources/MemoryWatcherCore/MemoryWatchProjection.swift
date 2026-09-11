import Foundation
import MemoryWatcherShared

public enum MemoryWatchProjection {
  public static func observation(
    sample: MemorySample,
    pressure: MemoryPressureLevel
  ) -> MemoryWatchResourceObservation {
    MemoryWatchResourceObservation(
      capturedAtUTC: sample.timestampUTC,
      physicalMemoryBytes: sample.physicalMemoryBytes,
      estimatedMemoryUsedBytes: sample.estimatedMemoryUsedBytes,
      swapUsedBytes: sample.swapUsedBytes,
      pressure: sharedPressure(pressure),
      calculationVersion: sample.calculationVersion
    )
  }

  private static func sharedPressure(
    _ pressure: MemoryPressureLevel
  ) -> MemoryWatcherPressureSignal {
    switch pressure {
    case .unknown:
      return .unknown
    case .normal:
      return .normal
    case .warning:
      return .warning
    case .critical:
      return .critical
    }
  }
}
