public enum MemoryMetricCertainty: String, Codable, Sendable {
  case systemReported
  case derivedEstimate
}

public struct MemoryMetricDefinition: Equatable, Sendable {
  public let displayName: String
  public let certainty: MemoryMetricCertainty

  public init(displayName: String, certainty: MemoryMetricCertainty) {
    self.displayName = displayName
    self.certainty = certainty
  }
}

public enum MemoryMetricCatalog {
  public static let physicalMemory = MemoryMetricDefinition(
    displayName: "物理メモリ",
    certainty: .systemReported
  )
  public static let estimatedMemoryUsed = MemoryMetricDefinition(
    displayName: "使用量（推定）",
    certainty: .derivedEstimate
  )
  public static let wiredMemory = MemoryMetricDefinition(
    displayName: "有線メモリ",
    certainty: .systemReported
  )
  public static let compressedMemory = MemoryMetricDefinition(
    displayName: "圧縮メモリ",
    certainty: .systemReported
  )
  public static let estimatedCachedFiles = MemoryMetricDefinition(
    displayName: "キャッシュ相当",
    certainty: .derivedEstimate
  )
  public static let swapUsed = MemoryMetricDefinition(
    displayName: "スワップ使用量",
    certainty: .systemReported
  )
}
