import Foundation

public enum MemoryWatcherPressureSignal: String, Codable, Sendable {
  case unknown = "UNKNOWN"
  case normal = "NORMAL"
  case warning = "WARNING"
  case critical = "CRITICAL"
}

public struct MemoryWatchResourceObservation: Codable, Equatable, Sendable {
  public static let schema = "OneRoad.MemoryWatcher.ResourceObservation.v1"

  public let schema: String
  public let capturedAtUTC: Date
  public let physicalMemoryBytes: UInt64
  public let estimatedMemoryUsedBytes: UInt64
  public let swapUsedBytes: UInt64
  public let pressure: MemoryWatcherPressureSignal
  public let calculationVersion: String

  public init(
    capturedAtUTC: Date,
    physicalMemoryBytes: UInt64,
    estimatedMemoryUsedBytes: UInt64,
    swapUsedBytes: UInt64,
    pressure: MemoryWatcherPressureSignal,
    calculationVersion: String,
    schema: String = MemoryWatchResourceObservation.schema
  ) {
    self.schema = schema
    self.capturedAtUTC = capturedAtUTC
    self.physicalMemoryBytes = physicalMemoryBytes
    self.estimatedMemoryUsedBytes = estimatedMemoryUsedBytes
    self.swapUsedBytes = swapUsedBytes
    self.pressure = pressure
    self.calculationVersion = calculationVersion
  }
}

public enum MemoryWatcherAttentionState: String, Codable, Sendable {
  case unknown = "UNKNOWN"
  case nominal = "NOMINAL"
  case elevated = "ELEVATED"
  case critical = "CRITICAL"
}

public enum MemoryWatcherSemanticAuthority: String, Codable, Sendable {
  case measurementDerived = "MEASUREMENT_DERIVED"
  case extensionCandidate = "EXTENSION_CANDIDATE"
}

public enum MemoryWatcherSemanticUncertainty: String, Codable, Sendable {
  case none = "NONE"
  case pressureUnavailable = "PRESSURE_UNAVAILABLE"
}

public struct MemoryWatcherSemanticProvenance: Codable, Equatable, Sendable {
  public let authority: MemoryWatcherSemanticAuthority
  public let analyzerIdentifier: String
  public let extensionIdentifier: String?

  public init(
    authority: MemoryWatcherSemanticAuthority,
    analyzerIdentifier: String,
    extensionIdentifier: String?
  ) {
    self.authority = authority
    self.analyzerIdentifier = analyzerIdentifier
    self.extensionIdentifier = extensionIdentifier
  }
}

public struct ResourceSemanticState: Codable, Equatable, Sendable {
  public static let schema = "OneRoad.MemoryWatcher.ResourceSemanticState.v1"

  public let schema: String
  public let observation: MemoryWatchResourceObservation
  public let memoryUsedFraction: Double
  public let attention: MemoryWatcherAttentionState
  public let uncertainty: MemoryWatcherSemanticUncertainty
  public let provenance: MemoryWatcherSemanticProvenance

  public init(
    observation: MemoryWatchResourceObservation,
    memoryUsedFraction: Double,
    attention: MemoryWatcherAttentionState,
    uncertainty: MemoryWatcherSemanticUncertainty,
    provenance: MemoryWatcherSemanticProvenance,
    schema: String = ResourceSemanticState.schema
  ) throws {
    self.schema = schema
    self.observation = observation
    self.memoryUsedFraction = memoryUsedFraction
    self.attention = attention
    self.uncertainty = uncertainty
    self.provenance = provenance
    try validate()
  }

  public func validate() throws {
    guard schema == Self.schema else {
      throw MemorySemanticAnalysisError.unsupportedSemanticStateSchema(schema)
    }
    guard observation.schema == MemoryWatchResourceObservation.schema else {
      throw MemorySemanticAnalysisError.unsupportedObservationSchema(
        observation.schema
      )
    }
    guard memoryUsedFraction.isFinite,
      (0...1).contains(memoryUsedFraction)
    else {
      throw MemorySemanticAnalysisError.invalidMemoryUsedFraction
    }
    guard !provenance.analyzerIdentifier.isEmpty else {
      throw MemorySemanticAnalysisError.invalidProvenance
    }
    switch provenance.authority {
    case .measurementDerived:
      guard provenance.extensionIdentifier == nil else {
        throw MemorySemanticAnalysisError.invalidProvenance
      }
    case .extensionCandidate:
      guard
        let extensionIdentifier = provenance.extensionIdentifier,
        !extensionIdentifier.isEmpty
      else {
        throw MemorySemanticAnalysisError.invalidProvenance
      }
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      observation: container.decode(
        MemoryWatchResourceObservation.self,
        forKey: .observation
      ),
      memoryUsedFraction: container.decode(
        Double.self,
        forKey: .memoryUsedFraction
      ),
      attention: container.decode(
        MemoryWatcherAttentionState.self,
        forKey: .attention
      ),
      uncertainty: container.decode(
        MemoryWatcherSemanticUncertainty.self,
        forKey: .uncertainty
      ),
      provenance: container.decode(
        MemoryWatcherSemanticProvenance.self,
        forKey: .provenance
      ),
      schema: container.decode(String.self, forKey: .schema)
    )
  }
}

public enum MemorySemanticAnalysisError: Error, Equatable, Sendable {
  case unsupportedObservationSchema(String)
  case unsupportedSemanticStateSchema(String)
  case invalidPhysicalMemory
  case estimatedUsedExceedsPhysicalMemory
  case invalidMemoryUsedFraction
  case invalidProvenance
}

public protocol MemorySemanticAnalyzing: Sendable {
  func analyze(
    _ observation: MemoryWatchResourceObservation
  ) async throws -> ResourceSemanticState
}

public struct DeterministicMemorySemanticAnalyzer: MemorySemanticAnalyzing {
  public static let identifier =
    "OneRoad.MemoryWatcher.DeterministicSemanticAnalyzer.v1"

  public init() {}

  public func analyze(
    _ observation: MemoryWatchResourceObservation
  ) async throws -> ResourceSemanticState {
    guard observation.schema == MemoryWatchResourceObservation.schema else {
      throw MemorySemanticAnalysisError.unsupportedObservationSchema(
        observation.schema
      )
    }
    guard observation.physicalMemoryBytes > 0 else {
      throw MemorySemanticAnalysisError.invalidPhysicalMemory
    }
    guard
      observation.estimatedMemoryUsedBytes
        <= observation.physicalMemoryBytes
    else {
      throw MemorySemanticAnalysisError.estimatedUsedExceedsPhysicalMemory
    }

    let attention: MemoryWatcherAttentionState
    let uncertainty: MemoryWatcherSemanticUncertainty
    switch observation.pressure {
    case .unknown:
      attention = .unknown
      uncertainty = .pressureUnavailable
    case .normal:
      attention = .nominal
      uncertainty = .none
    case .warning:
      attention = .elevated
      uncertainty = .none
    case .critical:
      attention = .critical
      uncertainty = .none
    }

    return try ResourceSemanticState(
      observation: observation,
      memoryUsedFraction:
        Double(observation.estimatedMemoryUsedBytes)
        / Double(observation.physicalMemoryBytes),
      attention: attention,
      uncertainty: uncertainty,
      provenance: MemoryWatcherSemanticProvenance(
        authority: .measurementDerived,
        analyzerIdentifier: Self.identifier,
        extensionIdentifier: nil
      )
    )
  }
}
