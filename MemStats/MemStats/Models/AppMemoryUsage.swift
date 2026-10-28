import Foundation

struct AppIdentity: Sendable, Hashable {
  let id: String
  let name: String
  let path: String?
}

struct AppMemoryUsage: Identifiable, Sendable, Equatable {
  let id: String
  let name: String
  let path: String?
  let bytes: UInt64
  let processCount: Int
  /// PIDs of the grouped processes, in snapshot order.
  var pids: [Int32] = []

  /// The `.app` bundle the processes belong to, `nil` for an executable outside a bundle.
  var bundlePath: String? {
    guard let path, path.hasSuffix(".app") else { return nil }
    return path
  }
}
