import Charts
import MemoryWatcherCore
import SwiftUI

struct TotalCPUHistoryPanel: View {
  let snapshot: DashboardHistoryRenderSnapshot
  @Binding var selectedUTC: Date?
  let layoutMetrics: DashboardLayoutMetrics

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text("Mac全体CPU")
          .font(.headline)
        Text("使用率 = user + system + nice")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Text("0〜100%")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      Chart {
        ForEach(snapshot.totalCPUPoints, id: \.pointID) { point in
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

        if let selectedUTC {
          RuleMark(x: .value("選択UTC", selectedUTC))
            .foregroundStyle(Color.primary.opacity(0.45))
        }
      }
      .chartXScale(domain: snapshot.startUTC...snapshot.endUTC)
      .chartYScale(domain: 0...100)
      .chartXAxis { dashboardXAxis(period: snapshot.period) }
      .chartYAxisLabel("%", position: .top)
      .chartLegend(.hidden)
      .chartXSelection(value: $selectedUTC)
      .frame(height: layoutMetrics.totalCPUChartHeight)
      .accessibilityLabel("Mac全体CPU使用率の履歴")

      Text("空白 = UNKNOWN / sleep / 再起動 / 取得不能")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .dashboardPanel(padding: layoutMetrics.contentPadding * 0.65)
  }

  @AxisContentBuilder
  private func dashboardXAxis(
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

struct LogicalCPUHistoryPanel: View {
  let snapshot: DashboardHistoryRenderSnapshot
  @Binding var selectedUTC: Date?
  let layoutMetrics: DashboardLayoutMetrics
  let usesTwoColumnOverview: Bool

  var body: some View {
    let chartSeries = series
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("論理CPU別")
          .font(.headline)
        Spacer()
        Text("OS indexを1始まり表示")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      if chartSeries.isEmpty {
        Text("この期間の論理CPU実測値はありません")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 100)
      } else {
        LazyVGrid(
          columns: gridColumns,
          alignment: .leading,
          spacing: layoutMetrics.sectionSpacing
        ) {
          ForEach(chartSeries, id: \.id) { item in
            logicalChart(item)
          }
        }
      }

      Text("各CPU 0〜100%・空白は未測定。物理コア種別は推測しません")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .dashboardPanel(padding: layoutMetrics.contentPadding * 0.65)
    .accessibilityIdentifier("logical-cpu-history-grid")
    .accessibilityValue(usesTwoColumnOverview ? "2列" : "自動列")
  }

  private var gridColumns: [GridItem] {
    if usesTwoColumnOverview {
      return Array(
        repeating: GridItem(
          .flexible(minimum: layoutMetrics.logicalCPUHistoryMinimumWidth),
          spacing: layoutMetrics.sectionSpacing
        ),
        count: 2
      )
    }
    return [
      GridItem(
        .adaptive(minimum: layoutMetrics.logicalCPUHistoryMinimumWidth),
        spacing: layoutMetrics.sectionSpacing
      )
    ]
  }

  private func logicalChart(
    _ item: DashboardLogicalCPUHistorySeries
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(item.displayName)
        .font(.caption.weight(.semibold))
      Chart {
        ForEach(item.points, id: \.pointID) { point in
          LineMark(
            x: .value("時刻", point.timestampUTC),
            y: .value("使用率", point.utilizationPercent),
            series: .value("連続区間", point.seriesIdentifier)
          )
          .foregroundStyle(Color.green)
          .lineStyle(StrokeStyle(lineWidth: 1.1))
        }
        if let selectedUTC {
          RuleMark(x: .value("選択UTC", selectedUTC))
            .foregroundStyle(Color.primary.opacity(0.35))
        }
      }
      .chartXScale(domain: snapshot.startUTC...snapshot.endUTC)
      .chartYScale(domain: 0...100)
      .chartXAxis(.hidden)
      .chartYAxis {
        AxisMarks(values: [0.0, 50.0, 100.0]) {
          AxisGridLine()
          AxisValueLabel()
        }
      }
      .chartLegend(.hidden)
      .chartXSelection(value: $selectedUTC)
      .frame(height: layoutMetrics.logicalCPUChartHeight)
      .accessibilityLabel("\(item.displayName)使用率の履歴")
    }
    .padding(7)
    .background(
      Color.primary.opacity(0.035),
      in: RoundedRectangle(cornerRadius: 8)
    )
  }

  private var series: [DashboardLogicalCPUHistorySeries] {
    snapshot.logicalCPUSeries
  }
}

struct DashboardSelectionDetailView: View {
  let selection: DashboardHistorySelection?
  let layoutMetrics: DashboardLayoutMetrics
  private let gigabyte = 1_000_000_000.0

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      if let selection {
        selectionHeader(selection)
        selectionSummaryTable(selection)

        HStack(
          alignment: .top,
          spacing: CGFloat(layoutMetrics.sectionSpacing)
        ) {
          if let total = selection.totalCPU {
            cpuBreakdownTable(total)
              .frame(maxWidth: .infinity, alignment: .topLeading)
          }

          if selection.logicalCPUs.isEmpty {
            Text("論理CPU: この時刻は未測定")
              .font(.body)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            logicalCPUTable(selection.logicalCPUs)
              .frame(maxWidth: .infinity, alignment: .topLeading)
          }
        }
      } else {
        Text("グラフ上の時刻を選択すると保存値と測定区間を確認できます")
          .font(.body)
          .foregroundStyle(.secondary)
      }
    }
    .dashboardPanel(padding: layoutMetrics.contentPadding * 0.65)
    .accessibilityIdentifier("dashboard-selection-details")
  }

  private func selectionHeader(
    _ selection: DashboardHistorySelection
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("選択時刻（UTC）")
          .font(.headline)
        Text(
          selection.requestedUTC.formatted(
            .dateTime.year().month().day().hour().minute().second()
          )
        )
        .font(.title3.weight(.semibold).monospacedDigit())
      }

      Spacer()

      Text("Pressure: \(selection.pressure?.rawValue ?? "未測定")")
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }
    .accessibilityIdentifier("selection-detail-header")
  }

  private func selectionSummaryTable(
    _ selection: DashboardHistorySelection
  ) -> some View {
    let rows: [[String]] = [
      selection.memory.map {
        [
          "メモリ（推定）",
          "\(($0.estimatedMemoryUsedBytes / gigabyte).formatted(.number.precision(.fractionLength(2)))) GB",
          intervalText($0),
        ]
      } ?? ["メモリ", "この時刻は未測定", "—"],
      selection.totalCPU.map {
        ["CPU全体", percent($0.utilizationPercent), intervalText($0)]
      } ?? ["CPU全体", "この時刻は未測定", "—"],
    ]
    return VStack(alignment: .leading, spacing: 5) {
      Text("選択時刻の保存値")
        .font(.headline)

      selectionTable(
        columns: [
          GridItem(.flexible(minimum: 110), alignment: .leading),
          GridItem(.flexible(minimum: 80), alignment: .leading),
          GridItem(.flexible(minimum: 190), alignment: .leading),
        ],
        header: ["項目", "値", "測定区間"],
        rows: rows,
        labelColumns: [0]
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .selectionTableBackground()
      .accessibilityIdentifier("selection-summary-table")
    }
  }

  private func cpuBreakdownTable(
    _ total: TotalCPUHistoryPoint
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("CPU内訳")
        .font(.headline)
      selectionTable(
        columns: [
          GridItem(.flexible(minimum: 90), alignment: .leading),
          GridItem(.flexible(minimum: 90), alignment: .leading),
        ],
        header: ["内訳", "使用率"],
        rows: [
          ["user", percent(total.userPercent)],
          ["system", percent(total.systemPercent)],
          ["nice", percent(total.nicePercent)],
          ["idle", percent(total.idlePercent)],
        ],
        labelColumns: [0]
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .selectionTableBackground()
      .accessibilityIdentifier("selection-cpu-breakdown-table")
    }
  }

  private func logicalCPUTable(
    _ logicalCPUs: [LogicalCPUHistoryPoint]
  ) -> some View {
    let pairs = stride(from: 0, to: logicalCPUs.count, by: 2).map { index in
      Array(logicalCPUs[index..<min(index + 2, logicalCPUs.count)])
    }
    return VStack(alignment: .leading, spacing: 5) {
      Text("論理CPU別")
        .font(.headline)
      selectionTable(
        columns: [
          GridItem(.flexible(minimum: 45), alignment: .leading),
          GridItem(.flexible(minimum: 65), alignment: .leading),
          GridItem(.flexible(minimum: 45), alignment: .leading),
          GridItem(.flexible(minimum: 65), alignment: .leading),
        ],
        header: ["CPU", "使用率", "CPU", "使用率"],
        rows: pairs.map { pair in
          if pair.count == 2 {
            return [
              pair[0].displayName,
              percent(pair[0].utilizationPercent),
              pair[1].displayName,
              percent(pair[1].utilizationPercent),
            ]
          } else {
            return [
              pair[0].displayName,
              percent(pair[0].utilizationPercent),
              "—",
              "—",
            ]
          }
        },
        labelColumns: [0, 2]
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .selectionTableBackground()
      .accessibilityIdentifier("selection-logical-cpu-table")
    }
  }

  private func selectionTable(
    columns: [GridItem],
    header: [String],
    rows: [[String]],
    labelColumns: Set<Int>
  ) -> some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
      ForEach(Array(header.enumerated()), id: \.offset) { _, value in
        Text(value)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 9)
          .padding(.vertical, 7)
          .background(Color.primary.opacity(0.055))
      }

      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        ForEach(Array(row.enumerated()), id: \.offset) { index, value in
          Text(value)
            .font(
              labelColumns.contains(index)
                ? .body.weight(.medium)
                : .body.monospacedDigit()
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
        }
      }
    }
  }

  private func percent(_ value: Double) -> String {
    "\(value.formatted(.number.precision(.fractionLength(1))))%"
  }

  private func intervalText(_ point: MemoryHistoryPoint) -> String {
    point.source == .raw
      ? point.timestampUTC.formatted(.dateTime.hour().minute().second())
      : "\(point.intervalStartUTC.formatted(.dateTime.hour().minute()))–\(point.intervalEndUTC.formatted(.dateTime.hour().minute())) / \(point.sampleCount)件"
  }

  private func intervalText(_ point: TotalCPUHistoryPoint) -> String {
    "\(point.intervalStartUTC.formatted(.dateTime.hour().minute().second()))–\(point.intervalEndUTC.formatted(.dateTime.hour().minute().second())) / \(point.sampleCount)件"
  }
}

extension View {
  fileprivate func dashboardPanel(padding: Double) -> some View {
    self.padding(CGFloat(padding))
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.secondary.opacity(0.16))
      )
  }

  fileprivate func selectionTableBackground() -> some View {
    self.background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.primary.opacity(0.025))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.secondary.opacity(0.14))
    )
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

  fileprivate var selectionID: String {
    "\(topology.epochKey)-\(cpuIndex)"
  }
}
