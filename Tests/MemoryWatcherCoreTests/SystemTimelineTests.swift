import Foundation
import XCTest

@testable import MemoryWatcherCore

final class SystemTimelineTests: XCTestCase {
  func testFirstLaunchDoesNotInventAReboot() {
    let current = SystemTimelineAnchor(
      timestampUTC: Date(timeIntervalSince1970: 10_000),
      systemUptimeSeconds: 500
    )

    XCTAssertEqual(
      SystemTimelineAnalyzer.launchEventKinds(
        previousSample: nil,
        current: current
      ),
      [.launch]
    )
  }

  func testLowerUptimeAtLaunchIdentifiesReboot() {
    let previous = SystemTimelineAnchor(
      timestampUTC: Date(timeIntervalSince1970: 10_000),
      systemUptimeSeconds: 50_000
    )
    let current = SystemTimelineAnchor(
      timestampUTC: Date(timeIntervalSince1970: 20_000),
      systemUptimeSeconds: 100
    )

    XCTAssertEqual(
      SystemTimelineAnalyzer.launchEventKinds(
        previousSample: previous,
        current: current
      ),
      [.rebootDetected, .launch]
    )
  }

  func testMatchingWallAndUptimeDeltasDoNotInventClockChange() {
    let previous = SystemTimelineAnchor(
      timestampUTC: Date(timeIntervalSince1970: 1_000),
      systemUptimeSeconds: 500
    )
    let current = SystemTimelineAnchor(
      timestampUTC: Date(timeIntervalSince1970: 1_005),
      systemUptimeSeconds: 505
    )

    XCTAssertFalse(
      SystemTimelineAnalyzer.clockChanged(previous: previous, current: current)
    )
  }

  func testDivergentWallAndUptimeDeltasIdentifyClockChange() {
    let previous = SystemTimelineAnchor(
      timestampUTC: Date(timeIntervalSince1970: 1_000),
      systemUptimeSeconds: 500
    )
    let current = SystemTimelineAnchor(
      timestampUTC: Date(timeIntervalSince1970: 1_065),
      systemUptimeSeconds: 505
    )

    XCTAssertTrue(
      SystemTimelineAnalyzer.clockChanged(previous: previous, current: current)
    )
  }
}
