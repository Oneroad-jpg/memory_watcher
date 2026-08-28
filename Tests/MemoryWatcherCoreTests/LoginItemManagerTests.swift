import Foundation
import XCTest

@testable import MemoryWatcherCore

final class LoginItemManagerTests: XCTestCase {
  func testEnableAndDisableUseRegistrationActions() throws {
    let service = FakeLoginItemService(status: .notRegistered)
    let manager = service.manager()

    XCTAssertEqual(try manager.setEnabled(true), .enabled)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(service.unregisterCount, 0)

    XCTAssertEqual(try manager.setEnabled(false), .notRegistered)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(service.unregisterCount, 1)
  }

  func testRequiresApprovalDoesNotReregister() throws {
    let service = FakeLoginItemService(status: .requiresApproval)
    let manager = service.manager()

    XCTAssertEqual(try manager.setEnabled(true), .requiresApproval)
    XCTAssertEqual(service.registerCount, 0)
  }

  func testOpenSettingsUsesDedicatedAction() {
    let service = FakeLoginItemService(status: .notRegistered)

    service.manager().openSystemSettings()

    XCTAssertEqual(service.openSettingsCount, 1)
  }
}

private final class FakeLoginItemService: @unchecked Sendable {
  private let lock = NSLock()
  private var storedStatus: LoginItemRegistrationStatus
  private var storedRegisterCount = 0
  private var storedUnregisterCount = 0
  private var storedOpenSettingsCount = 0

  init(status: LoginItemRegistrationStatus) {
    storedStatus = status
  }

  var registerCount: Int {
    lock.withLock { storedRegisterCount }
  }

  var unregisterCount: Int {
    lock.withLock { storedUnregisterCount }
  }

  var openSettingsCount: Int {
    lock.withLock { storedOpenSettingsCount }
  }

  func manager() -> LoginItemManager {
    LoginItemManager(
      statusProvider: { [self] in
        lock.withLock { storedStatus }
      },
      registerAction: { [self] in
        lock.withLock {
          storedRegisterCount += 1
          storedStatus = .enabled
        }
      },
      unregisterAction: { [self] in
        lock.withLock {
          storedUnregisterCount += 1
          storedStatus = .notRegistered
        }
      },
      openSettingsAction: { [self] in
        lock.withLock {
          storedOpenSettingsCount += 1
        }
      }
    )
  }
}
