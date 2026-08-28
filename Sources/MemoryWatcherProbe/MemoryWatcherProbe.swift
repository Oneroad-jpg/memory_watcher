import Foundation
import MemoryWatcherCore

private struct ProbeSummary: Encodable {
  let calculationVersion: String
  let cachedBytesMaximum: UInt64
  let cachedBytesMinimum: UInt64
  let compressedBytesMaximum: UInt64
  let compressedBytesMinimum: UInt64
  let expectedDurationSeconds: TimeInterval
  let expectedIntervalSeconds: TimeInterval
  let firstSystemUptimeSeconds: TimeInterval
  let firstTimestampUTC: Date
  let invalidSampleCount: Int
  let lastSystemUptimeSeconds: TimeInterval
  let lastTimestampUTC: Date
  let maximumObservedIntervalSeconds: TimeInterval
  let memoryUsedBytesMaximum: UInt64
  let memoryUsedBytesMinimum: UInt64
  let minimumObservedIntervalSeconds: TimeInterval
  let observedDurationSeconds: TimeInterval
  let observedSampleCount: Int
  let physicalMemoryBytes: UInt64
  let requestedSampleCount: Int
  let status: String
  let swapUsedBytesMaximum: UInt64
  let swapUsedBytesMinimum: UInt64
  let timestampOrderValid: Bool
  let uptimeOrderValid: Bool
  let wiredBytesMaximum: UInt64
  let wiredBytesMinimum: UInt64
}

@main
enum MemoryWatcherProbe {
  static func main() {
    do {
      let requestedSampleCount = try parseRequestedSampleCount()
      let samples = try collectSamples(count: requestedSampleCount)
      let summary = try makeSummary(
        samples: samples,
        requestedSampleCount: requestedSampleCount
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      let output = try encoder.encode(summary)
      FileHandle.standardOutput.write(output)
      FileHandle.standardOutput.write(Data([0x0A]))
    } catch {
      let message = "MemoryWatcherProbe failed: \(error)\n"
      FileHandle.standardError.write(Data(message.utf8))
      Foundation.exit(EXIT_FAILURE)
    }
  }

  private static func parseRequestedSampleCount() throws -> Int {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard
      arguments.count == 2,
      arguments[0] == "--samples",
      let count = Int(arguments[1]),
      (1...10_000).contains(count)
    else {
      throw MemorySamplingError.invalidSample
    }
    return count
  }

  private static func collectSamples(count: Int) throws -> [MemorySample] {
    let sampler = SystemMemorySampler()
    var samples: [MemorySample] = []
    samples.reserveCapacity(count)

    for index in 0..<count {
      if index > 0 {
        Thread.sleep(forTimeInterval: MemoryWatcherFoundation.sampleInterval)
      }
      let sample = try sampler.sample()
      try MemorySampleValidator.validate(sample)
      samples.append(sample)
    }
    return samples
  }

  private static func makeSummary(
    samples: [MemorySample],
    requestedSampleCount: Int
  ) throws -> ProbeSummary {
    guard let first = samples.first, let last = samples.last else {
      throw MemorySamplingError.invalidSample
    }
    let intervals = zip(samples, samples.dropFirst()).map {
      laterPair in
      laterPair.1.systemUptimeSeconds - laterPair.0.systemUptimeSeconds
    }
    let timestampIntervals = zip(samples, samples.dropFirst()).map {
      laterPair in
      laterPair.1.timestampUTC.timeIntervalSince(laterPair.0.timestampUTC)
    }
    let expectedDuration =
      Double(max(0, requestedSampleCount - 1))
      * MemoryWatcherFoundation.sampleInterval
    let observedDuration =
      last.systemUptimeSeconds - first.systemUptimeSeconds
    let minimumInterval = intervals.min() ?? 0
    let maximumInterval = intervals.max() ?? 0
    let uptimeOrderValid = intervals.allSatisfy { $0 > 0 }
    let timestampOrderValid = timestampIntervals.allSatisfy { $0 > 0 }
    let intervalBoundsPass =
      requestedSampleCount == 1
      || (minimumInterval >= 4
        && maximumInterval <= 7)
    let durationTolerance = max(1, expectedDuration * 0.05)
    let durationPass =
      abs(observedDuration - expectedDuration) <= durationTolerance
    let physicalMemoryStable = samples.allSatisfy {
      $0.physicalMemoryBytes == first.physicalMemoryBytes
    }
    let invalidSampleCount = samples.reduce(into: 0) { count, sample in
      if (try? MemorySampleValidator.validate(sample)) == nil {
        count += 1
      }
    }
    let valuesValid = invalidSampleCount == 0
    let status =
      samples.count == requestedSampleCount
        && uptimeOrderValid
        && timestampOrderValid
        && intervalBoundsPass
        && durationPass
        && physicalMemoryStable
        && valuesValid
      ? "PASS"
      : "FAIL"

    return ProbeSummary(
      calculationVersion: first.calculationVersion,
      cachedBytesMaximum: samples.map(\.cachedBytes).max() ?? 0,
      cachedBytesMinimum: samples.map(\.cachedBytes).min() ?? 0,
      compressedBytesMaximum: samples.map(\.compressedBytes).max() ?? 0,
      compressedBytesMinimum: samples.map(\.compressedBytes).min() ?? 0,
      expectedDurationSeconds: expectedDuration,
      expectedIntervalSeconds: MemoryWatcherFoundation.sampleInterval,
      firstSystemUptimeSeconds: first.systemUptimeSeconds,
      firstTimestampUTC: first.timestampUTC,
      invalidSampleCount: invalidSampleCount,
      lastSystemUptimeSeconds: last.systemUptimeSeconds,
      lastTimestampUTC: last.timestampUTC,
      maximumObservedIntervalSeconds: maximumInterval,
      memoryUsedBytesMaximum: samples.map(\.memoryUsedBytes).max() ?? 0,
      memoryUsedBytesMinimum: samples.map(\.memoryUsedBytes).min() ?? 0,
      minimumObservedIntervalSeconds: minimumInterval,
      observedDurationSeconds: observedDuration,
      observedSampleCount: samples.count,
      physicalMemoryBytes: first.physicalMemoryBytes,
      requestedSampleCount: requestedSampleCount,
      status: status,
      swapUsedBytesMaximum: samples.map(\.swapUsedBytes).max() ?? 0,
      swapUsedBytesMinimum: samples.map(\.swapUsedBytes).min() ?? 0,
      timestampOrderValid: timestampOrderValid,
      uptimeOrderValid: uptimeOrderValid,
      wiredBytesMaximum: samples.map(\.wiredBytes).max() ?? 0,
      wiredBytesMinimum: samples.map(\.wiredBytes).min() ?? 0
    )
  }
}
