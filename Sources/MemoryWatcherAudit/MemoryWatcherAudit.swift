import Foundation
import MemoryWatcherCore

@main
enum MemoryWatcherAudit {
  static func main() {
    do {
      try run()
    } catch {
      writeJSON([
        "error": String(describing: error),
        "status": "HOLD",
      ])
      exit(1)
    }
  }

  private static func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
      throw AuditCommandError.usage
    }
    let database = try MemoryWatcherDatabase(url: MemoryWatcherDatabase.defaultURL())
    let auditor = MemoryRunAuditor(database: database)
    switch command {
    case "checkpoint":
      guard arguments.count == 3 else {
        throw AuditCommandError.usage
      }
      let checkpoint = try auditor.makeCheckpoint()
      let data = try encoder.encode(checkpoint)
      let destination = URL(fileURLWithPath: arguments[1]).standardizedFileURL
      try data.write(to: destination, options: .atomic)
      let comparisonsDestination = URL(fileURLWithPath: arguments[2])
        .standardizedFileURL
      try encoder.encode([MemoryActivityMonitorComparison]()).write(
        to: comparisonsDestination,
        options: .atomic
      )
      writeData(data)
    case "observe":
      guard
        arguments.count == 11,
        let physical = Double(arguments[3]),
        let used = Double(arguments[4]),
        let wired = Double(arguments[5]),
        let compressed = Double(arguments[6]),
        let cached = Double(arguments[7]),
        let swap = Double(arguments[8]),
        ["explained", "unexplained"].contains(arguments[9]),
        let sample = try database.fetchSamples().last
      else {
        throw AuditCommandError.usage
      }
      let comparisonURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
      var comparisons = try decoder.decode(
        [MemoryActivityMonitorComparison].self,
        from: Data(contentsOf: comparisonURL)
      )
      let comparison = MemoryActivityMonitorComparison(
        label: arguments[2],
        observedAtUTC: Date(),
        memoryWatcherSampleUTC: sample.timestampUTC,
        activityMonitor: metricValues(
          physicalGiB: physical,
          usedGiB: used,
          wiredGiB: wired,
          compressedGiB: compressed,
          cachedGiB: cached,
          swapGiB: swap
        ),
        memoryWatcher: MemoryAuditMetricValues(
          physicalMemoryBytes: Double(sample.physicalMemoryBytes),
          memoryUsedBytes: Double(sample.estimatedMemoryUsedBytes),
          wiredBytes: Double(sample.wiredBytes),
          compressedBytes: Double(sample.compressedBytes),
          cachedFilesBytes: Double(sample.estimatedCachedFilesBytes),
          swapUsedBytes: Double(sample.swapUsedBytes)
        ),
        differencesExplained: arguments[9] == "explained",
        explanation: arguments[10]
      )
      comparisons.append(comparison)
      try encoder.encode(comparisons).write(to: comparisonURL, options: .atomic)
      writeData(try encoder.encode(comparison))
    case "report":
      guard arguments.count == 3 else {
        throw AuditCommandError.usage
      }
      let checkpointURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
      let checkpoint = try decoder.decode(
        MemoryRunAuditCheckpoint.self,
        from: Data(contentsOf: checkpointURL)
      )
      let restoredCheckpoint = AuditCheckpointPrecision.restoringHistoryMarker(
        in: checkpoint,
        sampleTimestamps: try database.fetchSamples().map(\.timestampUTC)
      )
      let comparisonURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
      let comparisons = try decoder.decode(
        [MemoryActivityMonitorComparison].self,
        from: Data(contentsOf: comparisonURL)
      )
      let report = try auditor.makeReport(
        checkpoint: restoredCheckpoint,
        activityMonitorComparisons: comparisons
      )
      writeData(try encoder.encode(report))
      if report.disposition == .hold {
        exit(2)
      }
    case "resource-checkpoint":
      guard
        arguments.count == 6,
        let processIdentifier = Int32(arguments[3]),
        let networkMatchCount = Int(arguments[4]),
        let notificationMatchCount = Int(arguments[5])
      else {
        throw AuditCommandError.usage
      }
      let checkpointURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
      let observationsURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
      guard
        !FileManager.default.fileExists(atPath: checkpointURL.path),
        !FileManager.default.fileExists(atPath: observationsURL.path)
      else {
        throw AuditCommandError.destinationExists
      }
      let resourceAuditor = MemoryResourceAuditor()
      let checkpoint = resourceAuditor.makeCheckpoint(
        processIdentifier: processIdentifier,
        forbiddenNetworkAPIMatchCount: networkMatchCount,
        forbiddenNotificationAPIMatchCount: notificationMatchCount,
        initialIntegrityCheck: try database.integrityCheck()
      )
      try FileManager.default.createDirectory(
        at: checkpointURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data = try encoder.encode(checkpoint)
      try data.write(to: checkpointURL, options: .atomic)
      try encoder.encode([MemoryResourceObservation]()).write(
        to: observationsURL,
        options: .atomic
      )
      writeData(data)
    case "resource-observe":
      guard arguments.count == 3 else {
        throw AuditCommandError.usage
      }
      let checkpointURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
      let observationsURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
      let checkpoint = try decoder.decode(
        MemoryResourceAuditCheckpoint.self,
        from: Data(contentsOf: checkpointURL)
      )
      var observations = try decoder.decode(
        [MemoryResourceObservation].self,
        from: Data(contentsOf: observationsURL)
      )
      let observation = try ProcessResourceCollector(database: database).collect(
        processIdentifier: checkpoint.targetProcessIdentifier
      )
      observations.append(observation)
      try encoder.encode(observations).write(to: observationsURL, options: .atomic)
      writeData(try encoder.encode(observation))
    case "resource-report":
      guard arguments.count == 3 else {
        throw AuditCommandError.usage
      }
      let checkpointURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
      let observationsURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
      let checkpoint = try decoder.decode(
        MemoryResourceAuditCheckpoint.self,
        from: Data(contentsOf: checkpointURL)
      )
      let observations = try decoder.decode(
        [MemoryResourceObservation].self,
        from: Data(contentsOf: observationsURL)
      )
      let report = MemoryResourceAuditor().makeReport(
        checkpoint: checkpoint,
        observations: observations,
        currentIntegrityCheck: try database.integrityCheck()
      )
      writeData(try encoder.encode(report))
      if report.disposition == .hold {
        exit(2)
      }
    default:
      throw AuditCommandError.usage
    }
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private static func metricValues(
    physicalGiB: Double,
    usedGiB: Double,
    wiredGiB: Double,
    compressedGiB: Double,
    cachedGiB: Double,
    swapGiB: Double
  ) -> MemoryAuditMetricValues {
    let gibibyte = 1_073_741_824.0
    return MemoryAuditMetricValues(
      physicalMemoryBytes: physicalGiB * gibibyte,
      memoryUsedBytes: usedGiB * gibibyte,
      wiredBytes: wiredGiB * gibibyte,
      compressedBytes: compressedGiB * gibibyte,
      cachedFilesBytes: cachedGiB * gibibyte,
      swapUsedBytes: swapGiB * gibibyte
    )
  }

  private static func writeJSON(_ value: [String: String]) {
    let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    if let data {
      writeData(data)
    }
  }

  private static func writeData(_ data: Data) {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
  }
}

private enum AuditCommandError: Error {
  case usage
  case destinationExists
  case processUnavailable
  case invalidProcessOutput
  case commandFailed
}

private struct ProcessResourceCollector {
  let database: MemoryWatcherDatabase

  func collect(processIdentifier: Int32) throws -> MemoryResourceObservation {
    let processResult = try runCommand(
      executable: "/bin/ps",
      arguments: [
        "-p", String(processIdentifier), "-o", "time=", "-o", "rss=",
      ]
    )
    guard processResult.status == 0 else {
      throw AuditCommandError.processUnavailable
    }
    let fields = processResult.output.split(whereSeparator: \.isWhitespace)
    guard
      fields.count == 2,
      let cumulativeCPUSeconds = parseCPUTime(String(fields[0])),
      let residentMemoryKilobytes = UInt64(fields[1])
    else {
      throw AuditCommandError.invalidProcessOutput
    }

    return MemoryResourceObservation(
      observedAtUTC: Date(),
      processIdentifier: processIdentifier,
      cumulativeCPUSeconds: cumulativeCPUSeconds,
      residentMemoryBytes: residentMemoryKilobytes * 1_024,
      internetSocketCount: try internetSocketCount(
        processIdentifier: processIdentifier
      ),
      databaseFileSetBytes: try databaseFileSetBytes(),
      rawSampleCount: try database.sampleCount(),
      oneMinuteAggregateCount: try database.aggregateCount(resolution: .oneMinute),
      fiveMinuteAggregateCount: try database.aggregateCount(resolution: .fiveMinutes)
    )
  }

  private func internetSocketCount(processIdentifier: Int32) throws -> Int {
    let result = try runCommand(
      executable: "/usr/sbin/lsof",
      arguments: [
        "-a", "-p", String(processIdentifier), "-i", "-n", "-P",
      ]
    )
    let lines = result.output.split(whereSeparator: \.isNewline)
    if result.status == 0 {
      return max(0, lines.count - 1)
    }
    if result.status == 1, lines.isEmpty {
      return 0
    }
    throw AuditCommandError.commandFailed
  }

  private func databaseFileSetBytes() throws -> UInt64 {
    try ["", "-wal", "-shm"].reduce(into: UInt64(0)) { total, suffix in
      let path = database.url.path + suffix
      guard FileManager.default.fileExists(atPath: path) else {
        return
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      if let size = attributes[.size] as? NSNumber {
        total += size.uint64Value
      }
    }
  }

  private func parseCPUTime(_ value: String) -> TimeInterval? {
    let dayAndTime = value.split(separator: "-", maxSplits: 1)
    let days: Double
    let time: Substring
    if dayAndTime.count == 2 {
      guard let parsedDays = Double(dayAndTime[0]) else {
        return nil
      }
      days = parsedDays
      time = dayAndTime[1]
    } else {
      days = 0
      time = Substring(value)
    }

    let parts = time.split(separator: ":")
    guard
      (2...3).contains(parts.count),
      let seconds = Double(parts[parts.count - 1]),
      let minutes = Double(parts[parts.count - 2])
    else {
      return nil
    }
    let hours: Double
    if parts.count == 3 {
      guard let parsedHours = Double(parts[0]) else {
        return nil
      }
      hours = parsedHours
    } else {
      hours = 0
    }
    return days * 86_400 + hours * 3_600 + minutes * 60 + seconds
  }

  private func runCommand(
    executable: String,
    arguments: [String]
  ) throws -> (status: Int32, output: String) {
    let outputPipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    return (
      status: process.terminationStatus,
      output: String(decoding: data, as: UTF8.self)
    )
  }
}
