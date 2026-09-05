import XCTest

@testable import MemoryWatcherCore

final class DashboardLayoutConfigurationTests: XCTestCase {
  func testDefaultConfigurationIsBalancedAndShowsEverySection() {
    let configuration = DashboardLayoutConfiguration.defaultConfiguration

    XCTAssertEqual(configuration.schemaVersion, 1)
    XCTAssertEqual(configuration.preset, .balanced)
    XCTAssertEqual(
      configuration.sectionOrder,
      DashboardLayoutConfiguration.canonicalSectionOrder
    )
    for section in DashboardLayoutSection.allCases {
      XCTAssertTrue(configuration.isVisible(section))
    }
  }

  func testEveryPresetHasOrderedBoundedMetrics() {
    let compact = DashboardLayoutPreset.compact.metrics
    let balanced = DashboardLayoutPreset.balanced.metrics
    let detailed = DashboardLayoutPreset.detailed.metrics

    for metrics in [compact, balanced, detailed] {
      XCTAssertGreaterThan(metrics.currentPaneMinimumHeight, 0)
      XCTAssertGreaterThanOrEqual(
        metrics.currentPaneMaximumHeight,
        metrics.currentPaneMinimumHeight
      )
      XCTAssertTrue((0...1).contains(metrics.currentPaneHeightFraction))
      XCTAssertGreaterThan(metrics.contentPadding, 0)
      XCTAssertGreaterThan(metrics.sectionSpacing, 0)
      XCTAssertGreaterThan(metrics.logicalCPUCurrentMinimumWidth, 0)
      XCTAssertGreaterThan(metrics.logicalCPUHistoryMinimumWidth, 0)
      XCTAssertGreaterThan(metrics.memoryChartHeight, 0)
      XCTAssertGreaterThan(metrics.swapChartHeight, 0)
      XCTAssertGreaterThan(metrics.totalCPUChartHeight, 0)
      XCTAssertGreaterThan(metrics.logicalCPUChartHeight, 0)
    }

    XCTAssertLessThan(
      compact.currentPaneHeightFraction,
      balanced.currentPaneHeightFraction
    )
    XCTAssertLessThan(
      balanced.currentPaneHeightFraction,
      detailed.currentPaneHeightFraction
    )
    XCTAssertLessThan(compact.memoryChartHeight, balanced.memoryChartHeight)
    XCTAssertLessThan(balanced.memoryChartHeight, detailed.memoryChartHeight)
  }

  func testResolutionRemovesDuplicatesAndRestoresMissingSections() {
    let configuration = DashboardLayoutConfiguration(
      preset: .compact,
      sectionOrder: [.totalCPUHistory, .totalCPUHistory],
      hiddenSections: [.logicalCPUHistory, .logicalCPUHistory]
    ).resolved()

    XCTAssertEqual(
      configuration.sectionOrder,
      [
        .totalCPUHistory,
        .memoryHistory,
        .logicalCPUHistory,
        .selectionDetails,
      ]
    )
    XCTAssertEqual(configuration.hiddenSections, [.logicalCPUHistory])
  }

  func testRequiredSectionsCannotBeHidden() {
    let configuration = DashboardLayoutConfiguration(
      preset: .detailed,
      sectionOrder: DashboardLayoutSection.allCases,
      hiddenSections: DashboardLayoutSection.allCases
    ).resolved()

    XCTAssertTrue(configuration.isVisible(.memoryHistory))
    XCTAssertTrue(configuration.isVisible(.totalCPUHistory))
    XCTAssertFalse(configuration.isVisible(.logicalCPUHistory))
    XCTAssertFalse(configuration.isVisible(.selectionDetails))
  }

  func testUnsupportedSchemaFallsBackToDefault() {
    let configuration = DashboardLayoutConfiguration(
      schemaVersion: 99,
      preset: .compact,
      sectionOrder: [.totalCPUHistory],
      hiddenSections: [.logicalCPUHistory]
    )

    XCTAssertEqual(
      configuration.resolved(),
      DashboardLayoutConfiguration.defaultConfiguration
    )
  }

  func testConfigurationRoundTripsThroughJSON() throws {
    let original = DashboardLayoutConfiguration(
      preset: .compact,
      sectionOrder: [
        .totalCPUHistory,
        .memoryHistory,
        .selectionDetails,
        .logicalCPUHistory,
      ],
      hiddenSections: [.selectionDetails]
    ).resolved()

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(
      DashboardLayoutConfiguration.self,
      from: data
    )

    XCTAssertEqual(decoded.resolved(), original)
  }
}
