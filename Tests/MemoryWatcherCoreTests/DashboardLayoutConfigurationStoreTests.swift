import Foundation
import XCTest

@testable import MemoryWatcherCore

final class DashboardLayoutConfigurationStoreTests: XCTestCase {
  func testMissingValueLoadsDefaultWithoutInventingSettings() throws {
    try withStore { store, defaults in
      XCTAssertEqual(store.load(), .defaultConfiguration)
      XCTAssertNil(
        defaults.data(forKey: DashboardLayoutConfiguration.storageKey)
      )
    }
  }

  func testSavedConfigurationSurvivesANewStoreInstance() throws {
    try withStore { store, defaults in
      let expected = DashboardLayoutConfiguration(
        preset: .compact,
        sectionOrder: [
          .selectionDetails,
          .memoryHistory,
          .totalCPUHistory,
          .logicalCPUHistory,
        ],
        hiddenSections: [.logicalCPUHistory]
      )

      try store.save(expected)

      let reopened = DashboardLayoutConfigurationStore(
        userDefaults: defaults
      )
      XCTAssertEqual(reopened.load(), expected.resolved())
    }
  }

  func testCorruptedValueIsRepairedWithDefault() throws {
    try withStore { store, defaults in
      defaults.set(
        Data("not-json".utf8),
        forKey: DashboardLayoutConfiguration.storageKey
      )

      XCTAssertEqual(store.load(), .defaultConfiguration)
      XCTAssertEqual(store.load(), .defaultConfiguration)

      let repairedData = try XCTUnwrap(
        defaults.data(forKey: DashboardLayoutConfiguration.storageKey)
      )
      XCTAssertEqual(
        try JSONDecoder().decode(
          DashboardLayoutConfiguration.self,
          from: repairedData
        ),
        .defaultConfiguration
      )
    }
  }

  func testUnsupportedSchemaIsRepairedWithDefault() throws {
    try withStore { store, defaults in
      let unsupported = DashboardLayoutConfiguration(
        schemaVersion: 99,
        preset: .detailed,
        sectionOrder: [.logicalCPUHistory],
        hiddenSections: [.selectionDetails]
      )
      defaults.set(
        try JSONEncoder().encode(unsupported),
        forKey: DashboardLayoutConfiguration.storageKey
      )

      XCTAssertEqual(store.load(), .defaultConfiguration)
      XCTAssertEqual(
        DashboardLayoutConfigurationStore(userDefaults: defaults).load(),
        .defaultConfiguration
      )
    }
  }

  func testResetRestoresBalancedCanonicalAllVisible() throws {
    try withStore { store, defaults in
      try store.save(
        DashboardLayoutConfiguration(
          preset: .compact,
          sectionOrder: DashboardLayoutSection.allCases.reversed(),
          hiddenSections: [.logicalCPUHistory, .selectionDetails]
        )
      )

      XCTAssertEqual(try store.reset(), .defaultConfiguration)
      XCTAssertEqual(
        DashboardLayoutConfigurationStore(userDefaults: defaults).load(),
        .defaultConfiguration
      )
    }
  }

  private func withStore(
    _ body: (
      DashboardLayoutConfigurationStore,
      UserDefaults
    ) throws -> Void
  ) throws {
    let suiteName = "DashboardLayoutConfigurationStoreTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    try body(
      DashboardLayoutConfigurationStore(userDefaults: defaults),
      defaults
    )
  }
}
