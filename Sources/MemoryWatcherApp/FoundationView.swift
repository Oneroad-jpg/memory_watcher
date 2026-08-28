import MemoryWatcherCore
import SwiftUI

struct FoundationView: View {
  @ObservedObject var viewModel: MonitoringViewModel

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        HStack(spacing: 16) {
          Image(systemName: "memorychip")
            .font(.system(size: 42))
            .foregroundStyle(.blue)

          VStack(alignment: .leading, spacing: 3) {
            Text(MemoryWatcherFoundation.appName)
              .font(.title)
              .fontWeight(.semibold)
            if let usedBytes = viewModel.lastMemoryUsedBytes {
              Text("現在の使用量（推定） \(formatGigabytes(usedBytes)) GB")
                .font(.headline)
            } else {
              Text("最初の測定を待っています")
                .foregroundStyle(.secondary)
            }
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
          }
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

        MemoryHistoryChartView(viewModel: viewModel)

        if let errorMessage = viewModel.errorMessage {
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
            .accessibilityIdentifier("memory-watcher-runtime-error")
        }
      }
      .padding(24)
    }
    .frame(minWidth: 940, minHeight: 760)
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
