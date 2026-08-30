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
      let comparisonURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
      let comparisons = try decoder.decode(
        [MemoryActivityMonitorComparison].self,
        from: Data(contentsOf: comparisonURL)
      )
      let report = try auditor.makeReport(
        checkpoint: checkpoint,
        activityMonitorComparisons: comparisons
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
}
