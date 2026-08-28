import Foundation
import MemoryWatcherCore

private struct ProbeCollection {
  var samples: [MemorySample] = []
  var gaps: [MemorySamplingGap] = []
  var observationTimestampsUTC: [Date] = []
  var observationUptimes: [TimeInterval] = []
}

private struct ProbeSummary: Encodable {
  let calculationVersion: String
  let compressedBytesMaximum: UInt64
  let compressedBytesMinimum: UInt64
  let estimatedApplicationMemoryBytesMaximum: UInt64
  let estimatedApplicationMemoryBytesMinimum: UInt64
  let estimatedCachedFilesBytesMaximum: UInt64
  let estimatedCachedFilesBytesMinimum: UInt64
  let estimatedMemoryUsedBytesMaximum: UInt64
  let estimatedMemoryUsedBytesMinimum: UInt64
  let expectedDurationSeconds: TimeInterval
  let expectedIntervalSeconds: TimeInterval
  let firstSystemUptimeSeconds: TimeInterval
  let firstTimestampUTC: Date
  let invalidSampleCount: Int
  let lastSystemUptimeSeconds: TimeInterval
  let lastTimestampUTC: Date
  let maximumAcquisitionAttemptCount: Int
  let maximumObservedIntervalSeconds: TimeInterval
  let maximumRejectedExcessBytes: UInt64
  let minimumObservedIntervalSeconds: TimeInterval
  let observedDurationSeconds: TimeInterval
  let observedSampleCount: Int
  let physicalMemoryBytes: UInt64
  let rejectedReasonCounts: [String: Int]
  let rejectedSampleCount: Int
  let requestedSampleCount: Int
  let retriedSampleCount: Int
  let status: String
  let swapUsedBytesMaximum: UInt64
  let swapUsedBytesMinimum: UInt64
  let timestampOrderValid: Bool
  let unclassifiedMemoryUsedBytesMaximum: UInt64
  let unclassifiedMemoryUsedBytesMinimum: UInt64
  let uptimeOrderValid: Bool
  let wiredBytesMaximum: UInt64
  let wiredBytesMinimum: UInt64
}

@main
enum MemoryWatcherProbe {
  static func main() {
    do {
      let requestedSampleCount = try parseRequestedSampleCount()
      let collection = try collectObservations(count: requestedSampleCount)
      let summary = try makeSummary(
        collection: collection,
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

  private static func collectObservations(
    count: Int
  ) throws -> ProbeCollection {
    let sampler = SystemMemorySampler()
    var collection = ProbeCollection()
    collection.samples.reserveCapacity(count)
    collection.gaps.reserveCapacity(count)
    collection.observationTimestampsUTC.reserveCapacity(count)
    collection.observationUptimes.reserveCapacity(count)

    for index in 0..<count {
      if index > 0 {
        Thread.sleep(forTimeInterval: MemoryWatcherFoundation.sampleInterval)
      }
      switch try sampler.sampleOutcome() {
      case .sample(let sample):
        try MemorySampleValidator.validate(sample)
        collection.samples.append(sample)
        collection.observationTimestampsUTC.append(sample.timestampUTC)
        collection.observationUptimes.append(sample.systemUptimeSeconds)
      case .gap(let gap):
        collection.gaps.append(gap)
        collection.observationTimestampsUTC.append(gap.timestampUTC)
        collection.observationUptimes.append(gap.systemUptimeSeconds)
      }
    }
    return collection
  }

  private static func makeSummary(
    collection: ProbeCollection,
    requestedSampleCount: Int
  ) throws -> ProbeSummary {
    guard
      let firstTimestamp = collection.observationTimestampsUTC.first,
      let lastTimestamp = collection.observationTimestampsUTC.last,
      let firstUptime = collection.observationUptimes.first,
      let lastUptime = collection.observationUptimes.last
    else {
      throw MemorySamplingError.invalidSample
    }

    let samples = collection.samples
    let gaps = collection.gaps
    let uptimeIntervals = zip(
      collection.observationUptimes,
      collection.observationUptimes.dropFirst()
    ).map { pair in
      pair.1 - pair.0
    }
    let timestampIntervals = zip(
      collection.observationTimestampsUTC,
      collection.observationTimestampsUTC.dropFirst()
    ).map { pair in
      pair.1.timeIntervalSince(pair.0)
    }
    let expectedDuration =
      Double(max(0, requestedSampleCount - 1))
      * MemoryWatcherFoundation.sampleInterval
    let observedDuration = lastUptime - firstUptime
    let minimumInterval = uptimeIntervals.min() ?? 0
    let maximumInterval = uptimeIntervals.max() ?? 0
    let uptimeOrderValid = uptimeIntervals.allSatisfy { $0 > 0 }
    let timestampOrderValid = timestampIntervals.allSatisfy { $0 > 0 }
    let intervalBoundsPass =
      requestedSampleCount == 1
      || (minimumInterval >= 4 && maximumInterval <= 7)
    let durationTolerance = max(1, expectedDuration * 0.05)
    let durationPass =
      abs(observedDuration - expectedDuration) <= durationTolerance
    let firstPhysicalMemory = samples.first?.physicalMemoryBytes ?? 0
    let physicalMemoryStable =
      !samples.isEmpty
      && samples.allSatisfy {
        $0.physicalMemoryBytes == firstPhysicalMemory
      }
    let invalidSampleCount = samples.reduce(into: 0) { count, sample in
      if (try? MemorySampleValidator.validate(sample)) == nil {
        count += 1
      }
    }
    let estimatedApplicationMemory = samples.map { sample in
      (sample.rawPageCounts.internalPages - sample.rawPageCounts.purgeable)
        * sample.pageSizeBytes
    }
    let unclassifiedMemoryUsed = zip(
      samples,
      estimatedApplicationMemory
    ).map { sample, applicationMemory in
      sample.estimatedMemoryUsedBytes
        - applicationMemory
        - sample.wiredBytes
        - sample.compressedBytes
    }
    let completedSlotCount = samples.count + gaps.count
    let basePass =
      completedSlotCount == requestedSampleCount
      && !samples.isEmpty
      && uptimeOrderValid
      && timestampOrderValid
      && intervalBoundsPass
      && durationPass
      && physicalMemoryStable
      && invalidSampleCount == 0
    let status =
      basePass
      ? (gaps.isEmpty ? "PASS" : "PASS_WITH_GAPS")
      : "FAIL"
    let rejectedReasonCounts = Dictionary(
      grouping: gaps,
      by: { $0.lastInconsistency.reason.rawValue }
    ).mapValues(\.count)
    let acceptedAttemptCounts = samples.map(\.acquisitionAttemptCount)
    let rejectedAttemptCounts = gaps.map(\.acquisitionAttemptCount)

    return ProbeSummary(
      calculationVersion: MemoryMetricsCalculator.calculationVersion,
      compressedBytesMaximum: samples.map(\.compressedBytes).max() ?? 0,
      compressedBytesMinimum: samples.map(\.compressedBytes).min() ?? 0,
      estimatedApplicationMemoryBytesMaximum:
        estimatedApplicationMemory.max() ?? 0,
      estimatedApplicationMemoryBytesMinimum:
        estimatedApplicationMemory.min() ?? 0,
      estimatedCachedFilesBytesMaximum: samples.map(
        \.estimatedCachedFilesBytes
      ).max() ?? 0,
      estimatedCachedFilesBytesMinimum: samples.map(
        \.estimatedCachedFilesBytes
      ).min() ?? 0,
      estimatedMemoryUsedBytesMaximum: samples.map(
        \.estimatedMemoryUsedBytes
      ).max() ?? 0,
      estimatedMemoryUsedBytesMinimum: samples.map(
        \.estimatedMemoryUsedBytes
      ).min() ?? 0,
      expectedDurationSeconds: expectedDuration,
      expectedIntervalSeconds: MemoryWatcherFoundation.sampleInterval,
      firstSystemUptimeSeconds: firstUptime,
      firstTimestampUTC: firstTimestamp,
      invalidSampleCount: invalidSampleCount,
      lastSystemUptimeSeconds: lastUptime,
      lastTimestampUTC: lastTimestamp,
      maximumAcquisitionAttemptCount: (acceptedAttemptCounts + rejectedAttemptCounts).max() ?? 0,
      maximumObservedIntervalSeconds: maximumInterval,
      maximumRejectedExcessBytes: gaps.map {
        $0.lastInconsistency.excessBytes
      }.max() ?? 0,
      minimumObservedIntervalSeconds: minimumInterval,
      observedDurationSeconds: observedDuration,
      observedSampleCount: samples.count,
      physicalMemoryBytes: firstPhysicalMemory,
      rejectedReasonCounts: rejectedReasonCounts,
      rejectedSampleCount: gaps.count,
      requestedSampleCount: requestedSampleCount,
      retriedSampleCount: samples.filter {
        $0.acquisitionQuality == .retried
      }.count,
      status: status,
      swapUsedBytesMaximum: samples.map(\.swapUsedBytes).max() ?? 0,
      swapUsedBytesMinimum: samples.map(\.swapUsedBytes).min() ?? 0,
      timestampOrderValid: timestampOrderValid,
      unclassifiedMemoryUsedBytesMaximum:
        unclassifiedMemoryUsed.max() ?? 0,
      unclassifiedMemoryUsedBytesMinimum:
        unclassifiedMemoryUsed.min() ?? 0,
      uptimeOrderValid: uptimeOrderValid,
      wiredBytesMaximum: samples.map(\.wiredBytes).max() ?? 0,
      wiredBytesMinimum: samples.map(\.wiredBytes).min() ?? 0
    )
  }
}
