import Foundation

public enum DashboardLayoutPreset: String, CaseIterable, Codable, Sendable {
  case compact
  case balanced
  case detailed

  public var metrics: DashboardLayoutMetrics {
    switch self {
    case .compact:
      return DashboardLayoutMetrics(
        currentPaneMinimumHeight: 170,
        currentPaneMaximumHeight: 260,
        currentPaneHeightFraction: 0.34,
        contentPadding: 12,
        sectionSpacing: 8,
        logicalCPUCurrentMinimumWidth: 88,
        logicalCPUHistoryMinimumWidth: 180,
        memoryChartHeight: 185,
        swapChartHeight: 62,
        totalCPUChartHeight: 130,
        logicalCPUChartHeight: 58
      )
    case .balanced:
      return DashboardLayoutMetrics(
        currentPaneMinimumHeight: 200,
        currentPaneMaximumHeight: 320,
        currentPaneHeightFraction: 0.42,
        contentPadding: 18,
        sectionSpacing: 10,
        logicalCPUCurrentMinimumWidth: 100,
        logicalCPUHistoryMinimumWidth: 210,
        memoryChartHeight: 215,
        swapChartHeight: 74,
        totalCPUChartHeight: 155,
        logicalCPUChartHeight: 70
      )
    case .detailed:
      return DashboardLayoutMetrics(
        currentPaneMinimumHeight: 220,
        currentPaneMaximumHeight: 380,
        currentPaneHeightFraction: 0.48,
        contentPadding: 24,
        sectionSpacing: 12,
        logicalCPUCurrentMinimumWidth: 112,
        logicalCPUHistoryMinimumWidth: 240,
        memoryChartHeight: 250,
        swapChartHeight: 88,
        totalCPUChartHeight: 185,
        logicalCPUChartHeight: 82
      )
    }
  }
}

public struct DashboardLayoutMetrics: Equatable, Sendable {
  public let currentPaneMinimumHeight: Double
  public let currentPaneMaximumHeight: Double
  public let currentPaneHeightFraction: Double
  public let contentPadding: Double
  public let sectionSpacing: Double
  public let logicalCPUCurrentMinimumWidth: Double
  public let logicalCPUHistoryMinimumWidth: Double
  public let memoryChartHeight: Double
  public let swapChartHeight: Double
  public let totalCPUChartHeight: Double
  public let logicalCPUChartHeight: Double

  public init(
    currentPaneMinimumHeight: Double,
    currentPaneMaximumHeight: Double,
    currentPaneHeightFraction: Double,
    contentPadding: Double,
    sectionSpacing: Double,
    logicalCPUCurrentMinimumWidth: Double,
    logicalCPUHistoryMinimumWidth: Double,
    memoryChartHeight: Double,
    swapChartHeight: Double,
    totalCPUChartHeight: Double,
    logicalCPUChartHeight: Double
  ) {
    self.currentPaneMinimumHeight = currentPaneMinimumHeight
    self.currentPaneMaximumHeight = currentPaneMaximumHeight
    self.currentPaneHeightFraction = currentPaneHeightFraction
    self.contentPadding = contentPadding
    self.sectionSpacing = sectionSpacing
    self.logicalCPUCurrentMinimumWidth = logicalCPUCurrentMinimumWidth
    self.logicalCPUHistoryMinimumWidth = logicalCPUHistoryMinimumWidth
    self.memoryChartHeight = memoryChartHeight
    self.swapChartHeight = swapChartHeight
    self.totalCPUChartHeight = totalCPUChartHeight
    self.logicalCPUChartHeight = logicalCPUChartHeight
  }
}

public enum DashboardLayoutSection: String, CaseIterable, Codable, Sendable {
  case memoryHistory
  case totalCPUHistory
  case logicalCPUHistory
  case selectionDetails

  public var canBeHidden: Bool {
    switch self {
    case .memoryHistory, .totalCPUHistory:
      return false
    case .logicalCPUHistory, .selectionDetails:
      return true
    }
  }
}

public struct DashboardLayoutConfiguration: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1
  public static let storageKey = "dashboard.layout.configuration.v1"
  public static let canonicalSectionOrder = DashboardLayoutSection.allCases
  public static let defaultConfiguration = DashboardLayoutConfiguration(
    schemaVersion: currentSchemaVersion,
    preset: .balanced,
    sectionOrder: canonicalSectionOrder,
    hiddenSections: []
  )

  public let schemaVersion: Int
  public let preset: DashboardLayoutPreset
  public let sectionOrder: [DashboardLayoutSection]
  public let hiddenSections: [DashboardLayoutSection]

  public init(
    schemaVersion: Int = currentSchemaVersion,
    preset: DashboardLayoutPreset,
    sectionOrder: [DashboardLayoutSection],
    hiddenSections: [DashboardLayoutSection]
  ) {
    self.schemaVersion = schemaVersion
    self.preset = preset
    self.sectionOrder = sectionOrder
    self.hiddenSections = hiddenSections
  }

  public func resolved() -> DashboardLayoutConfiguration {
    guard schemaVersion == Self.currentSchemaVersion else {
      return Self.defaultConfiguration
    }

    let completeOrder = unique(
      sectionOrder + Self.canonicalSectionOrder
    )
    let allowedHidden = unique(hiddenSections).filter(\.canBeHidden)
    return DashboardLayoutConfiguration(
      preset: preset,
      sectionOrder: completeOrder,
      hiddenSections: allowedHidden
    )
  }

  public func isVisible(_ section: DashboardLayoutSection) -> Bool {
    !resolved().hiddenSections.contains(section)
  }

  private func unique(
    _ sections: [DashboardLayoutSection]
  ) -> [DashboardLayoutSection] {
    var seen = Set<DashboardLayoutSection>()
    return sections.filter { seen.insert($0).inserted }
  }
}
