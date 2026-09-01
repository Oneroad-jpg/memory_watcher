import Charts
import MemoryWatcherCore
import SwiftUI

struct MemoryHistoryChartView: View {
  @ObservedObject var viewModel: HistoryViewModel
  @State private var selectedDate: Date?

  private let gigabyte = 1_000_000_000.0

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Picker(
          "表示期間",
          selection: Binding(
            get: { viewModel.historyPeriod },
            set: { viewModel.selectHistoryPeriod($0) }
          )
        ) {
          ForEach(MemoryHistoryPeriod.allCases) { period in
            Text(period.displayName).tag(period)
          }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
        .accessibilityIdentifier("memory-history-period-picker")

        Spacer()

        if let duration = viewModel.historyLoadDurationSeconds {
          Text("読込 \(duration.formatted(.number.precision(.fractionLength(3))))秒")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Button {
          viewModel.reloadHistory()
        } label: {
          Label("更新", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("memory-history-refresh")
      }

      if let snapshot = viewModel.historySnapshot,
        snapshot.period == viewModel.historyPeriod
      {
        if snapshot.points.isEmpty
          && snapshot.cpuHistory.totalPoints.isEmpty
          && snapshot.cpuHistory.logicalPoints.isEmpty
        {
          emptyHistoryView
        } else {
          charts(snapshot: snapshot)
        }
      } else if viewModel.historyIsLoading {
        ProgressView("履歴を読み込んでいます")
          .frame(maxWidth: .infinity, minHeight: 300)
      } else {
        emptyHistoryView
      }

      if let message = viewModel.historyErrorMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
      }
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 14)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .stroke(Color.secondary.opacity(0.18))
    )
    .accessibilityIdentifier("memory-history-chart")
  }

  @ViewBuilder
  private func charts(snapshot: MemoryHistorySnapshot) -> some View {
    let points = displayPoints(snapshot.points, limit: 600)
    let selectedPoint =
      selectedDate.flatMap {
        viewModel.nearestHistoryPoint(to: $0)
      }
      ?? snapshot.points.last
    let physicalMaximum = max(
      0.1,
      (points.map(\.physicalMemoryBytes).max() ?? gigabyte) / gigabyte
    )
    let swapMaximum = max(
      0.1,
      (points.map(\.swapUsedBytes).max() ?? 0) / gigabyte * 1.1
    )

    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 14) {
        legendItem("その他使用量（推定）", color: .blue)
        legendItem("有線", color: .orange)
        legendItem("圧縮", color: .purple)
        legendItem("物理メモリ", color: .secondary, line: true)
        Spacer()
        Text("空白 = 未測定 / sleep")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Chart {
        ForEach(compositionRows(points)) { row in
          AreaMark(
            x: .value("時刻", row.timestampUTC),
            yStart: .value("開始 GB", row.lowerBytes / gigabyte),
            yEnd: .value("終了 GB", row.upperBytes / gigabyte),
            series: .value("系列", row.seriesKey)
          )
          .foregroundStyle(compositionColor(row.component).opacity(0.72))
          .interpolationMethod(.linear)
        }

        ForEach(points, id: \.pointID) { point in
          LineMark(
            x: .value("時刻", point.timestampUTC),
            y: .value("物理メモリ GB", point.physicalMemoryBytes / gigabyte),
            series: .value("物理系列", "physical-\(point.continuitySegment)")
          )
          .foregroundStyle(Color.secondary)
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }

        ForEach(snapshot.sleepIntervals, id: \.startUTC) { interval in
          RectangleMark(
            xStart: .value("sleep開始", interval.startUTC),
            xEnd: .value("sleep終了", interval.endUTC),
            yStart: .value("下端", 0),
            yEnd: .value("上端", physicalMaximum)
          )
          .foregroundStyle(Color.gray.opacity(0.12))
        }

        if let selectedPoint {
          RuleMark(x: .value("選択時刻", selectedPoint.timestampUTC))
            .foregroundStyle(Color.primary.opacity(0.55))
          PointMark(
            x: .value("選択時刻", selectedPoint.timestampUTC),
            y: .value(
              "選択使用量 GB",
              selectedPoint.estimatedMemoryUsedBytes / gigabyte
            )
          )
          .foregroundStyle(Color.primary)
          .symbolSize(35)
        }
      }
      .chartXScale(domain: snapshot.startUTC...snapshot.endUTC)
      .chartYScale(domain: 0...(physicalMaximum * 1.05))
      .chartXAxis { historyXAxis(period: snapshot.period) }
      .chartYAxisLabel("GB", position: .top)
      .chartLegend(.hidden)
      .chartXSelection(value: $selectedDate)
      .frame(height: 280)
      .accessibilityLabel("メモリ使用量の構成グラフ")

      Text("スワップ")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      Chart {
        ForEach(points, id: \.pointID) { point in
          LineMark(
            x: .value("時刻", point.timestampUTC),
            y: .value("スワップ GB", point.swapUsedBytes / gigabyte),
            series: .value("区間", "swap-\(point.continuitySegment)")
          )
          .foregroundStyle(Color.indigo)
          .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        if let selectedPoint {
          PointMark(
            x: .value("選択時刻", selectedPoint.timestampUTC),
            y: .value("選択スワップ GB", selectedPoint.swapUsedBytes / gigabyte)
          )
          .foregroundStyle(Color.indigo)
        }
      }
      .chartXScale(domain: snapshot.startUTC...snapshot.endUTC)
      .chartYScale(domain: 0...swapMaximum)
      .chartXAxis(.hidden)
      .chartYAxisLabel("GB", position: .top)
      .chartLegend(.hidden)
      .frame(height: 105)
      .accessibilityLabel("スワップ使用量グラフ")

      HStack(spacing: 12) {
        Text("メモリプレッシャー")
          .font(.caption.weight(.semibold))
        pressureLegend("UNKNOWN", color: .gray)
        pressureLegend("NORMAL", color: .green)
        pressureLegend("WARNING", color: .yellow)
        pressureLegend("CRITICAL", color: .red)
      }
      .foregroundStyle(.secondary)

      Chart(snapshot.pressureIntervals, id: \.startUTC) { interval in
        RectangleMark(
          xStart: .value("開始", interval.startUTC),
          xEnd: .value("終了", interval.endUTC),
          yStart: .value("下端", 0),
          yEnd: .value("上端", 1)
        )
        .foregroundStyle(pressureColor(interval.level))
      }
      .chartXScale(domain: snapshot.startUTC...snapshot.endUTC)
      .chartXAxis(.hidden)
      .chartYAxis(.hidden)
      .chartLegend(.hidden)
      .frame(height: 26)
      .accessibilityLabel("メモリプレッシャー履歴")

      if let selectedPoint {
        selectedPointDetails(selectedPoint)
      }

      CPUHistoryChartSection(
        viewModel: viewModel,
        snapshot: snapshot,
        selectedDate: $selectedDate
      )
    }
    .overlay(alignment: .topTrailing) {
      if viewModel.historyIsLoading {
        ProgressView()
          .controlSize(.small)
          .padding(6)
          .background(.regularMaterial, in: Circle())
      }
    }
    .onChange(of: snapshot.period) {
      selectedDate = nil
    }
  }

  private var emptyHistoryView: some View {
    VStack(spacing: 8) {
      Image(systemName: "chart.xyaxis.line")
        .font(.system(size: 34))
        .foregroundStyle(.secondary)
      Text("この期間の測定値はまだありません")
        .font(.headline)
      Text("Memory Watcherの起動中に履歴が蓄積されます")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 300)
  }

  private func selectedPointDetails(_ point: MemoryHistoryPoint) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(
          point.timestampUTC.formatted(
            .dateTime.year().month().day().hour().minute().second()
          )
        )
        .font(.subheadline.weight(.semibold))
        Spacer()
        Text("実測 \(point.sampleCount)件")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 18) {
        metric("使用量（推定）", bytes: point.estimatedMemoryUsedBytes)
        metric("その他使用量", bytes: point.estimatedOtherUsedBytes)
        metric("有線", bytes: point.wiredBytes)
        metric("圧縮", bytes: point.compressedBytes)
        metric("キャッシュ（推定）", bytes: point.estimatedCachedFilesBytes)
        metric("スワップ", bytes: point.swapUsedBytes)
      }
    }
    .padding(10)
    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    .accessibilityIdentifier("memory-history-selected-point")
  }

  private func metric(_ label: String, bytes: Double) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text("\((bytes / gigabyte).formatted(.number.precision(.fractionLength(2)))) GB")
        .font(.caption.monospacedDigit())
    }
  }

  private func legendItem(
    _ label: String,
    color: Color,
    line: Bool = false
  ) -> some View {
    HStack(spacing: 5) {
      if line {
        Rectangle()
          .fill(color)
          .frame(width: 16, height: 2)
      } else {
        RoundedRectangle(cornerRadius: 2)
          .fill(color.opacity(0.72))
          .frame(width: 10, height: 10)
      }
      Text(label).font(.caption)
    }
  }

  private func pressureLegend(_ label: String, color: Color) -> some View {
    HStack(spacing: 4) {
      Circle().fill(color).frame(width: 7, height: 7)
      Text(label).font(.caption2)
    }
  }

  @AxisContentBuilder
  private func historyXAxis(period: MemoryHistoryPeriod) -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 6)) { value in
      AxisGridLine()
      AxisTick()
      AxisValueLabel {
        if let date = value.as(Date.self) {
          Text(axisLabel(date, period: period))
        }
      }
    }
  }

  private func axisLabel(_ date: Date, period: MemoryHistoryPeriod) -> String {
    switch period {
    case .twelveHours, .twentyFourHours:
      return date.formatted(.dateTime.hour().minute())
    case .threeDays:
      return date.formatted(.dateTime.month().day())
    }
  }

  private func displayPoints(
    _ points: [MemoryHistoryPoint],
    limit: Int
  ) -> [MemoryHistoryPoint] {
    guard points.count > limit, limit > 2 else {
      return points
    }
    let step = Double(points.count - 1) / Double(limit - 1)
    var indexes = Set((0..<limit).map { Int((Double($0) * step).rounded()) })
    indexes.insert(0)
    indexes.insert(points.count - 1)
    for index in 1..<points.count
    where points[index].continuitySegment != points[index - 1].continuitySegment {
      indexes.insert(index - 1)
      indexes.insert(index)
    }
    return indexes.sorted().map { points[$0] }
  }

  private func compositionRows(
    _ points: [MemoryHistoryPoint]
  ) -> [CompositionRow] {
    points.flatMap { point in
      let otherTop = point.estimatedOtherUsedBytes
      let wiredTop = otherTop + point.wiredBytes
      return [
        CompositionRow(
          point: point,
          component: .other,
          lowerBytes: 0,
          upperBytes: otherTop
        ),
        CompositionRow(
          point: point,
          component: .wired,
          lowerBytes: otherTop,
          upperBytes: wiredTop
        ),
        CompositionRow(
          point: point,
          component: .compressed,
          lowerBytes: wiredTop,
          upperBytes: point.estimatedMemoryUsedBytes
        ),
      ]
    }
  }

  private func compositionColor(_ component: MemoryComponent) -> Color {
    switch component {
    case .other:
      return .blue
    case .wired:
      return .orange
    case .compressed:
      return .purple
    }
  }

  private func pressureColor(_ level: MemoryPressureLevel) -> Color {
    switch level {
    case .unknown:
      return .gray
    case .normal:
      return .green
    case .warning:
      return .yellow
    case .critical:
      return .red
    }
  }
}

private enum MemoryComponent: String {
  case other
  case wired
  case compressed
}

private struct CompositionRow: Identifiable {
  let point: MemoryHistoryPoint
  let component: MemoryComponent
  let lowerBytes: Double
  let upperBytes: Double

  var id: String {
    "\(point.timestampUTC.timeIntervalSince1970)-\(component.rawValue)-\(point.continuitySegment)"
  }

  var timestampUTC: Date { point.timestampUTC }
  var seriesKey: String {
    "\(component.rawValue)-\(point.continuitySegment)"
  }
}

extension MemoryHistoryPoint {
  fileprivate var pointID: String {
    "\(timestampUTC.timeIntervalSince1970)-\(continuitySegment)"
  }
}
