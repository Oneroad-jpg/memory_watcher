import Foundation
import MemoryWatcherCore

@MainActor
final class MonitoringViewModel: ObservableObject {
  @Published private(set) var runState: MemoryMonitoringRunState = .stopped
  @Published private(set) var sampleCount = 0
  @Published private(set) var gapCount = 0
  @Published private(set) var lastMemoryUsedBytes: UInt64?
  @Published private(set) var pressureLevel: MemoryPressureLevel = .unknown
  @Published private(set) var lastLifecycleKind: SystemLifecycleEventKind?
  @Published private(set) var loginItemStatus: LoginItemRegistrationStatus
  @Published private(set) var errorMessage: String?

  private let loginItemManager: LoginItemManager

  init(loginItemManager: LoginItemManager = LoginItemManager()) {
    self.loginItemManager = loginItemManager
    loginItemStatus = loginItemManager.status
  }

  var loginItemIsRegistered: Bool {
    loginItemStatus == .enabled || loginItemStatus == .requiresApproval
  }

  func updateRunState(_ state: MemoryMonitoringRunState) {
    runState = state
  }

  func receive(_ event: MemoryMonitoringEvent) {
    switch event {
    case .sample(let sample):
      sampleCount += 1
      lastMemoryUsedBytes = sample.estimatedMemoryUsedBytes
    case .gap:
      gapCount += 1
    case .pressure(let observation):
      pressureLevel = observation.level
    case .lifecycle(let event):
      lastLifecycleKind = event.kind
    case .failure(let message):
      errorMessage = message
    }
  }

  func setLoginItemEnabled(_ enabled: Bool) {
    do {
      loginItemStatus = try loginItemManager.setEnabled(enabled)
      errorMessage = nil
    } catch {
      loginItemStatus = loginItemManager.status
      errorMessage = String(describing: error)
    }
  }

  func refreshLoginItemStatus() {
    loginItemStatus = loginItemManager.status
  }

  func openLoginItemSettings() {
    loginItemManager.openSystemSettings()
  }

  func reportStartupFailure(_ error: Error) {
    errorMessage = String(describing: error)
    runState = .stopped
  }
}
