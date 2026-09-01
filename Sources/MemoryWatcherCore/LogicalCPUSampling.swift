import Darwin
import Foundation

public struct LogicalCPUTopology: Equatable, Sendable {
  public let epochKey: String
  public let bootSessionStartUTC: Date
  public let logicalCPUCount: Int

  public init(
    epochKey: String,
    bootSessionStartUTC: Date,
    logicalCPUCount: Int
  ) {
    self.epochKey = epochKey
    self.bootSessionStartUTC = bootSessionStartUTC
    self.logicalCPUCount = logicalCPUCount
  }
}

public struct LogicalCPUCounterObservation: Equatable, Sendable {
  public let timestampUTC: Date
  public let systemUptimeSeconds: TimeInterval
  public let topology: LogicalCPUTopology
  public let countersByCPUIndex: [CPUCounterSnapshot]

  public init(
    timestampUTC: Date,
    systemUptimeSeconds: TimeInterval,
    topology: LogicalCPUTopology,
    countersByCPUIndex: [CPUCounterSnapshot]
  ) {
    self.timestampUTC = timestampUTC
    self.systemUptimeSeconds = systemUptimeSeconds
    self.topology = topology
    self.countersByCPUIndex = countersByCPUIndex
  }
}

public struct LogicalCPUSample: Equatable, Sendable {
  public let topology: LogicalCPUTopology
  public let cpuIndex: Int
  public let intervalStartUTC: Date?
  public let intervalEndUTC: Date
  public let intervalStartUptimeSeconds: TimeInterval?
  public let intervalEndUptimeSeconds: TimeInterval
  public let delta: CPUCounterDelta?
  public let calculationVersion: String
  public let quality: CPUUtilizationQuality

  public init(
    topology: LogicalCPUTopology,
    cpuIndex: Int,
    intervalStartUTC: Date?,
    intervalEndUTC: Date,
    intervalStartUptimeSeconds: TimeInterval?,
    intervalEndUptimeSeconds: TimeInterval,
    delta: CPUCounterDelta?,
    calculationVersion: String = CPUUtilizationCalculator.calculationVersion,
    quality: CPUUtilizationQuality
  ) {
    self.topology = topology
    self.cpuIndex = cpuIndex
    self.intervalStartUTC = intervalStartUTC
    self.intervalEndUTC = intervalEndUTC
    self.intervalStartUptimeSeconds = intervalStartUptimeSeconds
    self.intervalEndUptimeSeconds = intervalEndUptimeSeconds
    self.delta = delta
    self.calculationVersion = calculationVersion
    self.quality = quality
  }

  public var utilizationPercent: Double? {
    delta?.utilizationPercent
  }
}

public struct LogicalCPUSamplingGap: Equatable, Sendable {
  public let timestampUTC: Date
  public let systemUptimeSeconds: TimeInterval
  public let previousTopology: LogicalCPUTopology?
  public let quality: CPUUtilizationQuality

  public init(
    timestampUTC: Date,
    systemUptimeSeconds: TimeInterval,
    previousTopology: LogicalCPUTopology?,
    quality: CPUUtilizationQuality = .unavailable
  ) {
    self.timestampUTC = timestampUTC
    self.systemUptimeSeconds = systemUptimeSeconds
    self.previousTopology = previousTopology
    self.quality = quality
  }
}

public enum LogicalCPUSamplingOutcome: Equatable, Sendable {
  case samples([LogicalCPUSample])
  case gap(LogicalCPUSamplingGap)
}

public enum LogicalCPUSampleValidationError: Error, Equatable, Sendable {
  case invalidTopology
  case invalidCPUIndex
  case inconsistentBatch
  case invalidGap
  case invalidSample(TotalCPUSampleValidationError)
}

public enum LogicalCPUSampleValidator {
  public static func validate(_ sample: LogicalCPUSample) throws {
    try validate(sample.topology)
    guard
      sample.cpuIndex >= 0,
      sample.cpuIndex < sample.topology.logicalCPUCount
    else {
      throw LogicalCPUSampleValidationError.invalidCPUIndex
    }
    do {
      try TotalCPUSampleValidator.validate(
        TotalCPUSample(
          intervalStartUTC: sample.intervalStartUTC,
          intervalEndUTC: sample.intervalEndUTC,
          intervalStartUptimeSeconds: sample.intervalStartUptimeSeconds,
          intervalEndUptimeSeconds: sample.intervalEndUptimeSeconds,
          delta: sample.delta,
          calculationVersion: sample.calculationVersion,
          quality: sample.quality
        )
      )
    } catch let error as TotalCPUSampleValidationError {
      throw LogicalCPUSampleValidationError.invalidSample(error)
    }
  }

  public static func validate(batch: [LogicalCPUSample]) throws {
    guard let first = batch.first else {
      throw LogicalCPUSampleValidationError.inconsistentBatch
    }
    try validate(first.topology)
    guard batch.count == first.topology.logicalCPUCount else {
      throw LogicalCPUSampleValidationError.inconsistentBatch
    }
    var indices = Set<Int>()
    for sample in batch {
      try validate(sample)
      guard
        sample.topology == first.topology,
        sample.intervalEndUTC == first.intervalEndUTC,
        sample.intervalEndUptimeSeconds == first.intervalEndUptimeSeconds,
        indices.insert(sample.cpuIndex).inserted
      else {
        throw LogicalCPUSampleValidationError.inconsistentBatch
      }
    }
    guard indices == Set(0..<first.topology.logicalCPUCount) else {
      throw LogicalCPUSampleValidationError.inconsistentBatch
    }
  }

  public static func validate(_ gap: LogicalCPUSamplingGap) throws {
    guard
      gap.quality == .unavailable,
      gap.timestampUTC.timeIntervalSince1970.isFinite,
      gap.timestampUTC.timeIntervalSince1970 >= 0,
      gap.systemUptimeSeconds.isFinite,
      gap.systemUptimeSeconds >= 0
    else {
      throw LogicalCPUSampleValidationError.invalidGap
    }
    if let previousTopology = gap.previousTopology {
      try validate(previousTopology)
    }
  }

  public static func validate(_ topology: LogicalCPUTopology) throws {
    guard
      !topology.epochKey.isEmpty,
      topology.epochKey.utf8.count <= 200,
      topology.bootSessionStartUTC.timeIntervalSince1970.isFinite,
      topology.bootSessionStartUTC.timeIntervalSince1970 >= 0,
      topology.logicalCPUCount > 0,
      topology.logicalCPUCount <= 4_096
    else {
      throw LogicalCPUSampleValidationError.invalidTopology
    }
  }
}

public enum LogicalCPUSamplingError: Error, Equatable, Sendable {
  case hostProcessorInfo(Int32)
  case invalidProcessorInfo
  case bootTime(Int32)
  case invalidBootTime
}

public enum LogicalCPUStorageCapacity {
  public static let verifiedLogicalCPUCount = 32
  public static let maximumBytes = 128 * 1_024 * 1_024
  public static let fixedDatabaseAllowanceBytes = 8 * 1_024 * 1_024
  public static let maximumObservedBytesPerLogicalCPURow = 160

  public static var retainedRawRowCount: Int {
    verifiedLogicalCPUCount * 24 * 60 * 60 / 5
  }

  public static var retainedOneMinuteRowCount: Int {
    verifiedLogicalCPUCount * 3 * 24 * 60
  }

  public static var retainedFiveMinuteRowCount: Int {
    verifiedLogicalCPUCount * 3 * 24 * 60 / 5
  }

  public static var projectedMaximumBytes: Int {
    fixedDatabaseAllowanceBytes
      + maximumObservedBytesPerLogicalCPURow
      * (retainedRawRowCount
        + retainedOneMinuteRowCount
        + retainedFiveMinuteRowCount)
  }
}

public final class SystemLogicalCPUSampler: @unchecked Sendable {
  private let lock = NSLock()
  private let observationProvider: @Sendable () throws -> LogicalCPUCounterObservation
  private let timestampProvider: @Sendable () -> Date
  private let uptimeProvider: @Sendable () -> TimeInterval
  private var previousObservation: LogicalCPUCounterObservation?
  private var pendingContinuity: CPUIntervalContinuity?

  public init() {
    observationProvider = Self.readSystemObservation
    timestampProvider = { Date() }
    uptimeProvider = { ProcessInfo.processInfo.systemUptime }
  }

  init(
    observationProvider:
      @escaping @Sendable () throws -> LogicalCPUCounterObservation,
    timestampProvider: @escaping @Sendable () -> Date,
    uptimeProvider: @escaping @Sendable () -> TimeInterval
  ) {
    self.observationProvider = observationProvider
    self.timestampProvider = timestampProvider
    self.uptimeProvider = uptimeProvider
  }

  public func reset(for continuity: CPUIntervalContinuity) {
    lock.withLock {
      previousObservation = nil
      pendingContinuity = continuity
    }
  }

  public func reset() {
    lock.withLock {
      previousObservation = nil
      pendingContinuity = nil
    }
  }

  public func sample() -> LogicalCPUSamplingOutcome {
    lock.withLock {
      let retainedTopology = previousObservation?.topology
      let observation: LogicalCPUCounterObservation
      do {
        observation = try observationProvider()
        try validate(observation)
      } catch {
        previousObservation = nil
        pendingContinuity = nil
        return .gap(
          LogicalCPUSamplingGap(
            timestampUTC: timestampProvider(),
            systemUptimeSeconds: uptimeProvider(),
            previousTopology: retainedTopology
          )
        )
      }

      if let pendingContinuity {
        self.pendingContinuity = nil
        previousObservation = observation
        return .samples(
          unknownSamples(
            observation: observation,
            quality: quality(for: pendingContinuity)
          )
        )
      }
      guard let previousObservation else {
        self.previousObservation = observation
        return .samples(
          unknownSamples(
            observation: observation,
            quality: .firstDeltaUnknown
          )
        )
      }
      self.previousObservation = observation

      guard previousObservation.topology == observation.topology else {
        return .samples(
          unknownSamples(
            observation: observation,
            quality: .topologyChangeBoundary
          )
        )
      }
      if SystemTimelineAnalyzer.clockChanged(
        previous: SystemTimelineAnchor(
          timestampUTC: previousObservation.timestampUTC,
          systemUptimeSeconds: previousObservation.systemUptimeSeconds
        ),
        current: SystemTimelineAnchor(
          timestampUTC: observation.timestampUTC,
          systemUptimeSeconds: observation.systemUptimeSeconds
        )
      ) {
        return .samples(
          unknownSamples(
            observation: observation,
            quality: .clockChangeBoundary
          )
        )
      }
      let elapsed =
        observation.systemUptimeSeconds
        - previousObservation.systemUptimeSeconds
      guard
        elapsed >= CPUUtilizationCalculator.minimumContinuousIntervalSeconds,
        elapsed <= CPUUtilizationCalculator.maximumContinuousIntervalSeconds
      else {
        return .samples(
          unknownSamples(
            observation: observation,
            quality: .intervalOutOfRange
          )
        )
      }

      let samples = observation.countersByCPUIndex.indices.map { cpuIndex in
        switch CPUUtilizationCalculator.calculate(
          previous: previousObservation.countersByCPUIndex[cpuIndex],
          current: observation.countersByCPUIndex[cpuIndex]
        ) {
        case .measured(let delta):
          return LogicalCPUSample(
            topology: observation.topology,
            cpuIndex: cpuIndex,
            intervalStartUTC: previousObservation.timestampUTC,
            intervalEndUTC: observation.timestampUTC,
            intervalStartUptimeSeconds:
              previousObservation.systemUptimeSeconds,
            intervalEndUptimeSeconds: observation.systemUptimeSeconds,
            delta: delta,
            quality: .measured
          )
        case .unknown(let quality):
          return unknownSample(
            observation: observation,
            cpuIndex: cpuIndex,
            quality: quality
          )
        }
      }
      return .samples(samples)
    }
  }

  private func validate(_ observation: LogicalCPUCounterObservation) throws {
    try LogicalCPUSampleValidator.validate(observation.topology)
    guard
      observation.timestampUTC.timeIntervalSince1970.isFinite,
      observation.timestampUTC.timeIntervalSince1970 >= 0,
      observation.systemUptimeSeconds.isFinite,
      observation.systemUptimeSeconds >= 0,
      observation.countersByCPUIndex.count
        == observation.topology.logicalCPUCount
    else {
      throw LogicalCPUSamplingError.invalidProcessorInfo
    }
  }

  private func unknownSamples(
    observation: LogicalCPUCounterObservation,
    quality: CPUUtilizationQuality
  ) -> [LogicalCPUSample] {
    observation.countersByCPUIndex.indices.map { cpuIndex in
      unknownSample(
        observation: observation,
        cpuIndex: cpuIndex,
        quality: quality
      )
    }
  }

  private func unknownSample(
    observation: LogicalCPUCounterObservation,
    cpuIndex: Int,
    quality: CPUUtilizationQuality
  ) -> LogicalCPUSample {
    LogicalCPUSample(
      topology: observation.topology,
      cpuIndex: cpuIndex,
      intervalStartUTC: nil,
      intervalEndUTC: observation.timestampUTC,
      intervalStartUptimeSeconds: nil,
      intervalEndUptimeSeconds: observation.systemUptimeSeconds,
      delta: nil,
      quality: quality
    )
  }

  private func quality(
    for continuity: CPUIntervalContinuity
  ) -> CPUUtilizationQuality {
    switch CPUUtilizationCalculator.calculate(
      previous: CPUCounterSnapshot(
        userTicks: 0,
        systemTicks: 0,
        idleTicks: 0,
        niceTicks: 0
      ),
      current: CPUCounterSnapshot(
        userTicks: 0,
        systemTicks: 0,
        idleTicks: 0,
        niceTicks: 0
      ),
      continuity: continuity
    ) {
    case .unknown(let quality):
      return quality
    case .measured:
      return .unavailable
    }
  }

  private static func readSystemObservation() throws
    -> LogicalCPUCounterObservation
  {
    let host = mach_host_self()
    defer {
      mach_port_deallocate(mach_task_self_, host)
    }
    var processorCount: natural_t = 0
    var processorInfo: processor_info_array_t?
    var processorInfoCount: mach_msg_type_number_t = 0
    let result = host_processor_info(
      host,
      PROCESSOR_CPU_LOAD_INFO,
      &processorCount,
      &processorInfo,
      &processorInfoCount
    )
    guard result == KERN_SUCCESS, let processorInfo else {
      throw LogicalCPUSamplingError.hostProcessorInfo(result)
    }
    defer {
      let byteCount =
        vm_size_t(processorInfoCount)
        * vm_size_t(MemoryLayout<integer_t>.stride)
      vm_deallocate(
        mach_task_self_,
        vm_address_t(UInt(bitPattern: processorInfo)),
        byteCount
      )
    }

    let logicalCPUCount = Int(processorCount)
    let stateCount = Int(CPU_STATE_MAX)
    guard
      logicalCPUCount > 0,
      stateCount == 4,
      Int(processorInfoCount) == logicalCPUCount * stateCount
    else {
      throw LogicalCPUSamplingError.invalidProcessorInfo
    }
    let counters = (0..<logicalCPUCount).map { cpuIndex in
      let base = cpuIndex * stateCount
      return CPUCounterSnapshot(
        userTicks: unsignedProcessorTick(
          processorInfo[base + Int(CPU_STATE_USER)]
        ),
        systemTicks: unsignedProcessorTick(
          processorInfo[base + Int(CPU_STATE_SYSTEM)]
        ),
        idleTicks: unsignedProcessorTick(
          processorInfo[base + Int(CPU_STATE_IDLE)]
        ),
        niceTicks: unsignedProcessorTick(
          processorInfo[base + Int(CPU_STATE_NICE)]
        )
      )
    }
    let bootSessionStartUTC = try readBootSessionStartUTC()
    let bootMicroseconds = try bootSessionMicroseconds(
      from: bootSessionStartUTC
    )
    let topology = LogicalCPUTopology(
      epochKey: "boot-\(bootMicroseconds)-logical-\(logicalCPUCount)",
      bootSessionStartUTC: bootSessionStartUTC,
      logicalCPUCount: logicalCPUCount
    )
    return LogicalCPUCounterObservation(
      timestampUTC: Date(),
      systemUptimeSeconds: ProcessInfo.processInfo.systemUptime,
      topology: topology,
      countersByCPUIndex: counters
    )
  }

  private static func readBootSessionStartUTC() throws -> Date {
    var bootTime = timeval()
    var byteCount = MemoryLayout<timeval>.stride
    let result = sysctlbyname(
      "kern.boottime",
      &bootTime,
      &byteCount,
      nil,
      0
    )
    guard result == 0, byteCount == MemoryLayout<timeval>.stride else {
      throw LogicalCPUSamplingError.bootTime(errno)
    }
    let seconds = TimeInterval(bootTime.tv_sec)
    let microseconds = TimeInterval(bootTime.tv_usec) / 1_000_000
    let interval = seconds + microseconds
    guard interval.isFinite, interval >= 0 else {
      throw LogicalCPUSamplingError.invalidBootTime
    }
    return Date(timeIntervalSince1970: interval)
  }

  private static func unsignedProcessorTick(_ value: integer_t) -> UInt64 {
    UInt64(UInt32(bitPattern: value))
  }

  private static func bootSessionMicroseconds(from date: Date) throws -> Int64 {
    let scaled = date.timeIntervalSince1970 * 1_000_000
    guard
      scaled.isFinite,
      scaled >= 0,
      let value = Int64(exactly: scaled.rounded())
    else {
      throw LogicalCPUSamplingError.invalidBootTime
    }
    return value
  }
}
