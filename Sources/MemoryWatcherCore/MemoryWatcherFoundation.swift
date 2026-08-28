import CSQLite
import Foundation

public enum MemoryWatcherFoundation: Sendable {
  public static let appName = "Memory Watcher"
  public static let sampleInterval: TimeInterval = 5
  public static let minimumSystemMajorVersion = 14

  public static var sqliteVersionNumber: Int32 {
    sqlite3_libversion_number()
  }
}
