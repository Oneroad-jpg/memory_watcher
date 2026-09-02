import AppKit
import MemoryWatcherCore
import SwiftUI

@MainActor
final class DashboardRenderDiagnostics {
  private(set) var currentRootUpdateCount: UInt64 = 0
  private(set) var historyRootUpdateCount: UInt64 = 0

  func recordCurrentRootUpdate() {
    currentRootUpdateCount &+= 1
  }

  func recordHistoryRootUpdate() {
    historyRootUpdateCount &+= 1
  }
}

struct CurrentValuesRootView: View {
  @ObservedObject var viewModel: MonitoringViewModel
  let diagnostics: DashboardRenderDiagnostics

  var body: some View {
    VStack(spacing: 8) {
      TimelineView(.periodic(from: .now, by: 5)) { context in
        MonitoringStatusView(viewModel: viewModel, now: context.date)
      }
      MonitoringErrorView(viewModel: viewModel)
    }
    .padding(.horizontal, 24)
    .padding(.top, 16)
    .padding(.bottom, 8)
    .frame(minWidth: 780)
    .accessibilityIdentifier("memory-watcher-foundation-ready")
    #if DEBUG
      .background(
        DashboardRenderProbe(
          root: .current,
          revision: viewModel.currentValuesRevision,
          diagnostics: diagnostics
        )
      )
    #endif
  }
}

struct HistoryRootView: View {
  @ObservedObject var viewModel: HistoryViewModel
  let diagnostics: DashboardRenderDiagnostics

  var body: some View {
    ScrollView {
      MemoryHistoryChartView(viewModel: viewModel)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }
    .frame(minWidth: 780, minHeight: 400)
    .accessibilityIdentifier("memory-watcher-history-root")
    #if DEBUG
      .background(
        DashboardRenderProbe(
          root: .history,
          revision: viewModel.historyGeneration,
          diagnostics: diagnostics
        )
      )
    #endif
  }
}

#if DEBUG
  private enum DashboardRenderRoot {
    case current
    case history
  }

  @MainActor
  private struct DashboardRenderProbe: NSViewRepresentable {
    let root: DashboardRenderRoot
    let revision: UInt64
    let diagnostics: DashboardRenderDiagnostics

    func makeNSView(context: Context) -> NSView {
      recordUpdate()
      return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
      recordUpdate()
    }

    private func recordUpdate() {
      switch root {
      case .current:
        diagnostics.recordCurrentRootUpdate()
      case .history:
        diagnostics.recordHistoryRootUpdate()
      }
    }
  }
#endif

private struct MonitoringStatusView: View {
  @ObservedObject var viewModel: MonitoringViewModel
  let now: Date

  var body: some View {
    VStack(spacing: 12) {
      HStack(spacing: 12) {
        Image(systemName: "memorychip")
          .font(.system(size: 42))
          .foregroundStyle(.blue)

        VStack(alignment: .leading, spacing: 3) {
          Text(MemoryWatcherFoundation.appName)
            .font(.title)
            .fontWeight(.semibold)
          currentMemoryLabel
        }

        Spacer()

        HStack(spacing: 24) {
          statusValue(
            title: "監視",
            value: viewModel.runState.rawValue.uppercased()
          )
          statusValue(
            title: "記録",
            value: "\(viewModel.sampleCount)"
          )
          statusValue(
            title: "Pressure",
            value: viewModel.pressureLevel.rawValue
          )
          statusValue(title: "CPU全体", value: totalCPUText)
        }
      }

      if logicalCPUs.isEmpty {
        HStack {
          Text("論理CPU: 最初の測定を待っています")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }
      } else {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 104), spacing: 6)],
          alignment: .leading,
          spacing: 6
        ) {
          ForEach(logicalCPUs, id: \.cpuIndex) { cpu in
            logicalCPUMeter(cpu)
          }
        }
        .accessibilityIdentifier("logical-cpu-current-grid")
      }

      HStack {
        Toggle(
          "ログイン時にMemory Watcherを起動",
          isOn: Binding(
            get: { viewModel.loginItemIsRegistered },
            set: { viewModel.setLoginItemEnabled($0) }
          )
        )
        .accessibilityIdentifier("memory-watcher-login-item-toggle")

        if viewModel.loginItemStatus == .requiresApproval {
          Text("システム設定での許可が必要です")
            .foregroundStyle(.orange)
          Button("ログイン項目を開く") {
            viewModel.openLoginItemSettings()
          }
        }
        Spacer()
      }
    }
  }

  @ViewBuilder
  private var currentMemoryLabel: some View {
    let memory = viewModel.currentMemory(at: now)
    if let usedBytes = memory.usedBytes {
      HStack(spacing: 6) {
        Text("\(formatGigabytes(usedBytes)) GB")
          .font(.headline.monospacedDigit())
        Text(memory.status == .current ? "現在" : "更新待ち／最終値")
          .font(.caption)
          .foregroundStyle(
            memory.status == .current ? Color.secondary : Color.orange
          )
      }
    } else {
      Text(memory.status == .invalid ? "メモリ値が不正です" : "最初の測定を待っています")
        .foregroundStyle(
          memory.status == .invalid ? Color.red : Color.secondary
        )
    }
  }

  private var logicalCPUs: [DashboardLogicalCPUPresentation] {
    _ = viewModel.currentValuesRevision
    return viewModel.currentLogicalCPUs(at: now)
  }

  private var totalCPUText: String {
    cpuText(viewModel.currentTotalCPU(at: now))
  }

  private func logicalCPUMeter(
    _ cpu: DashboardLogicalCPUPresentation
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(cpu.displayName)
          .font(.caption.weight(.semibold))
        Spacer()
        Text(cpuText(cpu.value))
          .font(.caption.monospacedDigit())
      }
      if let percent = cpu.value.percent,
        cpu.value.status != .invalid
      {
        CPUUtilizationBar(
          percent: percent,
          color: cpu.value.status == .current ? .green : .orange
        )
      } else {
        Capsule()
          .fill(Color.secondary.opacity(0.18))
          .frame(height: 4)
      }
    }
    .padding(5)
    .background(
      Color.primary.opacity(0.045),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .accessibilityElement(children: .combine)
  }

  private func cpuText(_ value: DashboardCPUPresentation) -> String {
    switch value.status {
    case .current:
      return percentText(value.percent)
    case .stale:
      return "最終 \(percentText(value.percent))"
    case .unknown:
      return value.showsFinalValue
        ? "UNKNOWN（最終 \(percentText(value.percent))）"
        : "UNKNOWN"
    case .unavailable:
      return value.showsFinalValue
        ? "取得不能（最終 \(percentText(value.percent))）"
        : "取得不能"
    case .invalid:
      return "不正値"
    }
  }

  private func percentText(_ percent: Double?) -> String {
    guard let percent else { return "—" }
    return "\(percent.formatted(.number.precision(.fractionLength(1))))%"
  }

  private func statusValue(title: String, value: String) -> some View {
    VStack(spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.headline.monospaced())
    }
  }

  private func formatGigabytes(_ bytes: UInt64) -> String {
    String(format: "%.2f", Double(bytes) / 1_000_000_000)
  }
}

private struct CPUUtilizationBar: View {
  let percent: Double
  let color: Color

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.secondary.opacity(0.18))
        Capsule()
          .fill(color)
          .frame(width: proxy.size.width * percent / 100)
      }
    }
    .frame(height: 4)
  }
}

private struct MonitoringErrorView: View {
  @ObservedObject var viewModel: MonitoringViewModel

  var body: some View {
    if let errorMessage = viewModel.errorMessage {
      Text(errorMessage)
        .font(.caption)
        .foregroundStyle(.red)
        .lineLimit(2)
        .accessibilityIdentifier("memory-watcher-runtime-error")
    }
  }
}
