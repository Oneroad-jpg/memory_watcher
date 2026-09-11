import XCTest
@testable import MemoryWatcherShared

final class MemoryWatcherArchitectureTests: XCTestCase {
  func testManifestContainsExactlyFiveLayersAndFourteenPhases() {
    let phases = MemoryWatcherArchitectureManifest.phases

    XCTAssertEqual(phases.count, 14)
    XCTAssertEqual(Set(phases.map(\.phase)).count, 14)
    XCTAssertEqual(Set(phases.map { $0.phase.layer }).count, 5)
    XCTAssertEqual(Set(phases.map(\.phase)), Set(MemoryWatcherPhaseID.allCases))
  }

  func testUnusedPhasesRemainUndefinedWithoutAssignedResponsibility() {
    let definitions = Dictionary(
      uniqueKeysWithValues:
        MemoryWatcherArchitectureManifest.phases.map { ($0.phase, $0) }
    )

    for phase in [
      MemoryWatcherPhaseID.r2,
      .r4,
      .p1,
      .pl1,
    ] {
      XCTAssertEqual(definitions[phase]?.definitionStatus, .undefined)
      XCTAssertNil(definitions[phase]?.responsibility)
      XCTAssertEqual(
        definitions[phase]?.replaceableAdapterBoundary,
        false
      )
    }
  }

  func testDefinedPhasesHaveResponsibilities() {
    let definitions = MemoryWatcherArchitectureManifest.phases.filter {
      $0.definitionStatus == .defined
    }

    XCTAssertFalse(definitions.isEmpty)
    XCTAssertTrue(
      definitions.allSatisfy { definition in
        guard let responsibility = definition.responsibility else {
          return false
        }
        return !responsibility.isEmpty
      }
    )
  }

  func testPublicEditionHasNoRemoteAction() {
    XCTAssertFalse(MemoryWatcherPublicEditionPolicy.permitsRemoteActions)
    XCTAssertTrue(
      MemoryWatcherPublicEditionPolicy.requiresAuthenticatedTransport
    )
  }
}
