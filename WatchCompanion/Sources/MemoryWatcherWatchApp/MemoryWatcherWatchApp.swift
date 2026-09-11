import SwiftUI
import MemoryWatcherShared

@main
struct MemoryWatcherWatchApp: App {
  var body: some Scene {
    WindowGroup {
      MemoryStatusView(store: MemoryWatchSnapshotStore())
    }
  }
}

@MainActor
final class MemoryWatchSnapshotStore: ObservableObject {
  @Published private(set) var snapshot: MemoryWatchSnapshot?

  let transportStatus = "Mac connection reserved"

  func accept(_ snapshot: MemoryWatchSnapshot) {
    self.snapshot = snapshot
  }
}

struct MemoryStatusView: View {
  @StateObject private var store: MemoryWatchSnapshotStore

  init(store: MemoryWatchSnapshotStore) {
    _store = StateObject(wrappedValue: store)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Text("Memory Watcher")
          .font(.headline)

        if let snapshot = store.snapshot {
          snapshotContent(snapshot)
        } else {
          Label("Mac未接続", systemImage: "macbook")
            .foregroundStyle(.secondary)
          Text("認証済み転送は次工程です")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
    }
  }

  private func snapshotContent(
    _ snapshot: MemoryWatchSnapshot
  ) -> some View {
    let state = snapshot.semanticState
    let usedPercent = state.memoryUsedFraction * 100

    return VStack(alignment: .leading, spacing: 6) {
      Text(state.attention.rawValue)
        .font(.title3.monospaced())
      if state.provenance.authority == .extensionCandidate {
        Label("拡張候補", systemImage: "puzzlepiece.extension")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      ProgressView(value: state.memoryUsedFraction)
        .tint(tint(for: state.attention))
      Text("使用量（推定） \(usedPercent, format: .number.precision(.fractionLength(0)))%")
        .font(.caption)
      Text(state.observation.capturedAtUTC, style: .time)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private func tint(
    for state: MemoryWatcherAttentionState
  ) -> Color {
    switch state {
    case .unknown:
      return .gray
    case .nominal:
      return .green
    case .elevated:
      return .orange
    case .critical:
      return .red
    }
  }
}

#if DEBUG
  #Preview("No Mac connection") {
    MemoryStatusView(store: MemoryWatchSnapshotStore())
  }
#endif
