import XCTest

@testable import MemoryWatcherCore

final class MemoryWatcherFoundationTests: XCTestCase {
  func testProductIdentityIsStable() {
    XCTAssertEqual(MemoryWatcherFoundation.appName, "Memory Watcher")
  }

  func testSampleIntervalMatchesFrozenRequirement() {
    XCTAssertEqual(MemoryWatcherFoundation.sampleInterval, 5)
  }

  func testSystemSQLiteIsAvailable() {
    XCTAssertGreaterThan(MemoryWatcherFoundation.sqliteVersionNumber, 0)
  }
}
