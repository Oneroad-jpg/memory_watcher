import Foundation

public final class DashboardLayoutConfigurationStore {
  private let userDefaults: UserDefaults
  private let storageKey: String
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(
    userDefaults: UserDefaults = .standard,
    storageKey: String = DashboardLayoutConfiguration.storageKey
  ) {
    self.userDefaults = userDefaults
    self.storageKey = storageKey
  }

  public func load() -> DashboardLayoutConfiguration {
    guard let data = userDefaults.data(forKey: storageKey) else {
      return .defaultConfiguration
    }
    guard
      let decoded = try? decoder.decode(
        DashboardLayoutConfiguration.self,
        from: data
      ),
      decoded.schemaVersion == DashboardLayoutConfiguration.currentSchemaVersion
    else {
      repairWithDefault()
      return .defaultConfiguration
    }

    let resolved = decoded.resolved()
    if resolved != decoded {
      try? save(resolved)
    }
    return resolved
  }

  public func save(_ configuration: DashboardLayoutConfiguration) throws {
    let resolved = configuration.resolved()
    let data = try encoder.encode(resolved)
    userDefaults.set(data, forKey: storageKey)
  }

  @discardableResult
  public func reset() throws -> DashboardLayoutConfiguration {
    let configuration = DashboardLayoutConfiguration.defaultConfiguration
    try save(configuration)
    return configuration
  }

  private func repairWithDefault() {
    try? save(.defaultConfiguration)
  }
}
