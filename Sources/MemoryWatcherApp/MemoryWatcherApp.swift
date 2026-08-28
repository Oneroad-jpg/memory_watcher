import AppKit
import Foundation
import SwiftUI

@main
enum MemoryWatcherApp {
  @MainActor
  private static var window: NSWindow?

  @MainActor
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let smokeTestRequested =
      Array(CommandLine.arguments.dropFirst()) == ["--smoke-test"]

    let contentView = NSHostingView(rootView: FoundationView())
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.center()
    window.contentView = contentView
    window.title = "Memory Watcher"
    window.isReleasedWhenClosed = false
    self.window = window

    DispatchQueue.main.async {
      application.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      window.orderFrontRegardless()

      if smokeTestRequested {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "UNKNOWN"
        let windowCount = application.windows.count
        let visible = window.isVisible
        let status =
          bundleIdentifier == "com.oneroad.memorywatcher"
            && windowCount == 1
            && visible
          ? "PASS"
          : "FAIL"
        let result: [String: Any] = [
          "bundle_identifier": bundleIdentifier,
          "status": status,
          "visible": visible,
          "window_count": windowCount,
        ]
        let data = try? JSONSerialization.data(
          withJSONObject: result,
          options: [.sortedKeys]
        )
        if let data {
          FileHandle.standardOutput.write(data)
          FileHandle.standardOutput.write(Data([0x0A]))
        }
        application.terminate(nil)
      }
    }
    application.run()
  }
}
