import Foundation

public enum MemoryWatcherLayerID: String, Codable, CaseIterable, Sendable {
  case foundation = "L1_FOUNDATION"
  case detectionCore = "L2_DETECTION_CORE"
  case runtime = "L3_RUNTIME"
  case product = "L4_PRODUCT"
  case platformIntegration = "L5_PLATFORM_INTEGRATION"
}

public enum MemoryWatcherPhaseID: String, Codable, CaseIterable, Sendable {
  case f1 = "F1"
  case f2 = "F2"
  case d1 = "D1"
  case d2 = "D2"
  case r1 = "R1"
  case r2 = "R2"
  case r3 = "R3"
  case r4 = "R4"
  case p1 = "P1"
  case p2 = "P2"
  case p3 = "P3"
  case pl1 = "PL1"
  case pl2 = "PL2"
  case ui1 = "UI1"

  public var layer: MemoryWatcherLayerID {
    switch self {
    case .f1, .f2:
      return .foundation
    case .d1, .d2:
      return .detectionCore
    case .r1, .r2, .r3, .r4:
      return .runtime
    case .p1, .p2, .p3:
      return .product
    case .pl1, .pl2, .ui1:
      return .platformIntegration
    }
  }
}

public enum MemoryWatcherPhaseDefinitionStatus: String, Codable, Sendable {
  case defined = "DEFINED"
  case undefined = "UNDEFINED"
}

public struct MemoryWatcherPhaseDefinition: Codable, Equatable, Sendable {
  public let phase: MemoryWatcherPhaseID
  public let definitionStatus: MemoryWatcherPhaseDefinitionStatus
  public let responsibility: String?
  public let replaceableAdapterBoundary: Bool

  public init(
    defined phase: MemoryWatcherPhaseID,
    responsibility: String,
    replaceableAdapterBoundary: Bool = false
  ) {
    self.phase = phase
    definitionStatus = .defined
    self.responsibility = responsibility
    self.replaceableAdapterBoundary = replaceableAdapterBoundary
  }

  public init(undefined phase: MemoryWatcherPhaseID) {
    self.phase = phase
    definitionStatus = .undefined
    responsibility = nil
    replaceableAdapterBoundary = false
  }
}

public enum MemoryWatcherArchitectureManifest {
  public static let identifier =
    "OneRoad.MemoryWatcher.GitHubLite.ArchitectureBlueprint.v1"

  public static let phases: [MemoryWatcherPhaseDefinition] = [
    .init(
      defined: .f1,
      responsibility: "Versioned Mac resource observation input"
    ),
    .init(
      defined: .f2,
      responsibility: "Semantic-state analyzer port and deterministic adapter",
      replaceableAdapterBoundary: true
    ),
    .init(
      defined: .d1,
      responsibility: "Measurement-derived attention state"
    ),
    .init(
      defined: .d2,
      responsibility: "Qualified and provenance-bound snapshot"
    ),
    .init(
      defined: .r1,
      responsibility: "Read-only runtime projection"
    ),
    .init(undefined: .r2),
    .init(
      defined: .r3,
      responsibility: "Deterministic pipeline routing"
    ),
    .init(undefined: .r4),
    .init(undefined: .p1),
    .init(
      defined: .p2,
      responsibility: "Mac and Apple Watch status presentation"
    ),
    .init(
      defined: .p3,
      responsibility: "Public-edition privacy and feature policy"
    ),
    .init(undefined: .pl1),
    .init(
      defined: .pl2,
      responsibility: "Authenticated Mac-to-Watch snapshot transport"
    ),
    .init(
      defined: .ui1,
      responsibility: "Read-only Apple Watch companion UI"
    ),
  ]
}
