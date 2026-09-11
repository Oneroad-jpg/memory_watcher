import Foundation

public struct MemoryWatchSnapshot: Codable, Equatable, Sendable {
  public static let schema = "OneRoad.MemoryWatcher.WatchSnapshot.v1"

  public let schema: String
  public let semanticState: ResourceSemanticState

  public init(
    semanticState: ResourceSemanticState,
    schema: String = MemoryWatchSnapshot.schema
  ) throws {
    guard schema == Self.schema else {
      throw MemoryWatchSnapshotError.unsupportedSchema(schema)
    }
    try semanticState.validate()
    self.schema = schema
    self.semanticState = semanticState
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      semanticState: container.decode(
        ResourceSemanticState.self,
        forKey: .semanticState
      ),
      schema: container.decode(String.self, forKey: .schema)
    )
  }

  public func freshness(
    at now: Date,
    staleAfter: TimeInterval = 30
  ) -> MemoryWatchSnapshotFreshness {
    let age = now.timeIntervalSince(
      semanticState.observation.capturedAtUTC
    )
    if age < 0 {
      return .clockMismatch
    }
    return age <= staleAfter ? .current : .stale
  }
}

public enum MemoryWatchSnapshotError: Error, Equatable, Sendable {
  case unsupportedSchema(String)
}

public enum MemoryWatchSnapshotFreshness: String, Codable, Sendable {
  case current = "CURRENT"
  case stale = "STALE"
  case clockMismatch = "CLOCK_MISMATCH"
}

public enum MemoryWatcherPublicEditionPolicy {
  public static let permitsExternalAnalytics = false
  public static let permitsRemoteActions = false
  public static let requiresAuthenticatedTransport = true
}

public struct MemoryWatchPipeline: Sendable {
  private let analyzer: any MemorySemanticAnalyzing

  public init(
    analyzer: any MemorySemanticAnalyzing =
      DeterministicMemorySemanticAnalyzer()
  ) {
    self.analyzer = analyzer
  }

  public func makeSnapshot(
    from observation: MemoryWatchResourceObservation
  ) async throws -> MemoryWatchSnapshot {
    let state = try await analyzer.analyze(observation)
    return try MemoryWatchSnapshot(semanticState: state)
  }
}
