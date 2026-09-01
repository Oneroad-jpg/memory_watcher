import Charts
import MemoryWatcherCore
import SwiftUI

struct CPUHistoryChartSection: View {
  @ObservedObject var viewModel: HistoryViewModel
  let snapshot: MemoryHistorySnapshot
  @Binding var selectedDate: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Divider().padding(.vertical, 4)

      HStack {
        Text("CPU履歴")
          .font(.headline)
        Text("使用率 = user + system + nice")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Text("空白 = UNKNOWN / sleep / 再起動 / 取得不能")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if snapshot.cpuHistory.totalPoints.isEmpty
        && snapshot.cpuHistory.logicalPoints.isEmpty
      {
        Text("この期間のCPU実測値はまだありません")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 120)
          .accessibilityIdentifier("cpu-history-empty")
      } else {
        totalCPUChart
        logicalCPUChart
        selectedCPUDetails
      }
    }
    .accessibilityIdentifier("cpu-history-section")
  }

  private var totalCPUChart: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Mac全体CPU")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      Chart {
        ForEach(displayTotalPoints, id: \.pointID) { point in
          LineMark(
            x: .value("時刻", point.timestampUTC),
            y: .value("CPU使用率", point.utilizationPercent),
            series: .value("連続区間", "total-\(point.continuitySegment)")
          )
          .foregroundStyle(Color.cyan)
          .lineStyle(StrokeStyle(lineWidth: 1.6))
        }

        ForEach(snapshot.sleepIntervals, id: \.startUTC) { interval in
          RectangleMark(
            xStart: .value("sleep開始", interval.startUTC),
            xEnd: .value("sleep終了", interval.endUTC),
            yStart: .value("下端", 0),
            yEnd: .value("上端", 100)
          )
          .foregroundStyle(Color.gray.opacity(0.12))
        }

        if let point = selectedTotalPoint {
          RuleMark(x: .value("選択時刻", point.timestampUTC))
            .foregroundStyle(Color.primary.opacity(0.5))
          PointMark(
            x: .value("選択時刻", point.timestampUTC),
            y: .value("選択CPU使用率", point.utilizationPercent)
          )
          .foregroundStyle(Color.cyan)
          .symbolSize(34)
        }
      }
      .chartXScale(domain: snapshot.startUTC...snapshot.endUTC)
      .chartYScale(domain: 0...100)
      .chartXAxis { cpuXAxis }
      .chartYAxisLabel("%", position: .top)
      .chartLegend(.hidden)
      .chartXSelection(value: $selectedDate)
      .frame(height: 170)
      .accessibilityLabel("Mac全体CPU使用率の履歴")
    }
  }

  private var logicalCPUChart: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("論理CPU別")
          .font(.caption.weight(.semibold))
        Text("CPU番号はOSの0始まりindexを画面上で1始まり表示")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Chart {
        ForEach(displayLogicalPoints, id: \.pointID) { point in
          LineMark(
            x: .value("時刻", point.timestampUTC),
            y: .value("CPU使用率", point.utilizationPercent),
            series: .value("連続系列", point.seriesIdentifier)
          )
          .foregroundStyle(by: .value("論理CPU", point.displayName))
          .lineStyle(StrokeStyle(lineWidth: 1.1))
        }

        if let selectedDate {
          RuleMark(x: .value("選択時刻", selectedDate))
            .foregroundStyle(Color.primary.opacity(0.45))
        }
      }
      .chartXScale(domain: snapshot.startUTC...snapshot.endUTC)
      .chartYScale(domain: 0...100)
      .chartXAxis { cpuXAxis }
      .chartYAxisLabel("%", position: .top)
      .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
      .chartXSelection(value: $selectedDate)
      .frame(height: 230)
      .accessibilityLabel("論理CPU別使用率の履歴")
    }
  }

  @ViewBuilder
  private var selectedCPUDetails: some View {
    if let point = selectedTotalPoint {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(
            point.timestampUTC.formatted(
              .dateTime.year().month().day().hour().minute().second()
            )
          )
          .font(.subheadline.weight(.semibold))
          Spacer()
          Text(
            point.source == .raw
              ? "実測 \(point.sampleCount)件"
              : "1分集約 \(point.sampleCount)件"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        HStack(spacing: 18) {
          percentMetric("全体", value: point.utilizationPercent)
          percentMetric("user", value: point.userPercent)
          percentMetric("system", value: point.systemPercent)
          percentMetric("nice", value: point.nicePercent)
          percentMetric("idle", value: point.idlePercent)
        }

        let logicalPoints = selectedLogicalPoints
        if !logicalPoints.isEmpty {
          ScrollView(.horizontal) {
            HStack(spacing: 14) {
              ForEach(logicalPoints, id: \.pointID) { logical in
                percentMetric(
                  logical.displayName,
                  value: logical.utilizationPercent
                )
              }
            }
          }
          .scrollIndicators(.hidden)
        }
      }
      .padding(10)
      .background(
        Color.primary.opacity(0.045),
        in: RoundedRectangle(cornerRadius: 9)
      )
      .accessibilityIdentifier("cpu-history-selected-point")
    }
  }

  private var selectedTotalPoint: TotalCPUHistoryPoint? {
    let target = selectedDate ?? snapshot.cpuHistory.totalPoints.last?.timestampUTC
    return target.flatMap { viewModel.nearestTotalCPUPoint(to: $0) }
  }

  private var selectedLogicalPoints: [LogicalCPUHistoryPoint] {
    guard let target = selectedDate ?? selectedTotalPoint?.timestampUTC else {
      return []
    }
    return viewModel.nearestLogicalCPUPoints(to: target)
  }

  private var displayTotalPoints: [TotalCPUHistoryPoint] {
    downsample(
      snapshot.cpuHistory.totalPoints,
      limit: 600,
      timestamp: \.timestampUTC,
      segment: { "\($0.continuitySegment)" }
    )
  }

  private var displayLogicalPoints: [LogicalCPUHistoryPoint] {
    let groups = Dictionary(
      grouping: snapshot.cpuHistory.logicalPoints,
      by: \.seriesIdentifier
    )
    return groups.values.flatMap {
      downsample(
        $0,
        limit: 180,
        timestamp: \.timestampUTC,
        segment: { $0.seriesIdentifier }
      )
    }.sorted { $0.timestampUTC < $1.timestampUTC }
  }

  private func downsample<Point>(
    _ points: [Point],
    limit: Int,
    timestamp: KeyPath<Point, Date>,
    segment: (Point) -> String
  ) -> [Point] {
    guard points.count > limit, limit > 2 else { return points }
    let step = Double(points.count - 1) / Double(limit - 1)
    var indexes = Set((0..<limit).map { Int((Double($0) * step).rounded()) })
    indexes.insert(0)
    indexes.insert(points.count - 1)
    for index in 1..<points.count
    where segment(points[index]) != segment(points[index - 1]) {
      indexes.insert(index - 1)
      indexes.insert(index)
    }
    return indexes.sorted().map { points[$0] }.sorted {
      $0[keyPath: timestamp] < $1[keyPath: timestamp]
    }
  }

  private func percentMetric(_ label: String, value: Double) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text("\(value.formatted(.number.precision(.fractionLength(1))))%")
        .font(.caption.monospacedDigit())
    }
  }

  @AxisContentBuilder
  private var cpuXAxis: some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 6)) { value in
      AxisGridLine()
      AxisTick()
      AxisValueLabel {
        if let date = value.as(Date.self) {
          switch snapshot.period {
          case .twelveHours, .twentyFourHours:
            Text(date.formatted(.dateTime.hour().minute()))
          case .threeDays:
            Text(date.formatted(.dateTime.month().day()))
          }
        }
      }
    }
  }
}

extension TotalCPUHistoryPoint {
  fileprivate var pointID: String {
    "\(timestampUTC.timeIntervalSince1970)-\(continuitySegment)"
  }
}

extension LogicalCPUHistoryPoint {
  fileprivate var pointID: String {
    "\(topology.epochKey)-\(cpuIndex)-\(timestampUTC.timeIntervalSince1970)-\(continuitySegment)"
  }
}
