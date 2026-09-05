import MemoryWatcherCore
import SwiftUI

@MainActor
final class DashboardLayoutViewModel: ObservableObject {
  @Published private(set) var configuration: DashboardLayoutConfiguration
  @Published private(set) var revision: UInt64 = 0
  @Published var isEditorPresented = false
  @Published private(set) var persistenceErrorMessage: String?

  var configurationDidChange: ((DashboardLayoutConfiguration) -> Void)?

  private let store: DashboardLayoutConfigurationStore?

  init(store: DashboardLayoutConfigurationStore) {
    self.store = store
    configuration = store.load()
  }

  init(configuration: DashboardLayoutConfiguration) {
    store = nil
    self.configuration = configuration.resolved()
  }

  func presentEditor() {
    isEditorPresented = true
  }

  func setPreset(_ preset: DashboardLayoutPreset) {
    apply(
      DashboardLayoutConfiguration(
        preset: preset,
        sectionOrder: configuration.sectionOrder,
        hiddenSections: configuration.hiddenSections
      )
    )
  }

  func setVisible(_ visible: Bool, for section: DashboardLayoutSection) {
    guard section.canBeHidden else { return }
    var hidden = Set(configuration.hiddenSections)
    if visible {
      hidden.remove(section)
    } else {
      hidden.insert(section)
    }
    apply(
      DashboardLayoutConfiguration(
        preset: configuration.preset,
        sectionOrder: configuration.sectionOrder,
        hiddenSections: DashboardLayoutSection.allCases.filter(hidden.contains)
      )
    )
  }

  func move(_ section: DashboardLayoutSection, by offset: Int) {
    guard
      let index = configuration.sectionOrder.firstIndex(of: section)
    else { return }
    let destination = index + offset
    guard configuration.sectionOrder.indices.contains(destination) else {
      return
    }
    var order = configuration.sectionOrder
    order.swapAt(index, destination)
    apply(
      DashboardLayoutConfiguration(
        preset: configuration.preset,
        sectionOrder: order,
        hiddenSections: configuration.hiddenSections
      )
    )
  }

  func reset() {
    apply(.defaultConfiguration)
  }

  private func apply(_ proposed: DashboardLayoutConfiguration) {
    let resolved = proposed.resolved()
    do {
      try store?.save(resolved)
      persistenceErrorMessage = nil
    } catch {
      persistenceErrorMessage = "表示設定を保存できませんでした"
    }
    guard resolved != configuration else { return }
    configuration = resolved
    revision &+= 1
    configurationDidChange?(resolved)
  }
}

struct DashboardLayoutEditorView: View {
  @ObservedObject var viewModel: DashboardLayoutViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("表示設定")
            .font(.title2.weight(.semibold))
          Text("このMacだけに保存されます")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("完了") {
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("dashboard-layout-editor-done")
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("表示密度")
          .font(.headline)
        Picker(
          "表示密度",
          selection: Binding(
            get: { viewModel.configuration.preset },
            set: { viewModel.setPreset($0) }
          )
        ) {
          ForEach(DashboardLayoutPreset.allCases, id: \.self) { preset in
            Text(preset.displayName).tag(preset)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("dashboard-layout-preset-picker")
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("表示項目と順序")
          .font(.headline)
        ForEach(viewModel.configuration.sectionOrder, id: \.self) { section in
          sectionRow(section)
        }
      }

      if let message = viewModel.persistenceErrorMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityIdentifier("dashboard-layout-save-error")
      }

      HStack {
        Button("標準に戻す") {
          viewModel.reset()
        }
        .accessibilityLabel("表示設定を標準に戻す")
        .accessibilityHint("balanced、標準順、すべて表示へ戻します")
        .accessibilityIdentifier("dashboard-layout-reset")
        Spacer()
      }
    }
    .padding(24)
    .frame(minWidth: 520)
    .accessibilityIdentifier("dashboard-layout-editor")
  }

  private func sectionRow(_ section: DashboardLayoutSection) -> some View {
    let index = viewModel.configuration.sectionOrder.firstIndex(of: section) ?? 0
    return HStack(spacing: 10) {
      if section.canBeHidden {
        Toggle(
          section.displayName,
          isOn: Binding(
            get: { viewModel.configuration.isVisible(section) },
            set: { viewModel.setVisible($0, for: section) }
          )
        )
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("dashboard-layout-visible-\(section.rawValue)")
      } else {
        Label(section.displayName, systemImage: "checkmark.circle.fill")
          .accessibilityLabel("\(section.displayName)、常に表示")
      }

      Spacer()

      Button {
        viewModel.move(section, by: -1)
      } label: {
        Image(systemName: "arrow.up")
      }
      .buttonStyle(.borderless)
      .disabled(index == 0)
      .accessibilityLabel("\(section.displayName)を上へ移動")
      .accessibilityIdentifier("dashboard-layout-move-up-\(section.rawValue)")

      Button {
        viewModel.move(section, by: 1)
      } label: {
        Image(systemName: "arrow.down")
      }
      .buttonStyle(.borderless)
      .disabled(index == viewModel.configuration.sectionOrder.count - 1)
      .accessibilityLabel("\(section.displayName)を下へ移動")
      .accessibilityIdentifier("dashboard-layout-move-down-\(section.rawValue)")
    }
    .padding(.vertical, 5)
    .padding(.horizontal, 10)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }
}

extension DashboardLayoutPreset {
  fileprivate var displayName: String {
    switch self {
    case .compact: "コンパクト"
    case .balanced: "標準"
    case .detailed: "詳細"
    }
  }
}

extension DashboardLayoutSection {
  fileprivate var displayName: String {
    switch self {
    case .memoryHistory: "メモリ履歴"
    case .totalCPUHistory: "Mac全体CPU"
    case .logicalCPUHistory: "論理CPU別履歴"
    case .selectionDetails: "選択時刻の詳細"
    }
  }
}
