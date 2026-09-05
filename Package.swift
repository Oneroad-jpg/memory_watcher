// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MemoryWatcher",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "MemoryWatcherCore",
      targets: ["MemoryWatcherCore"]
    ),
    .executable(
      name: "MemoryWatcher",
      targets: ["MemoryWatcherApp"]
    ),
    .executable(
      name: "MemoryWatcherProbe",
      targets: ["MemoryWatcherProbe"]
    ),
    .executable(
      name: "MemoryWatcherAudit",
      targets: ["MemoryWatcherAudit"]
    ),
  ],
  targets: [
    .systemLibrary(
      name: "CSQLite"
    ),
    .target(
      name: "MemoryWatcherCore",
      dependencies: ["CSQLite"]
    ),
    .executableTarget(
      name: "MemoryWatcherApp",
      dependencies: ["MemoryWatcherCore"]
    ),
    .executableTarget(
      name: "MemoryWatcherProbe",
      dependencies: ["MemoryWatcherCore"]
    ),
    .executableTarget(
      name: "MemoryWatcherAudit",
      dependencies: ["MemoryWatcherCore"]
    ),
    .testTarget(
      name: "MemoryWatcherCoreTests",
      dependencies: ["MemoryWatcherCore", "CSQLite"]
    ),
    .testTarget(
      name: "MemoryWatcherAuditTests",
      dependencies: ["MemoryWatcherAudit", "MemoryWatcherCore"]
    ),
  ]
)
