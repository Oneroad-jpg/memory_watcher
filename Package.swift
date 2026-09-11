// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MemoryWatcher",
  platforms: [
    .macOS(.v14),
    .watchOS(.v10)
  ],
  products: [
    .library(
      name: "MemoryWatcherShared",
      targets: ["MemoryWatcherShared"]
    ),
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
      name: "MemoryWatcherShared"
    ),
    .target(
      name: "MemoryWatcherCore",
      dependencies: ["CSQLite", "MemoryWatcherShared"]
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
    .testTarget(
      name: "MemoryWatcherSharedTests",
      dependencies: ["MemoryWatcherShared"]
    ),
  ]
)
