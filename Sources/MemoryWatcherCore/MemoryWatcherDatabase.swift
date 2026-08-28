import CSQLite
import Foundation

public enum MemoryWatcherDatabaseError: Error, Equatable, Sendable {
  case sqliteFailure(operation: String, code: Int32, message: String)
  case invalidValue(field: String)
  case unexpectedRow(operation: String)
  case unsupportedSchemaVersion(Int32)
}

public final class MemoryWatcherDatabase: @unchecked Sendable {
  public static let currentSchemaVersion: Int32 = 3

  public let url: URL

  private let lock = NSLock()
  private var connection: OpaquePointer?

  public static func defaultURL(
    fileManager: FileManager = .default
  ) throws -> URL {
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return
      applicationSupport
      .appendingPathComponent("MemoryWatcher", isDirectory: true)
      .appendingPathComponent("memory-watcher.sqlite3", isDirectory: false)
  }

  public init(url: URL, fileManager: FileManager = .default) throws {
    self.url = url.standardizedFileURL
    try fileManager.createDirectory(
      at: self.url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var openedConnection: OpaquePointer?
    let flags =
      SQLITE_OPEN_READWRITE
      | SQLITE_OPEN_CREATE
      | SQLITE_OPEN_FULLMUTEX
    let openCode = sqlite3_open_v2(
      self.url.path,
      &openedConnection,
      flags,
      nil
    )
    guard openCode == SQLITE_OK, let openedConnection else {
      let message = Self.sqliteMessage(for: openedConnection)
      if let openedConnection {
        sqlite3_close_v2(openedConnection)
      }
      throw MemoryWatcherDatabaseError.sqliteFailure(
        operation: "open",
        code: openCode,
        message: message
      )
    }
    connection = openedConnection

    do {
      sqlite3_extended_result_codes(openedConnection, 1)
      sqlite3_busy_timeout(openedConnection, 5_000)
      try execute("PRAGMA foreign_keys = ON", operation: "enable foreign keys")
      try execute("PRAGMA journal_mode = WAL", operation: "enable WAL")
      try execute("PRAGMA synchronous = NORMAL", operation: "set synchronous mode")
      try migrateIfNeeded()
    } catch {
      sqlite3_close_v2(openedConnection)
      connection = nil
      throw error
    }
  }

  deinit {
    if let connection {
      sqlite3_close_v2(connection)
    }
  }

  public func schemaVersion() throws -> Int32 {
    try locked {
      let value = try scalarInt64(
        "PRAGMA user_version",
        operation: "read schema version"
      )
      guard value >= 0, value <= Int64(Int32.max) else {
        throw MemoryWatcherDatabaseError.unexpectedRow(
          operation: "read schema version"
        )
      }
      return Int32(value)
    }
  }

  public func insert(samples: [MemorySample]) throws {
    guard !samples.isEmpty else {
      return
    }
    try locked {
      try transaction(operation: "insert memory samples") {
        let statement = try prepare(
          Self.insertSampleSQL,
          operation: "prepare memory sample insert"
        )
        defer { sqlite3_finalize(statement) }

        for sample in samples {
          try MemorySampleValidator.validate(sample)
          sqlite3_reset(statement)
          sqlite3_clear_bindings(statement)
          try bind(sample: sample, to: statement)
          try stepDone(statement, operation: "insert memory sample")
        }
      }
    }
  }

  public func insert(
    pressureObservations: [MemoryPressureObservation]
  ) throws {
    guard !pressureObservations.isEmpty else {
      return
    }
    try locked {
      try transaction(operation: "insert memory pressure observations") {
        let statement = try prepare(
          Self.insertPressureSQL,
          operation: "prepare memory pressure insert"
        )
        defer { sqlite3_finalize(statement) }

        for observation in pressureObservations {
          sqlite3_reset(statement)
          sqlite3_clear_bindings(statement)
          try bind(
            Self.microseconds(
              since1970: observation.timestampUTC,
              field: "pressure timestamp"
            ),
            at: 1,
            to: statement,
            operation: "bind pressure timestamp"
          )
          try bind(
            Self.microseconds(
              interval: observation.systemUptimeSeconds,
              field: "pressure uptime"
            ),
            at: 2,
            to: statement,
            operation: "bind pressure uptime"
          )
          try bind(
            observation.level.rawValue,
            at: 3,
            to: statement,
            operation: "bind pressure level"
          )
          try stepDone(statement, operation: "insert memory pressure observation")
        }
      }
    }
  }

  public func insert(gaps: [MemorySamplingGap]) throws {
    guard !gaps.isEmpty else {
      return
    }
    try locked {
      try transaction(operation: "insert memory sampling gaps") {
        let statement = try prepare(
          Self.insertGapSQL,
          operation: "prepare memory sampling gap insert"
        )
        defer { sqlite3_finalize(statement) }

        for gap in gaps {
          sqlite3_reset(statement)
          sqlite3_clear_bindings(statement)
          try bind(gap: gap, to: statement)
          try stepDone(statement, operation: "insert memory sampling gap")
        }
      }
    }
  }

  public func insert(lifecycleEvents: [SystemLifecycleEvent]) throws {
    guard !lifecycleEvents.isEmpty else {
      return
    }
    try locked {
      try transaction(operation: "insert system lifecycle events") {
        let statement = try prepare(
          Self.insertLifecycleSQL,
          operation: "prepare system lifecycle insert"
        )
        defer { sqlite3_finalize(statement) }

        for event in lifecycleEvents {
          sqlite3_reset(statement)
          sqlite3_clear_bindings(statement)
          try bind(
            Self.microseconds(
              since1970: event.timestampUTC,
              field: "lifecycle timestamp"
            ),
            at: 1,
            to: statement,
            operation: "bind lifecycle timestamp"
          )
          try bind(
            Self.microseconds(
              interval: event.systemUptimeSeconds,
              field: "lifecycle uptime"
            ),
            at: 2,
            to: statement,
            operation: "bind lifecycle uptime"
          )
          try bind(
            event.kind.rawValue,
            at: 3,
            to: statement,
            operation: "bind lifecycle kind"
          )
          try stepDone(statement, operation: "insert system lifecycle event")
        }
      }
    }
  }

  public func sampleCount() throws -> Int {
    try locked {
      try countRows(in: "memory_samples")
    }
  }

  public func pressureObservationCount() throws -> Int {
    try locked {
      try countRows(in: "memory_pressure_observations")
    }
  }

  public func samplingGapCount() throws -> Int {
    try locked {
      try countRows(in: "memory_sampling_gaps")
    }
  }

  public func lifecycleEventCount() throws -> Int {
    try locked {
      try countRows(in: "system_lifecycle_events")
    }
  }

  public func aggregateCount(
    resolution: MemoryHistoryResolution
  ) throws -> Int {
    try locked {
      try countRows(in: aggregateTable(for: resolution))
    }
  }

  public func fetchAggregates(
    resolution: MemoryHistoryResolution
  ) throws -> [MemoryHistoryAggregate] {
    try locked {
      let statement = try prepare(
        selectAggregatesSQL(for: resolution),
        operation: "prepare memory history aggregate read"
      )
      defer { sqlite3_finalize(statement) }
      var aggregates: [MemoryHistoryAggregate] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE {
          return aggregates
        }
        guard code == SQLITE_ROW else {
          throw sqliteError(
            operation: "read memory history aggregates",
            code: code
          )
        }
        aggregates.append(
          try decodeAggregate(from: statement, resolution: resolution)
        )
      }
    }
  }

  public func performHistoryMaintenance(
    now: Date = Date()
  ) throws -> MemoryHistoryMaintenanceResult {
    try performHistoryMaintenance(now: now, beforeSourceDeletion: {})
  }

  func performHistoryMaintenance(
    now: Date,
    beforeSourceDeletion: () throws -> Void
  ) throws -> MemoryHistoryMaintenanceResult {
    let nowMicroseconds = try Self.microseconds(
      since1970: now,
      field: "history maintenance timestamp"
    )
    let minute = Self.oneMinuteMicroseconds
    let fiveMinutes = Self.fiveMinuteMicroseconds
    let completedMinuteCutoff = nowMicroseconds / minute * minute
    let completedFiveMinuteCutoff =
      nowMicroseconds / fiveMinutes * fiveMinutes
    let rawCutoff = max(
      0,
      nowMicroseconds - Self.rawRetentionMicroseconds
    )
    let oneMinuteCutoff = max(
      0,
      nowMicroseconds - Self.oneMinuteRetentionMicroseconds
    )
    let fiveMinuteCutoff = max(
      0,
      nowMicroseconds - Self.fiveMinuteRetentionMicroseconds
    )

    return try locked {
      try transaction(operation: "maintain memory history") {
        let oneMinuteBucketsUpserted = try executeReturningChanges(
          Self.upsertOneMinuteAggregatesSQL(
            completedBefore: completedMinuteCutoff
          ),
          operation: "upsert one-minute memory aggregates"
        )
        let fiveMinuteBucketsUpserted = try executeReturningChanges(
          Self.upsertFiveMinuteAggregatesSQL(
            completedBefore: completedFiveMinuteCutoff
          ),
          operation: "upsert five-minute memory aggregates"
        )

        try beforeSourceDeletion()

        let rawSamplesDeleted = try executeReturningChanges(
          Self.deleteRawSamplesSQL(olderThan: rawCutoff),
          operation: "delete aggregated raw memory samples"
        )
        let oneMinuteBucketsDeleted = try executeReturningChanges(
          Self.deleteOneMinuteAggregatesSQL(
            completedBefore: oneMinuteCutoff
          ),
          operation: "delete rolled-up one-minute aggregates"
        )
        let fiveMinuteBucketsDeleted = try executeReturningChanges(
          Self.deleteFiveMinuteAggregatesSQL(
            completedBefore: fiveMinuteCutoff
          ),
          operation: "delete expired five-minute aggregates"
        )
        let pressureObservationsDeleted = try executeReturningChanges(
          Self.deleteRowsSQL(
            table: "memory_pressure_observations",
            olderThan: fiveMinuteCutoff
          ),
          operation: "delete expired memory pressure observations"
        )
        let samplingGapsDeleted = try executeReturningChanges(
          Self.deleteRowsSQL(
            table: "memory_sampling_gaps",
            olderThan: fiveMinuteCutoff
          ),
          operation: "delete expired memory sampling gaps"
        )
        let lifecycleEventsDeleted = try executeReturningChanges(
          Self.deleteRowsSQL(
            table: "system_lifecycle_events",
            olderThan: fiveMinuteCutoff
          ),
          operation: "delete expired system lifecycle events"
        )

        return MemoryHistoryMaintenanceResult(
          oneMinuteBucketsUpserted: oneMinuteBucketsUpserted,
          fiveMinuteBucketsUpserted: fiveMinuteBucketsUpserted,
          rawSamplesDeleted: rawSamplesDeleted,
          oneMinuteBucketsDeleted: oneMinuteBucketsDeleted,
          fiveMinuteBucketsDeleted: fiveMinuteBucketsDeleted,
          pressureObservationsDeleted: pressureObservationsDeleted,
          samplingGapsDeleted: samplingGapsDeleted,
          lifecycleEventsDeleted: lifecycleEventsDeleted
        )
      }
    }
  }

  public func fetchSamples() throws -> [MemorySample] {
    try locked {
      let statement = try prepare(
        Self.selectSamplesSQL,
        operation: "prepare memory sample read"
      )
      defer { sqlite3_finalize(statement) }
      var samples: [MemorySample] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE {
          return samples
        }
        guard code == SQLITE_ROW else {
          throw sqliteError(operation: "read memory samples", code: code)
        }
        samples.append(try decodeSample(from: statement))
      }
    }
  }

  public func fetchPressureObservations() throws -> [MemoryPressureObservation] {
    try locked {
      let statement = try prepare(
        Self.selectPressureSQL,
        operation: "prepare memory pressure read"
      )
      defer { sqlite3_finalize(statement) }
      var observations: [MemoryPressureObservation] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE {
          return observations
        }
        guard code == SQLITE_ROW else {
          throw sqliteError(
            operation: "read memory pressure observations",
            code: code
          )
        }
        guard
          let rawLevel = text(at: 2, from: statement),
          let level = MemoryPressureLevel(rawValue: rawLevel)
        else {
          throw MemoryWatcherDatabaseError.unexpectedRow(
            operation: "decode memory pressure observation"
          )
        }
        observations.append(
          MemoryPressureObservation(
            timestampUTC: Self.date(
              fromMicroseconds: sqlite3_column_int64(statement, 0)
            ),
            systemUptimeSeconds: Self.interval(
              fromMicroseconds: sqlite3_column_int64(statement, 1)
            ),
            level: level
          )
        )
      }
    }
  }

  public func fetchSamplingGaps() throws -> [MemorySamplingGap] {
    try locked {
      let statement = try prepare(
        Self.selectGapsSQL,
        operation: "prepare memory sampling gap read"
      )
      defer { sqlite3_finalize(statement) }
      var gaps: [MemorySamplingGap] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE {
          return gaps
        }
        guard code == SQLITE_ROW else {
          throw sqliteError(operation: "read memory sampling gaps", code: code)
        }
        gaps.append(try decodeGap(from: statement))
      }
    }
  }

  public func fetchLifecycleEvents() throws -> [SystemLifecycleEvent] {
    try locked {
      let statement = try prepare(
        Self.selectLifecycleSQL,
        operation: "prepare system lifecycle read"
      )
      defer { sqlite3_finalize(statement) }
      var events: [SystemLifecycleEvent] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE {
          return events
        }
        guard code == SQLITE_ROW else {
          throw sqliteError(operation: "read system lifecycle events", code: code)
        }
        guard
          let rawKind = text(at: 2, from: statement),
          let kind = SystemLifecycleEventKind(rawValue: rawKind)
        else {
          throw MemoryWatcherDatabaseError.unexpectedRow(
            operation: "decode system lifecycle event"
          )
        }
        events.append(
          SystemLifecycleEvent(
            timestampUTC: Self.date(
              fromMicroseconds: sqlite3_column_int64(statement, 0)
            ),
            systemUptimeSeconds: Self.interval(
              fromMicroseconds: sqlite3_column_int64(statement, 1)
            ),
            kind: kind
          )
        )
      }
    }
  }

  public func latestSampleAnchor() throws -> SystemTimelineAnchor? {
    try locked {
      let statement = try prepare(
        Self.selectLatestSampleAnchorSQL,
        operation: "prepare latest sample anchor read"
      )
      defer { sqlite3_finalize(statement) }
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE {
        return nil
      }
      guard code == SQLITE_ROW else {
        throw sqliteError(operation: "read latest sample anchor", code: code)
      }
      return SystemTimelineAnchor(
        timestampUTC: Self.date(
          fromMicroseconds: sqlite3_column_int64(statement, 0)
        ),
        systemUptimeSeconds: Self.interval(
          fromMicroseconds: sqlite3_column_int64(statement, 1)
        )
      )
    }
  }

  public func integrityCheck() throws -> String {
    try locked {
      let statement = try prepare(
        "PRAGMA integrity_check",
        operation: "prepare integrity check"
      )
      defer { sqlite3_finalize(statement) }
      var rows: [String] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE {
          break
        }
        guard code == SQLITE_ROW, let value = text(at: 0, from: statement) else {
          throw sqliteError(operation: "run integrity check", code: code)
        }
        rows.append(value)
      }
      return rows.joined(separator: "\n")
    }
  }

  private func migrateIfNeeded() throws {
    var version = try scalarInt64(
      "PRAGMA user_version",
      operation: "read schema version for migration"
    )
    guard version <= Int64(Self.currentSchemaVersion) else {
      throw MemoryWatcherDatabaseError.unsupportedSchemaVersion(Int32(version))
    }
    if version == 0 {
      try migrateToVersion1()
      version = 1
    }
    if version == 1 {
      try migrateToVersion2()
      version = 2
    }
    if version == 2 {
      try migrateToVersion3()
      version = 3
    }
    guard version == Int64(Self.currentSchemaVersion) else {
      throw MemoryWatcherDatabaseError.unsupportedSchemaVersion(Int32(version))
    }
  }

  private func migrateToVersion1() throws {
    try transaction(operation: "migrate schema to version 1") {
      try execute(Self.schemaVersion1SQL, operation: "create schema version 1")
      try recordMigration(version: 1)
      try execute("PRAGMA user_version = 1", operation: "set schema version 1")
    }
  }

  private func migrateToVersion2() throws {
    try transaction(operation: "migrate schema to version 2") {
      try execute(Self.schemaVersion2SQL, operation: "create schema version 2")
      try recordMigration(version: 2)
      try execute("PRAGMA user_version = 2", operation: "set schema version 2")
    }
  }

  private func migrateToVersion3() throws {
    try transaction(operation: "migrate schema to version 3") {
      try execute(Self.schemaVersion3SQL, operation: "create schema version 3")
      try recordMigration(version: 3)
      try execute("PRAGMA user_version = 3", operation: "set schema version 3")
    }
  }

  private func recordMigration(version: Int32) throws {
    let appliedAt = try Self.microseconds(
      since1970: Date(),
      field: "migration timestamp"
    )
    try execute(
      "INSERT INTO schema_migrations(version, applied_at_utc_microseconds) "
        + "VALUES (\(version), \(appliedAt))",
      operation: "record schema version \(version)"
    )
  }

  private func transaction<T>(
    operation: String,
    _ body: () throws -> T
  ) throws -> T {
    try execute("BEGIN IMMEDIATE", operation: "\(operation): begin")
    do {
      let result = try body()
      try execute("COMMIT", operation: "\(operation): commit")
      return result
    } catch {
      try? execute("ROLLBACK", operation: "\(operation): rollback")
      throw error
    }
  }

  private func execute(_ sql: String, operation: String) throws {
    guard let connection else {
      throw MemoryWatcherDatabaseError.sqliteFailure(
        operation: operation,
        code: SQLITE_MISUSE,
        message: "database connection is unavailable"
      )
    }
    var errorMessage: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
    guard code == SQLITE_OK else {
      let message =
        errorMessage.map { String(cString: $0) }
        ?? Self.sqliteMessage(for: connection)
      if let errorMessage {
        sqlite3_free(errorMessage)
      }
      throw MemoryWatcherDatabaseError.sqliteFailure(
        operation: operation,
        code: code,
        message: message
      )
    }
  }

  private func executeReturningChanges(
    _ sql: String,
    operation: String
  ) throws -> Int {
    try execute(sql, operation: operation)
    guard let connection else {
      throw MemoryWatcherDatabaseError.sqliteFailure(
        operation: operation,
        code: SQLITE_MISUSE,
        message: "database connection is unavailable"
      )
    }
    let changes = sqlite3_changes64(connection)
    guard changes >= 0, let count = Int(exactly: changes) else {
      throw MemoryWatcherDatabaseError.unexpectedRow(operation: operation)
    }
    return count
  }

  private func prepare(_ sql: String, operation: String) throws -> OpaquePointer {
    guard let connection else {
      throw MemoryWatcherDatabaseError.sqliteFailure(
        operation: operation,
        code: SQLITE_MISUSE,
        message: "database connection is unavailable"
      )
    }
    var statement: OpaquePointer?
    let code = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
    guard code == SQLITE_OK, let statement else {
      throw sqliteError(operation: operation, code: code)
    }
    return statement
  }

  private func scalarInt64(_ sql: String, operation: String) throws -> Int64 {
    let statement = try prepare(sql, operation: operation)
    defer { sqlite3_finalize(statement) }
    let code = sqlite3_step(statement)
    guard code == SQLITE_ROW else {
      throw sqliteError(operation: operation, code: code)
    }
    let value = sqlite3_column_int64(statement, 0)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw MemoryWatcherDatabaseError.unexpectedRow(operation: operation)
    }
    return value
  }

  private func countRows(in table: String) throws -> Int {
    let allowedTables = [
      "memory_samples",
      "memory_pressure_observations",
      "memory_sampling_gaps",
      "system_lifecycle_events",
      "memory_aggregates_1m",
      "memory_aggregates_5m",
    ]
    guard allowedTables.contains(table) else {
      throw MemoryWatcherDatabaseError.invalidValue(field: "table")
    }
    let value = try scalarInt64(
      "SELECT COUNT(*) FROM \(table)",
      operation: "count \(table)"
    )
    guard value >= 0, let count = Int(exactly: value) else {
      throw MemoryWatcherDatabaseError.unexpectedRow(operation: "count \(table)")
    }
    return count
  }

  private func aggregateTable(
    for resolution: MemoryHistoryResolution
  ) -> String {
    switch resolution {
    case .oneMinute:
      return "memory_aggregates_1m"
    case .fiveMinutes:
      return "memory_aggregates_5m"
    }
  }

  private func selectAggregatesSQL(
    for resolution: MemoryHistoryResolution
  ) -> String {
    """
    SELECT
      bucket_start_utc_microseconds,
      sample_count,
      average_physical_memory_bytes,
      average_estimated_memory_used_bytes,
      average_wired_bytes,
      average_compressed_bytes,
      average_estimated_cached_files_bytes,
      average_swap_used_bytes
    FROM \(aggregateTable(for: resolution))
    ORDER BY bucket_start_utc_microseconds
    """
  }

  private func bind(sample: MemorySample, to statement: OpaquePointer) throws {
    let values: [(UInt64, String)] = [
      (sample.physicalMemoryBytes, "physical memory"),
      (sample.estimatedMemoryUsedBytes, "estimated memory used"),
      (sample.wiredBytes, "wired memory"),
      (sample.compressedBytes, "compressed memory"),
      (sample.estimatedCachedFilesBytes, "estimated cached files"),
      (sample.swapUsedBytes, "swap used"),
      (sample.pageSizeBytes, "page size"),
      (sample.rawPageCounts.free, "free pages"),
      (sample.rawPageCounts.active, "active pages"),
      (sample.rawPageCounts.inactive, "inactive pages"),
      (sample.rawPageCounts.wired, "raw wired pages"),
      (sample.rawPageCounts.speculative, "speculative pages"),
      (sample.rawPageCounts.purgeable, "purgeable pages"),
      (sample.rawPageCounts.compressor, "compressor pages"),
      (sample.rawPageCounts.external, "external pages"),
      (sample.rawPageCounts.internalPages, "internal pages"),
    ]
    try bind(
      Self.microseconds(
        since1970: sample.timestampUTC,
        field: "sample timestamp"
      ),
      at: 1,
      to: statement,
      operation: "bind sample timestamp"
    )
    try bind(
      Self.microseconds(
        interval: sample.systemUptimeSeconds,
        field: "sample uptime"
      ),
      at: 2,
      to: statement,
      operation: "bind sample uptime"
    )
    for (offset, value) in values.enumerated() {
      try bind(
        value.0,
        field: value.1,
        at: Int32(offset + 3),
        to: statement
      )
    }
    try bind(
      sample.calculationVersion,
      at: 19,
      to: statement,
      operation: "bind calculation version"
    )
    try bind(
      sample.acquisitionQuality.rawValue,
      at: 20,
      to: statement,
      operation: "bind acquisition quality"
    )
    try bind(
      Int64(sample.acquisitionAttemptCount),
      at: 21,
      to: statement,
      operation: "bind acquisition attempt count"
    )
  }

  private func bind(gap: MemorySamplingGap, to statement: OpaquePointer) throws {
    let diagnostic = gap.lastInconsistency
    try bind(
      Self.microseconds(since1970: gap.timestampUTC, field: "gap timestamp"),
      at: 1,
      to: statement,
      operation: "bind gap timestamp"
    )
    try bind(
      Self.microseconds(interval: gap.systemUptimeSeconds, field: "gap uptime"),
      at: 2,
      to: statement,
      operation: "bind gap uptime"
    )
    try bind(
      Int64(gap.acquisitionAttemptCount),
      at: 3,
      to: statement,
      operation: "bind gap attempt count"
    )
    try bind(
      diagnostic.reason.rawValue,
      at: 4,
      to: statement,
      operation: "bind gap reason"
    )
    let values: [(UInt64, String)] = [
      (diagnostic.physicalMemoryBytes, "gap physical memory"),
      (diagnostic.pageSizeBytes, "gap page size"),
      (diagnostic.counters.free, "gap free pages"),
      (diagnostic.counters.active, "gap active pages"),
      (diagnostic.counters.inactive, "gap inactive pages"),
      (diagnostic.counters.wired, "gap wired pages"),
      (diagnostic.counters.speculative, "gap speculative pages"),
      (diagnostic.counters.purgeable, "gap purgeable pages"),
      (diagnostic.counters.compressor, "gap compressor pages"),
      (diagnostic.counters.external, "gap external pages"),
      (diagnostic.counters.internalPages, "gap internal pages"),
    ]
    for (offset, value) in values.enumerated() {
      try bind(
        value.0,
        field: value.1,
        at: Int32(offset + 5),
        to: statement
      )
    }
    try bindOptional(
      diagnostic.estimatedMemoryUsedBytes,
      field: "gap estimated memory used",
      at: 16,
      to: statement
    )
    try bindOptional(
      diagnostic.classifiedMemoryUsedBytes,
      field: "gap classified memory used",
      at: 17,
      to: statement
    )
    try bind(
      diagnostic.excessBytes,
      field: "gap excess bytes",
      at: 18,
      to: statement
    )
  }

  private func bind(
    _ value: UInt64,
    field: String,
    at index: Int32,
    to statement: OpaquePointer
  ) throws {
    guard value <= UInt64(Int64.max) else {
      throw MemoryWatcherDatabaseError.invalidValue(field: field)
    }
    try bind(
      Int64(value),
      at: index,
      to: statement,
      operation: "bind \(field)"
    )
  }

  private func bindOptional(
    _ value: UInt64?,
    field: String,
    at index: Int32,
    to statement: OpaquePointer
  ) throws {
    guard let value else {
      let code = sqlite3_bind_null(statement, index)
      guard code == SQLITE_OK else {
        throw sqliteError(operation: "bind \(field)", code: code)
      }
      return
    }
    try bind(value, field: field, at: index, to: statement)
  }

  private func bind(
    _ value: Int64,
    at index: Int32,
    to statement: OpaquePointer,
    operation: String
  ) throws {
    let code = sqlite3_bind_int64(statement, index, value)
    guard code == SQLITE_OK else {
      throw sqliteError(operation: operation, code: code)
    }
  }

  private func bind(
    _ value: String,
    at index: Int32,
    to statement: OpaquePointer,
    operation: String
  ) throws {
    let code = value.withCString { pointer in
      sqlite3_bind_text(
        statement,
        index,
        pointer,
        -1,
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      )
    }
    guard code == SQLITE_OK else {
      throw sqliteError(operation: operation, code: code)
    }
  }

  private func stepDone(_ statement: OpaquePointer, operation: String) throws {
    let code = sqlite3_step(statement)
    guard code == SQLITE_DONE else {
      throw sqliteError(operation: operation, code: code)
    }
  }

  private func decodeSample(from statement: OpaquePointer) throws -> MemorySample {
    guard
      let calculationVersion = text(at: 18, from: statement),
      let qualityText = text(at: 19, from: statement),
      let quality = MemorySampleAcquisitionQuality(rawValue: qualityText),
      let attemptCount = Int(exactly: sqlite3_column_int64(statement, 20))
    else {
      throw MemoryWatcherDatabaseError.unexpectedRow(
        operation: "decode memory sample"
      )
    }
    let sample = MemorySample(
      timestampUTC: Self.date(
        fromMicroseconds: sqlite3_column_int64(statement, 0)
      ),
      systemUptimeSeconds: Self.interval(
        fromMicroseconds: sqlite3_column_int64(statement, 1)
      ),
      physicalMemoryBytes: try unsigned(at: 2, from: statement),
      estimatedMemoryUsedBytes: try unsigned(at: 3, from: statement),
      wiredBytes: try unsigned(at: 4, from: statement),
      compressedBytes: try unsigned(at: 5, from: statement),
      estimatedCachedFilesBytes: try unsigned(at: 6, from: statement),
      swapUsedBytes: try unsigned(at: 7, from: statement),
      pageSizeBytes: try unsigned(at: 8, from: statement),
      rawPageCounts: RawMemoryPageCounts(
        free: try unsigned(at: 9, from: statement),
        active: try unsigned(at: 10, from: statement),
        inactive: try unsigned(at: 11, from: statement),
        wired: try unsigned(at: 12, from: statement),
        speculative: try unsigned(at: 13, from: statement),
        purgeable: try unsigned(at: 14, from: statement),
        compressor: try unsigned(at: 15, from: statement),
        external: try unsigned(at: 16, from: statement),
        internalPages: try unsigned(at: 17, from: statement)
      ),
      calculationVersion: calculationVersion,
      acquisitionQuality: quality,
      acquisitionAttemptCount: attemptCount
    )
    try MemorySampleValidator.validate(sample)
    return sample
  }

  private func decodeAggregate(
    from statement: OpaquePointer,
    resolution: MemoryHistoryResolution
  ) throws -> MemoryHistoryAggregate {
    let sampleCountValue = sqlite3_column_int64(statement, 1)
    let averages = (2...7).map {
      sqlite3_column_double(statement, Int32($0))
    }
    guard
      sampleCountValue > 0,
      let sampleCount = Int(exactly: sampleCountValue),
      averages.allSatisfy({ $0.isFinite && $0 >= 0 })
    else {
      throw MemoryWatcherDatabaseError.unexpectedRow(
        operation: "decode memory history aggregate"
      )
    }
    return MemoryHistoryAggregate(
      resolution: resolution,
      bucketStartUTC: Self.date(
        fromMicroseconds: sqlite3_column_int64(statement, 0)
      ),
      sampleCount: sampleCount,
      averagePhysicalMemoryBytes: averages[0],
      averageEstimatedMemoryUsedBytes: averages[1],
      averageWiredBytes: averages[2],
      averageCompressedBytes: averages[3],
      averageEstimatedCachedFilesBytes: averages[4],
      averageSwapUsedBytes: averages[5]
    )
  }

  private func decodeGap(from statement: OpaquePointer) throws -> MemorySamplingGap {
    guard
      let attemptCount = Int(exactly: sqlite3_column_int64(statement, 2)),
      let reasonText = text(at: 3, from: statement),
      let reason = MemoryCounterInconsistencyReason(rawValue: reasonText)
    else {
      throw MemoryWatcherDatabaseError.unexpectedRow(
        operation: "decode memory sampling gap"
      )
    }
    return MemorySamplingGap(
      timestampUTC: Self.date(
        fromMicroseconds: sqlite3_column_int64(statement, 0)
      ),
      systemUptimeSeconds: Self.interval(
        fromMicroseconds: sqlite3_column_int64(statement, 1)
      ),
      acquisitionAttemptCount: attemptCount,
      lastInconsistency: MemoryCounterInconsistency(
        reason: reason,
        physicalMemoryBytes: try unsigned(at: 4, from: statement),
        pageSizeBytes: try unsigned(at: 5, from: statement),
        counters: RawMemoryPageCounts(
          free: try unsigned(at: 6, from: statement),
          active: try unsigned(at: 7, from: statement),
          inactive: try unsigned(at: 8, from: statement),
          wired: try unsigned(at: 9, from: statement),
          speculative: try unsigned(at: 10, from: statement),
          purgeable: try unsigned(at: 11, from: statement),
          compressor: try unsigned(at: 12, from: statement),
          external: try unsigned(at: 13, from: statement),
          internalPages: try unsigned(at: 14, from: statement)
        ),
        estimatedMemoryUsedBytes: try optionalUnsigned(at: 15, from: statement),
        classifiedMemoryUsedBytes: try optionalUnsigned(at: 16, from: statement),
        excessBytes: try unsigned(at: 17, from: statement)
      )
    )
  }

  private func unsigned(at index: Int32, from statement: OpaquePointer) throws -> UInt64 {
    let value = sqlite3_column_int64(statement, index)
    guard value >= 0 else {
      throw MemoryWatcherDatabaseError.unexpectedRow(operation: "decode unsigned integer")
    }
    return UInt64(value)
  }

  private func optionalUnsigned(
    at index: Int32,
    from statement: OpaquePointer
  ) throws -> UInt64? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
      return nil
    }
    return try unsigned(at: index, from: statement)
  }

  private func text(at index: Int32, from statement: OpaquePointer) -> String? {
    guard let pointer = sqlite3_column_text(statement, index) else {
      return nil
    }
    return String(cString: pointer)
  }

  private func sqliteError(
    operation: String,
    code: Int32
  ) -> MemoryWatcherDatabaseError {
    .sqliteFailure(
      operation: operation,
      code: code,
      message: Self.sqliteMessage(for: connection)
    )
  }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    try lock.withLock(body)
  }

  private static func sqliteMessage(for connection: OpaquePointer?) -> String {
    guard let connection, let message = sqlite3_errmsg(connection) else {
      return "SQLite error"
    }
    return String(cString: message)
  }

  private static func microseconds(
    since1970 date: Date,
    field: String
  ) throws -> Int64 {
    try microseconds(interval: date.timeIntervalSince1970, field: field)
  }

  private static func microseconds(
    interval: TimeInterval,
    field: String
  ) throws -> Int64 {
    let scaled = interval * 1_000_000
    let rounded = scaled.rounded()
    guard
      interval.isFinite,
      interval >= 0,
      let microseconds = Int64(exactly: rounded)
    else {
      throw MemoryWatcherDatabaseError.invalidValue(field: field)
    }
    return microseconds
  }

  private static func date(fromMicroseconds value: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(value) / 1_000_000)
  }

  private static func interval(fromMicroseconds value: Int64) -> TimeInterval {
    TimeInterval(value) / 1_000_000
  }

  private static let oneMinuteMicroseconds: Int64 = 60 * 1_000_000
  private static let fiveMinuteMicroseconds: Int64 = 5 * oneMinuteMicroseconds
  private static let rawRetentionMicroseconds: Int64 =
    24 * 60 * oneMinuteMicroseconds
  private static let oneMinuteRetentionMicroseconds: Int64 =
    7 * 24 * 60 * oneMinuteMicroseconds
  private static let fiveMinuteRetentionMicroseconds: Int64 =
    30 * 24 * 60 * oneMinuteMicroseconds

  private static func upsertOneMinuteAggregatesSQL(
    completedBefore: Int64
  ) -> String {
    """
    INSERT INTO memory_aggregates_1m(
      bucket_start_utc_microseconds,
      sample_count,
      average_physical_memory_bytes,
      average_estimated_memory_used_bytes,
      average_wired_bytes,
      average_compressed_bytes,
      average_estimated_cached_files_bytes,
      average_swap_used_bytes
    )
    SELECT
      timestamp_utc_microseconds / \(oneMinuteMicroseconds)
        * \(oneMinuteMicroseconds),
      COUNT(*),
      AVG(CAST(physical_memory_bytes AS REAL)),
      AVG(CAST(estimated_memory_used_bytes AS REAL)),
      AVG(CAST(wired_bytes AS REAL)),
      AVG(CAST(compressed_bytes AS REAL)),
      AVG(CAST(estimated_cached_files_bytes AS REAL)),
      AVG(CAST(swap_used_bytes AS REAL))
    FROM memory_samples
    WHERE timestamp_utc_microseconds < \(completedBefore)
    GROUP BY timestamp_utc_microseconds / \(oneMinuteMicroseconds)
    ON CONFLICT(bucket_start_utc_microseconds) DO UPDATE SET
      sample_count = excluded.sample_count,
      average_physical_memory_bytes = excluded.average_physical_memory_bytes,
      average_estimated_memory_used_bytes =
        excluded.average_estimated_memory_used_bytes,
      average_wired_bytes = excluded.average_wired_bytes,
      average_compressed_bytes = excluded.average_compressed_bytes,
      average_estimated_cached_files_bytes =
        excluded.average_estimated_cached_files_bytes,
      average_swap_used_bytes = excluded.average_swap_used_bytes
    """
  }

  private static func upsertFiveMinuteAggregatesSQL(
    completedBefore: Int64
  ) -> String {
    """
    INSERT INTO memory_aggregates_5m(
      bucket_start_utc_microseconds,
      sample_count,
      average_physical_memory_bytes,
      average_estimated_memory_used_bytes,
      average_wired_bytes,
      average_compressed_bytes,
      average_estimated_cached_files_bytes,
      average_swap_used_bytes
    )
    SELECT
      bucket_start_utc_microseconds / \(fiveMinuteMicroseconds)
        * \(fiveMinuteMicroseconds),
      SUM(sample_count),
      SUM(average_physical_memory_bytes * sample_count) / SUM(sample_count),
      SUM(average_estimated_memory_used_bytes * sample_count)
        / SUM(sample_count),
      SUM(average_wired_bytes * sample_count) / SUM(sample_count),
      SUM(average_compressed_bytes * sample_count) / SUM(sample_count),
      SUM(average_estimated_cached_files_bytes * sample_count)
        / SUM(sample_count),
      SUM(average_swap_used_bytes * sample_count) / SUM(sample_count)
    FROM memory_aggregates_1m
    WHERE bucket_start_utc_microseconds < \(completedBefore)
    GROUP BY bucket_start_utc_microseconds / \(fiveMinuteMicroseconds)
    ON CONFLICT(bucket_start_utc_microseconds) DO UPDATE SET
      sample_count = excluded.sample_count,
      average_physical_memory_bytes = excluded.average_physical_memory_bytes,
      average_estimated_memory_used_bytes =
        excluded.average_estimated_memory_used_bytes,
      average_wired_bytes = excluded.average_wired_bytes,
      average_compressed_bytes = excluded.average_compressed_bytes,
      average_estimated_cached_files_bytes =
        excluded.average_estimated_cached_files_bytes,
      average_swap_used_bytes = excluded.average_swap_used_bytes
    """
  }

  private static func deleteRawSamplesSQL(olderThan cutoff: Int64) -> String {
    """
    DELETE FROM memory_samples
    WHERE timestamp_utc_microseconds < \(cutoff)
      AND EXISTS(
        SELECT 1
        FROM memory_aggregates_1m
        WHERE bucket_start_utc_microseconds =
          memory_samples.timestamp_utc_microseconds / \(oneMinuteMicroseconds)
            * \(oneMinuteMicroseconds)
      )
    """
  }

  private static func deleteOneMinuteAggregatesSQL(
    completedBefore cutoff: Int64
  ) -> String {
    """
    DELETE FROM memory_aggregates_1m
    WHERE bucket_start_utc_microseconds + \(oneMinuteMicroseconds) <= \(cutoff)
      AND EXISTS(
        SELECT 1
        FROM memory_aggregates_5m
        WHERE bucket_start_utc_microseconds =
          memory_aggregates_1m.bucket_start_utc_microseconds
            / \(fiveMinuteMicroseconds) * \(fiveMinuteMicroseconds)
      )
    """
  }

  private static func deleteFiveMinuteAggregatesSQL(
    completedBefore cutoff: Int64
  ) -> String {
    """
    DELETE FROM memory_aggregates_5m
    WHERE bucket_start_utc_microseconds + \(fiveMinuteMicroseconds) <= \(cutoff)
    """
  }

  private static func deleteRowsSQL(
    table: String,
    olderThan cutoff: Int64
  ) -> String {
    precondition(
      [
        "memory_pressure_observations",
        "memory_sampling_gaps",
        "system_lifecycle_events",
      ].contains(table)
    )
    return "DELETE FROM \(table) WHERE timestamp_utc_microseconds < \(cutoff)"
  }

  private static let insertSampleSQL = """
    INSERT INTO memory_samples(
      timestamp_utc_microseconds,
      system_uptime_microseconds,
      physical_memory_bytes,
      estimated_memory_used_bytes,
      wired_bytes,
      compressed_bytes,
      estimated_cached_files_bytes,
      swap_used_bytes,
      page_size_bytes,
      raw_free_pages,
      raw_active_pages,
      raw_inactive_pages,
      raw_wired_pages,
      raw_speculative_pages,
      raw_purgeable_pages,
      raw_compressor_pages,
      raw_external_pages,
      raw_internal_pages,
      calculation_version,
      acquisition_quality,
      acquisition_attempt_count
    ) VALUES (
      ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
    )
    """

  private static let insertPressureSQL = """
    INSERT INTO memory_pressure_observations(
      timestamp_utc_microseconds,
      system_uptime_microseconds,
      level
    ) VALUES (?, ?, ?)
    """

  private static let insertGapSQL = """
    INSERT INTO memory_sampling_gaps(
      timestamp_utc_microseconds,
      system_uptime_microseconds,
      acquisition_attempt_count,
      inconsistency_reason,
      physical_memory_bytes,
      page_size_bytes,
      raw_free_pages,
      raw_active_pages,
      raw_inactive_pages,
      raw_wired_pages,
      raw_speculative_pages,
      raw_purgeable_pages,
      raw_compressor_pages,
      raw_external_pages,
      raw_internal_pages,
      estimated_memory_used_bytes,
      classified_memory_used_bytes,
      excess_bytes
    ) VALUES (
      ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
    )
    """

  private static let insertLifecycleSQL = """
    INSERT INTO system_lifecycle_events(
      timestamp_utc_microseconds,
      system_uptime_microseconds,
      kind
    ) VALUES (?, ?, ?)
    """

  private static let selectSamplesSQL = """
    SELECT
      timestamp_utc_microseconds,
      system_uptime_microseconds,
      physical_memory_bytes,
      estimated_memory_used_bytes,
      wired_bytes,
      compressed_bytes,
      estimated_cached_files_bytes,
      swap_used_bytes,
      page_size_bytes,
      raw_free_pages,
      raw_active_pages,
      raw_inactive_pages,
      raw_wired_pages,
      raw_speculative_pages,
      raw_purgeable_pages,
      raw_compressor_pages,
      raw_external_pages,
      raw_internal_pages,
      calculation_version,
      acquisition_quality,
      acquisition_attempt_count
    FROM memory_samples
    ORDER BY timestamp_utc_microseconds, system_uptime_microseconds
    """

  private static let selectPressureSQL = """
    SELECT
      timestamp_utc_microseconds,
      system_uptime_microseconds,
      level
    FROM memory_pressure_observations
    ORDER BY timestamp_utc_microseconds, system_uptime_microseconds, id
    """

  private static let selectGapsSQL = """
    SELECT
      timestamp_utc_microseconds,
      system_uptime_microseconds,
      acquisition_attempt_count,
      inconsistency_reason,
      physical_memory_bytes,
      page_size_bytes,
      raw_free_pages,
      raw_active_pages,
      raw_inactive_pages,
      raw_wired_pages,
      raw_speculative_pages,
      raw_purgeable_pages,
      raw_compressor_pages,
      raw_external_pages,
      raw_internal_pages,
      estimated_memory_used_bytes,
      classified_memory_used_bytes,
      excess_bytes
    FROM memory_sampling_gaps
    ORDER BY timestamp_utc_microseconds, system_uptime_microseconds
    """

  private static let selectLifecycleSQL = """
    SELECT
      timestamp_utc_microseconds,
      system_uptime_microseconds,
      kind
    FROM system_lifecycle_events
    ORDER BY id
    """

  private static let selectLatestSampleAnchorSQL = """
    SELECT
      timestamp_utc_microseconds,
      system_uptime_microseconds
    FROM memory_samples
    ORDER BY id DESC
    LIMIT 1
    """

  private static let schemaVersion1SQL = """
    CREATE TABLE schema_migrations(
      version INTEGER PRIMARY KEY,
      applied_at_utc_microseconds INTEGER NOT NULL CHECK(applied_at_utc_microseconds >= 0)
    );

    CREATE TABLE memory_samples(
      id INTEGER PRIMARY KEY,
      timestamp_utc_microseconds INTEGER NOT NULL CHECK(timestamp_utc_microseconds >= 0),
      system_uptime_microseconds INTEGER NOT NULL CHECK(system_uptime_microseconds >= 0),
      physical_memory_bytes INTEGER NOT NULL CHECK(physical_memory_bytes > 0),
      estimated_memory_used_bytes INTEGER NOT NULL CHECK(estimated_memory_used_bytes >= 0),
      wired_bytes INTEGER NOT NULL CHECK(wired_bytes >= 0),
      compressed_bytes INTEGER NOT NULL CHECK(compressed_bytes >= 0),
      estimated_cached_files_bytes INTEGER NOT NULL CHECK(estimated_cached_files_bytes >= 0),
      swap_used_bytes INTEGER NOT NULL CHECK(swap_used_bytes >= 0),
      page_size_bytes INTEGER NOT NULL CHECK(page_size_bytes > 0),
      raw_free_pages INTEGER NOT NULL CHECK(raw_free_pages >= 0),
      raw_active_pages INTEGER NOT NULL CHECK(raw_active_pages >= 0),
      raw_inactive_pages INTEGER NOT NULL CHECK(raw_inactive_pages >= 0),
      raw_wired_pages INTEGER NOT NULL CHECK(raw_wired_pages >= 0),
      raw_speculative_pages INTEGER NOT NULL CHECK(raw_speculative_pages >= 0),
      raw_purgeable_pages INTEGER NOT NULL CHECK(raw_purgeable_pages >= 0),
      raw_compressor_pages INTEGER NOT NULL CHECK(raw_compressor_pages >= 0),
      raw_external_pages INTEGER NOT NULL CHECK(raw_external_pages >= 0),
      raw_internal_pages INTEGER NOT NULL CHECK(raw_internal_pages >= 0),
      calculation_version TEXT NOT NULL CHECK(length(calculation_version) > 0),
      acquisition_quality TEXT NOT NULL CHECK(acquisition_quality IN ('firstPass', 'retried')),
      acquisition_attempt_count INTEGER NOT NULL CHECK(acquisition_attempt_count > 0),
      UNIQUE(timestamp_utc_microseconds, system_uptime_microseconds)
    );

    CREATE TABLE memory_pressure_observations(
      id INTEGER PRIMARY KEY,
      timestamp_utc_microseconds INTEGER NOT NULL CHECK(timestamp_utc_microseconds >= 0),
      system_uptime_microseconds INTEGER NOT NULL CHECK(system_uptime_microseconds >= 0),
      level TEXT NOT NULL CHECK(level IN ('UNKNOWN', 'NORMAL', 'WARNING', 'CRITICAL')),
      UNIQUE(timestamp_utc_microseconds, system_uptime_microseconds, level)
    );

    CREATE TABLE memory_sampling_gaps(
      id INTEGER PRIMARY KEY,
      timestamp_utc_microseconds INTEGER NOT NULL CHECK(timestamp_utc_microseconds >= 0),
      system_uptime_microseconds INTEGER NOT NULL CHECK(system_uptime_microseconds >= 0),
      acquisition_attempt_count INTEGER NOT NULL CHECK(acquisition_attempt_count > 0),
      inconsistency_reason TEXT NOT NULL,
      physical_memory_bytes INTEGER NOT NULL CHECK(physical_memory_bytes > 0),
      page_size_bytes INTEGER NOT NULL CHECK(page_size_bytes > 0),
      raw_free_pages INTEGER NOT NULL CHECK(raw_free_pages >= 0),
      raw_active_pages INTEGER NOT NULL CHECK(raw_active_pages >= 0),
      raw_inactive_pages INTEGER NOT NULL CHECK(raw_inactive_pages >= 0),
      raw_wired_pages INTEGER NOT NULL CHECK(raw_wired_pages >= 0),
      raw_speculative_pages INTEGER NOT NULL CHECK(raw_speculative_pages >= 0),
      raw_purgeable_pages INTEGER NOT NULL CHECK(raw_purgeable_pages >= 0),
      raw_compressor_pages INTEGER NOT NULL CHECK(raw_compressor_pages >= 0),
      raw_external_pages INTEGER NOT NULL CHECK(raw_external_pages >= 0),
      raw_internal_pages INTEGER NOT NULL CHECK(raw_internal_pages >= 0),
      estimated_memory_used_bytes INTEGER CHECK(estimated_memory_used_bytes >= 0),
      classified_memory_used_bytes INTEGER CHECK(classified_memory_used_bytes >= 0),
      excess_bytes INTEGER NOT NULL CHECK(excess_bytes >= 0),
      UNIQUE(timestamp_utc_microseconds, system_uptime_microseconds)
    );

    CREATE INDEX memory_samples_timestamp_index
      ON memory_samples(timestamp_utc_microseconds);
    CREATE INDEX memory_pressure_timestamp_index
      ON memory_pressure_observations(timestamp_utc_microseconds);
    CREATE INDEX memory_sampling_gaps_timestamp_index
      ON memory_sampling_gaps(timestamp_utc_microseconds);
    """

  private static let schemaVersion2SQL = """
    CREATE TABLE system_lifecycle_events(
      id INTEGER PRIMARY KEY,
      timestamp_utc_microseconds INTEGER NOT NULL CHECK(timestamp_utc_microseconds >= 0),
      system_uptime_microseconds INTEGER NOT NULL CHECK(system_uptime_microseconds >= 0),
      kind TEXT NOT NULL CHECK(
        kind IN ('LAUNCH', 'SLEEP', 'WAKE', 'CLOCK_CHANGED', 'REBOOT_DETECTED')
      ),
      UNIQUE(timestamp_utc_microseconds, system_uptime_microseconds, kind)
    );

    CREATE INDEX system_lifecycle_timestamp_index
      ON system_lifecycle_events(timestamp_utc_microseconds);
    """

  private static let schemaVersion3SQL = """
    CREATE TABLE memory_aggregates_1m(
      bucket_start_utc_microseconds INTEGER PRIMARY KEY
        CHECK(
          bucket_start_utc_microseconds >= 0
          AND bucket_start_utc_microseconds % 60000000 = 0
        ),
      sample_count INTEGER NOT NULL CHECK(sample_count > 0),
      average_physical_memory_bytes REAL NOT NULL
        CHECK(average_physical_memory_bytes > 0),
      average_estimated_memory_used_bytes REAL NOT NULL
        CHECK(average_estimated_memory_used_bytes >= 0),
      average_wired_bytes REAL NOT NULL CHECK(average_wired_bytes >= 0),
      average_compressed_bytes REAL NOT NULL CHECK(average_compressed_bytes >= 0),
      average_estimated_cached_files_bytes REAL NOT NULL
        CHECK(average_estimated_cached_files_bytes >= 0),
      average_swap_used_bytes REAL NOT NULL CHECK(average_swap_used_bytes >= 0)
    );

    CREATE TABLE memory_aggregates_5m(
      bucket_start_utc_microseconds INTEGER PRIMARY KEY
        CHECK(
          bucket_start_utc_microseconds >= 0
          AND bucket_start_utc_microseconds % 300000000 = 0
        ),
      sample_count INTEGER NOT NULL CHECK(sample_count > 0),
      average_physical_memory_bytes REAL NOT NULL
        CHECK(average_physical_memory_bytes > 0),
      average_estimated_memory_used_bytes REAL NOT NULL
        CHECK(average_estimated_memory_used_bytes >= 0),
      average_wired_bytes REAL NOT NULL CHECK(average_wired_bytes >= 0),
      average_compressed_bytes REAL NOT NULL CHECK(average_compressed_bytes >= 0),
      average_estimated_cached_files_bytes REAL NOT NULL
        CHECK(average_estimated_cached_files_bytes >= 0),
      average_swap_used_bytes REAL NOT NULL CHECK(average_swap_used_bytes >= 0)
    );
    """
}
