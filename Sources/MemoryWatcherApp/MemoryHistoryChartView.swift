import Charts
import MemoryWatcherCore
import SwiftUI

struct MemoryHistoryChartView: View {
  @ObservedObject var viewModel: HistoryViewModel
  let layoutConfiguration: DashboardLayoutConfiguration

  var body: some View {
    let metrics = layoutConfiguration.resolved().preset.metrics
    VStack(alignment: .leading, spacing: CGFloat(metrics.sectionSpacing)) {
      historyControls

      if let snapshot = viewModel.historyRenderSnapshot,
        snapshot.period == viewModel.historyPeriod
      {
        if snapshot.isEmpty {
          emptyHistoryView
        } else {
          unifiedHistory(snapshot, metrics: metrics)
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
          .accessibilityIdentifier("dashboard-history-error")
      }
    }
    .padding(CGFloat(metrics.contentPadding * 0.75))
    .background(
      RoundedRectangle(cornerRadius: 14)
        .fill(Color(nsColor: .windowBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .stroke(Color.secondary.opacity(0.18))
    )
    .accessibilityIdentifier("unified-dashboard-history")
  }

  private var historyControls: some View {
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
      .keyboardShortcut("r", modifiers: .command)
      .accessibilityIdentifier("memory-history-refresh")
    }
  }

  @ViewBuilder
  private func unifiedHistory(
    _ snapshot: DashboardHistoryRenderSnapshot,
    metrics: DashboardLayoutMetrics
  ) -> some View {
    let configuration = layoutConfiguration.resolved()
    let selection = Binding<Date?>(
      get: { viewModel.selectedUTC },
      set: { viewModel.selectTimestamp($0) }
    )

    VStack(
      alignment: .leading,
      spacing: CGFloat(metrics.sectionSpacing)
    ) {
      if configuration.usesCanonicalSectionOrder {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: CGFloat(metrics.sectionSpacing)) {
            if configuration.isVisible(.logicalCPUHistory) {
              LogicalCPUHistoryPanel(
                snapshot: snapshot,
                selectedUTC: selection,
                layoutMetrics: metrics
              )
              .frame(
                minWidth: metrics.logicalCPUHistoryMinimumWidth,
                idealWidth: metrics.logicalCPUHistoryMinimumWidth + 40,
                maxWidth: metrics.logicalCPUHistoryMinimumWidth + 100
              )
            }

            VStack(spacing: CGFloat(metrics.sectionSpacing)) {
              MemoryHistoryPanel(
                snapshot: snapshot,
                selectedUTC: selection,
                layoutMetrics: metrics
              )
              TotalCPUHistoryPanel(
                snapshot: snapshot,
                selectedUTC: selection,
                layoutMetrics: metrics
              )
            }
            .frame(minWidth: 500)
          }

          stackedSections(
            configuration.visibleSections.filter {
              $0 != .selectionDetails
            },
            snapshot: snapshot,
            selection: selection,
            metrics: metrics
          )
        }

        if configuration.isVisible(.selectionDetails) {
          DashboardSelectionDetailView(
            selection: viewModel.selectedDetails,
            layoutMetrics: metrics
          )
        }
      } else {
        stackedSections(
          configuration.visibleSections,
          snapshot: snapshot,
          selection: selection,
          metrics: metrics
        )
      }
    }
    .overlay(alignment: .topTrailing) {
      if viewModel.historyIsLoading {
        ProgressView()
          .controlSize(.small)
          .padding(6)
          .background(.regularMaterial, in: Circle())
      }
    }
  }

  private func stackedSections(
    _ sections: [DashboardLayoutSection],
    snapshot: DashboardHistoryRenderSnapshot,
    selection: Binding<Date?>,
    metrics: DashboardLayoutMetrics
  ) -> some View {
    VStack(spacing: CGFloat(metrics.sectionSpacing)) {
      ForEach(sections, id: \.self) { section in
        sectionView(
          section,
          snapshot: snapshot,
          selection: selection,
          metrics: metrics
        )
      }
    }
  }

  @ViewBuilder
  private func sectionView(
    _ section: DashboardLayoutSection,
    snapshot: DashboardHistoryRenderSnapshot,
    selection: Binding<Date?>,
    metrics: DashboardLayoutMetrics
  ) -> some View {
    switch section {
    case .memoryHistory:
      MemoryHistoryPanel(
        snapshot: snapshot,
        selectedUTC: selection,
        layoutMetrics: metrics
      )
    case .totalCPUHistory:
      TotalCPUHistoryPanel(
        snapshot: snapshot,
        selectedUTC: selection,
        layoutMetrics: metrics
      )
    case .logicalCPUHistory:
      LogicalCPUHistoryPanel(
        snapshot: snapshot,
        selectedUTC: selection,
        layoutMetrics: metrics
      )
    case .selectionDetails:
      DashboardSelectionDetailView(
        selection: viewModel.selectedDetails,
        layoutMetrics: metrics
      )
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
}

private struct MemoryHistoryPanel: View {
  let snapshot: DashboardHistoryRenderSnapshot
  @Binding var selectedUTC: Date?
  let layoutMetrics: DashboardLayoutMetrics

  private let gigabyte = 1_000_000_000.0

  var body: some View {
    let points = snapshot.memoryPoints
    let rows = compositionRows(from: points)
    let physicalMaximum = physicalMaximum(from: points)
    let swapMaximum = swapMaximum(from: points)
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 12) {
        Text("メモリ")
          .font(.headline)
        legendItem("その他（推定）", color: .blue)
        legendItem("有線", color: .orange)
        legendItem("圧縮", color: .purple)
        Spacer()
        Text("空白 = 未測定 / sleep")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Chart {
        ForEach(rows) { row in
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

        if let selectedUTC {
          RuleMark(x: .value("選択UTC", selectedUTC))
            .foregroundStyle(Color.primary.opacity(0.5))
        }
      }
      .chartXScale(domain: snapshot.startUTC...snapshot.endUTC)
      .chartYScale(domain: 0...(physicalMaximum * 1.05))
      .chartXAxis { historyXAxis(period: snapshot.period) }
      .chartYAxisLabel("GB", position: .top)
      .chartLegend(.hidden)
      .chartXSelection(value: $selectedUTC)
      .frame(height: layoutMetrics.memoryChartHeight)
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
          .lineStyle(StrokeStyle(lineWidth: 1.4))
        }
        if let selectedUTC {
          RuleMark(x: .value("選択UTC", selectedUTC))
            .foregroundStyle(Color.primary.opacity(0.35))
        }
      }
      .chartXScale(domain: snapshot.startUTC...snapshot.endUTC)
      .chartYScale(domain: 0...swapMaximum)
      .chartXAxis(.hidden)
      .chartYAxisLabel("GB", position: .top)
      .chartLegend(.hidden)
      .chartXSelection(value: $selectedUTC)
      .frame(height: layoutMetrics.swapChartHeight)
      .accessibilityLabel("スワップ使用量グラフ")

      HStack(spacing: 10) {
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
      .frame(height: 24)
      .accessibilityLabel("メモリプレッシャー履歴")
    }
    .padding(CGFloat(layoutMetrics.contentPadding * 0.65))
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.secondary.opacity(0.16))
    )
  }

  private func compositionRows(
    from points: [MemoryHistoryPoint]
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

  private func physicalMaximum(from points: [MemoryHistoryPoint]) -> Double {
    max(
      0.1,
      (points.map(\.physicalMemoryBytes).max() ?? gigabyte) / gigabyte
    )
  }

  private func swapMaximum(from points: [MemoryHistoryPoint]) -> Double {
    max(
      0.1,
      (points.map(\.swapUsedBytes).max() ?? 0) / gigabyte * 1.1
    )
  }

  private func legendItem(_ label: String, color: Color) -> some View {
    HStack(spacing: 4) {
      RoundedRectangle(cornerRadius: 2)
        .fill(color.opacity(0.72))
        .frame(width: 9, height: 9)
      Text(label).font(.caption2)
    }
  }

  private func pressureLegend(_ label: String, color: Color) -> some View {
    HStack(spacing: 3) {
      Circle().fill(color).frame(width: 7, height: 7)
      Text(label).font(.caption2)
    }
  }

  private func compositionColor(_ component: MemoryComponent) -> Color {
    switch component {
    case .other: return .blue
    case .wired: return .orange
    case .compressed: return .purple
    }
  }

  private func pressureColor(_ level: MemoryPressureLevel) -> Color {
    switch level {
    case .unknown: return .gray
    case .normal: return .green
    case .warning: return .yellow
    case .critical: return .red
    }
  }

  @AxisContentBuilder
  private func historyXAxis(
    period: MemoryHistoryPeriod
  ) -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 5)) { value in
      AxisGridLine()
      AxisTick()
      AxisValueLabel {
        if let date = value.as(Date.self) {
          switch period {
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
    "\(point.timestampUTC.timeIntervalSince1970)-\(point.continuitySegment)-\(component.rawValue)"
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
