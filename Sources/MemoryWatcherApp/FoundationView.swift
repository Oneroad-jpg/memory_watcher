import Charts
import MemoryWatcherCore
import SwiftUI

struct FoundationView: View {
  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "memorychip")
        .font(.system(size: 52))
        .foregroundStyle(.blue)

      Text(MemoryWatcherFoundation.appName)
        .font(.largeTitle)
        .fontWeight(.semibold)

      Text("Memory history will appear here as each verified phase is completed.")
        .foregroundStyle(.secondary)

      Chart {
        RuleMark(y: .value("Baseline", 0))
          .foregroundStyle(.blue.opacity(0.4))
      }
      .frame(height: 80)
      .accessibilityLabel("Memory history placeholder")
    }
    .padding(40)
    .frame(minWidth: 560, minHeight: 360)
    .accessibilityIdentifier("memory-watcher-foundation-ready")
  }
}
