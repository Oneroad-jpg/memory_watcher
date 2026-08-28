import Dispatch
import Foundation
import XCTest

@testable import MemoryWatcherCore

final class MemoryPressureMonitorTests: XCTestCase {
  func testDecoderMapsEachDocumentedPressureEvent() {
    XCTAssertEqual(MemoryPressureEventDecoder.level(for: .normal), .normal)
    XCTAssertEqual(MemoryPressureEventDecoder.level(for: .warning), .warning)
    XCTAssertEqual(MemoryPressureEventDecoder.level(for: .critical), .critical)
  }

  func testDecoderPreservesUnknownForMissingOrAmbiguousEvents() {
    XCTAssertEqual(MemoryPressureEventDecoder.level(for: []), .unknown)
    XCTAssertEqual(
      MemoryPressureEventDecoder.level(for: [.normal, .warning]),
      .unknown
    )
    XCTAssertEqual(
      MemoryPressureEventDecoder.level(for: [.warning, .critical]),
      .unknown
    )
    XCTAssertEqual(
      MemoryPressureEventDecoder.level(for: [.normal, .warning, .critical]),
      .unknown
    )
    XCTAssertEqual(
      MemoryPressureEventDecoder.level(
        for: DispatchSource.MemoryPressureEvent(rawValue: 1 << 12)
      ),
      .unknown
    )
  }

  func testStateMachineEmitsOnlyActualStateChanges() {
    var stateMachine = MemoryPressureStateMachine()
    let first = stateMachine.transition(
      to: .warning,
      timestampUTC: Date(timeIntervalSince1970: 100),
      systemUptimeSeconds: 50
    )
    let duplicate = stateMachine.transition(
      to: .warning,
      timestampUTC: Date(timeIntervalSince1970: 101),
      systemUptimeSeconds: 51
    )
    let second = stateMachine.transition(
      to: .critical,
      timestampUTC: Date(timeIntervalSince1970: 102),
      systemUptimeSeconds: 52
    )

    XCTAssertEqual(first?.level, .warning)
    XCTAssertNil(duplicate)
    XCTAssertEqual(second?.level, .critical)
    XCTAssertEqual(stateMachine.currentLevel, .critical)
  }

  func testStateChangePreservesTimestampAndUptime() {
    var stateMachine = MemoryPressureStateMachine()
    let timestamp = Date(timeIntervalSince1970: 123_456)

    let observation = stateMachine.transition(
      to: .normal,
      timestampUTC: timestamp,
      systemUptimeSeconds: 654.25
    )

    XCTAssertEqual(observation?.timestampUTC, timestamp)
    XCTAssertEqual(observation?.systemUptimeSeconds, 654.25)
    XCTAssertEqual(observation?.level, .normal)
  }

  func testLiveMonitorStartsUnknownAndCanStop() throws {
    let monitor = MemoryPressureMonitor(
      queue: DispatchQueue(label: "MemoryPressureMonitorTests.live"),
      timestampProvider: { Date(timeIntervalSince1970: 2_000) },
      uptimeProvider: { 1_000 }
    )

    let initialObservation = try monitor.start { _ in }

    XCTAssertEqual(initialObservation.level, .unknown)
    XCTAssertEqual(
      initialObservation.timestampUTC,
      Date(timeIntervalSince1970: 2_000)
    )
    XCTAssertEqual(initialObservation.systemUptimeSeconds, 1_000)
    monitor.stop()
  }

  func testMonitorRejectsDuplicateStart() throws {
    let monitor = MemoryPressureMonitor(
      queue: DispatchQueue(label: "MemoryPressureMonitorTests.duplicate"),
      timestampProvider: { Date(timeIntervalSince1970: 3_000) },
      uptimeProvider: { 2_000 }
    )
    _ = try monitor.start { _ in }
    defer { monitor.stop() }

    XCTAssertThrowsError(try monitor.start { _ in }) { error in
      XCTAssertEqual(
        error as? MemoryPressureMonitorError,
        .alreadyStarted
      )
    }
  }
}
