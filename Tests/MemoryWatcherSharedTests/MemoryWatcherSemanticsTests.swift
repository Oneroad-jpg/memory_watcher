import Foundation
import XCTest
@testable import MemoryWatcherShared

final class MemoryWatcherSemanticsTests: XCTestCase {
  func testDeterministicAnalyzerUsesPressureWithoutInventingDiagnosis() async throws {
    let observation = makeObservation(pressure: .warning)

    let state = try await DeterministicMemorySemanticAnalyzer()
      .analyze(observation)

    XCTAssertEqual(state.attention, .elevated)
    XCTAssertEqual(state.uncertainty, .none)
    XCTAssertEqual(state.memoryUsedFraction, 0.75, accuracy: 0.0001)
    XCTAssertEqual(state.provenance.authority, .measurementDerived)
    XCTAssertEqual(state.provenance.extensionIdentifier, nil)
    XCTAssertEqual(state.observation, observation)
  }

  func testUnknownPressureRemainsUnknown() async throws {
    let state = try await DeterministicMemorySemanticAnalyzer()
      .analyze(makeObservation(pressure: .unknown))

    XCTAssertEqual(state.attention, .unknown)
    XCTAssertEqual(state.uncertainty, .pressureUnavailable)
  }

  func testInvalidObservationIsRejected() async {
    let observation = MemoryWatchResourceObservation(
      capturedAtUTC: Date(timeIntervalSince1970: 100),
      physicalMemoryBytes: 10,
      estimatedMemoryUsedBytes: 11,
      swapUsedBytes: 0,
      pressure: .normal,
      calculationVersion: "test"
    )

    do {
      _ = try await DeterministicMemorySemanticAnalyzer()
        .analyze(observation)
      XCTFail("Expected invalid observation to be rejected")
    } catch {
      XCTAssertEqual(
        error as? MemorySemanticAnalysisError,
        .estimatedUsedExceedsPhysicalMemory
      )
    }
  }

  func testSnapshotRoundTripAndFreshness() async throws {
    let state = try await DeterministicMemorySemanticAnalyzer()
      .analyze(makeObservation(pressure: .normal))
    let snapshot = try MemoryWatchSnapshot(semanticState: state)

    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(
      MemoryWatchSnapshot.self,
      from: encoded
    )

    XCTAssertEqual(decoded, snapshot)
    XCTAssertEqual(
      snapshot.freshness(at: Date(timeIntervalSince1970: 120)),
      .current
    )
    XCTAssertEqual(
      snapshot.freshness(at: Date(timeIntervalSince1970: 140)),
      .stale
    )
    XCTAssertEqual(
      snapshot.freshness(at: Date(timeIntervalSince1970: 90)),
      .clockMismatch
    )
  }

  func testPipelineProducesValidatedDeterministicSnapshot() async throws {
    let snapshot = try await MemoryWatchPipeline().makeSnapshot(
      from: makeObservation(pressure: .critical)
    )

    XCTAssertEqual(snapshot.semanticState.attention, .critical)
    XCTAssertEqual(
      snapshot.semanticState.provenance.authority,
      .measurementDerived
    )
  }

  func testExtensionCandidateCannotClaimMeasurementAuthority() {
    XCTAssertThrowsError(
      try ResourceSemanticState(
        observation: makeObservation(pressure: .normal),
        memoryUsedFraction: 0.75,
        attention: .nominal,
        uncertainty: .none,
        provenance: MemoryWatcherSemanticProvenance(
          authority: .measurementDerived,
          analyzerIdentifier: "extension-adapter",
          extensionIdentifier: "extension"
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? MemorySemanticAnalysisError,
        .invalidProvenance
      )
    }
  }

  func testDecoderRejectsExtensionIdentifierWithMeasurementAuthority() async throws {
    let validState = try await DeterministicMemorySemanticAnalyzer()
      .analyze(makeObservation(pressure: .normal))
    let encoded = try JSONEncoder().encode(validState)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var provenance = try XCTUnwrap(
      object["provenance"] as? [String: Any]
    )
    provenance["extensionIdentifier"] = "extension"
    object["provenance"] = provenance
    let invalid = try JSONSerialization.data(withJSONObject: object)

    XCTAssertThrowsError(
      try JSONDecoder().decode(ResourceSemanticState.self, from: invalid)
    ) { error in
      XCTAssertEqual(
        error as? MemorySemanticAnalysisError,
        .invalidProvenance
      )
    }
  }

  private func makeObservation(
    pressure: MemoryWatcherPressureSignal
  ) -> MemoryWatchResourceObservation {
    MemoryWatchResourceObservation(
      capturedAtUTC: Date(timeIntervalSince1970: 100),
      physicalMemoryBytes: 16_000,
      estimatedMemoryUsedBytes: 12_000,
      swapUsedBytes: 200,
      pressure: pressure,
      calculationVersion: "test-v1"
    )
  }
}
