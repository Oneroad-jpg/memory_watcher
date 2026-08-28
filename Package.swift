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
    .testTarget(
      name: "MemoryWatcherCoreTests",
      dependencies: ["MemoryWatcherCore"]
    ),
  ]
)
