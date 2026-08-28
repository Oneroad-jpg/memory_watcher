import ServiceManagement

public enum LoginItemRegistrationStatus: String, Equatable, Sendable {
  case notRegistered
  case enabled
  case requiresApproval
  case notFound
}

private final class LoginItemServiceBox: @unchecked Sendable {
  let service: SMAppService

  init(service: SMAppService) {
    self.service = service
  }
}

public struct LoginItemManager: Sendable {
  private let statusProvider: @Sendable () -> LoginItemRegistrationStatus
  private let registerAction: @Sendable () throws -> Void
  private let unregisterAction: @Sendable () throws -> Void
  private let openSettingsAction: @Sendable () -> Void

  public init() {
    let box = LoginItemServiceBox(service: .mainApp)
    statusProvider = {
      Self.registrationStatus(for: box.service.status)
    }
    registerAction = {
      try box.service.register()
    }
    unregisterAction = {
      try box.service.unregister()
    }
    openSettingsAction = {
      SMAppService.openSystemSettingsLoginItems()
    }
  }

  init(
    statusProvider: @escaping @Sendable () -> LoginItemRegistrationStatus,
    registerAction: @escaping @Sendable () throws -> Void,
    unregisterAction: @escaping @Sendable () throws -> Void,
    openSettingsAction: @escaping @Sendable () -> Void = {}
  ) {
    self.statusProvider = statusProvider
    self.registerAction = registerAction
    self.unregisterAction = unregisterAction
    self.openSettingsAction = openSettingsAction
  }

  public var status: LoginItemRegistrationStatus {
    statusProvider()
  }

  @discardableResult
  public func setEnabled(_ enabled: Bool) throws -> LoginItemRegistrationStatus {
    let currentStatus = statusProvider()
    if enabled {
      if currentStatus == .notRegistered || currentStatus == .notFound {
        try registerAction()
      }
    } else if currentStatus != .notRegistered {
      try unregisterAction()
    }
    return statusProvider()
  }

  public func openSystemSettings() {
    openSettingsAction()
  }

  private static func registrationStatus(
    for status: SMAppService.Status
  ) -> LoginItemRegistrationStatus {
    switch status {
    case .notRegistered:
      return .notRegistered
    case .enabled:
      return .enabled
    case .requiresApproval:
      return .requiresApproval
    case .notFound:
      return .notFound
    @unknown default:
      return .notFound
    }
  }
}
