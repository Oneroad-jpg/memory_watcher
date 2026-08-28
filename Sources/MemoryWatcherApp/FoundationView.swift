import Charts
import MemoryWatcherCore
import SwiftUI

struct FoundationView: View {
  @ObservedObject var viewModel: MonitoringViewModel

  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "memorychip")
        .font(.system(size: 52))
        .foregroundStyle(.blue)

      Text(MemoryWatcherFoundation.appName)
        .font(.largeTitle)
        .fontWeight(.semibold)

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
      }

      if let usedBytes = viewModel.lastMemoryUsedBytes {
        Text("現在の使用量（推定） \(formatGigabytes(usedBytes)) GB")
          .font(.headline)
      } else {
        Text("最初の測定を待っています")
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        Toggle(
          "ログイン時にMemory Watcherを起動",
          isOn: Binding(
            get: { viewModel.loginItemIsRegistered },
            set: { viewModel.setLoginItemEnabled($0) }
          )
        )
        .accessibilityIdentifier("memory-watcher-login-item-toggle")

        if viewModel.loginItemStatus == .requiresApproval {
          HStack {
            Text("システム設定での許可が必要です")
              .foregroundStyle(.orange)
            Button("ログイン項目を開く") {
              viewModel.openLoginItemSettings()
            }
          }
        }
      }

      Chart {
        RuleMark(y: .value("Baseline", 0))
          .foregroundStyle(.blue.opacity(0.4))
      }
      .frame(height: 80)
      .accessibilityLabel("Memory history placeholder")

      if let errorMessage = viewModel.errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
          .accessibilityIdentifier("memory-watcher-runtime-error")
      }
    }
    .padding(40)
    .frame(minWidth: 560, minHeight: 360)
    .accessibilityIdentifier("memory-watcher-foundation-ready")
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
