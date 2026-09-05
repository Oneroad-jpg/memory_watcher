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
          columns: [
            GridItem(
              .adaptive(
                minimum: layoutMetrics.logicalCPUHistoryMinimumWidth
              ),
              spacing: layoutMetrics.sectionSpacing
            )
          ],
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
        HStack {
          Text("選択UTC")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(
            selection.requestedUTC.formatted(
              .dateTime.year().month().day().hour().minute().second()
            )
          )
          .font(.subheadline.weight(.semibold))
          Spacer()
          Text("Pressure: \(selection.pressure?.rawValue ?? "未測定")")
            .font(.caption)
        }

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 128), spacing: 12)],
          alignment: .leading,
          spacing: 8
        ) {
          if let memory = selection.memory {
            metric(
              "メモリ（推定）",
              "\((memory.estimatedMemoryUsedBytes / gigabyte).formatted(.number.precision(.fractionLength(2)))) GB"
            )
            metric("メモリ区間", intervalText(memory))
          } else {
            metric("メモリ", "この時刻は未測定")
          }

          if let total = selection.totalCPU {
            metric("CPU全体", percent(total.utilizationPercent))
            metric("CPU区間", intervalText(total))
            metric("user", percent(total.userPercent))
            metric("system", percent(total.systemPercent))
            metric("nice", percent(total.nicePercent))
            metric("idle", percent(total.idlePercent))
          } else {
            metric("CPU全体", "この時刻は未測定")
          }
        }

        if selection.logicalCPUs.isEmpty {
          Text("論理CPU: この時刻は未測定")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 92), spacing: 10)],
            alignment: .leading,
            spacing: 6
          ) {
            ForEach(selection.logicalCPUs, id: \.selectionID) { cpu in
              metric(cpu.displayName, percent(cpu.utilizationPercent))
            }
          }
        }
      } else {
        Text("グラフ上の時刻を選択すると保存値と測定区間を確認できます")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .dashboardPanel(padding: layoutMetrics.contentPadding * 0.65)
    .accessibilityIdentifier("dashboard-selection-details")
  }

  private func metric(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption.monospacedDigit())
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
