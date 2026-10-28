import Darwin
import Foundation

enum AppIdentityResolver {
  nonisolated static func resolve(pids: [Int32]) -> [Int32: AppIdentity] {
    var identities: [Int32: AppIdentity] = [:]
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    for pid in pids {
      guard let path = executablePath(for: pid, buffer: &buffer) ?? launchPath(for: pid) else {
        continue
      }
      identities[pid] = identity(forExecutablePath: path)
    }
    return identities
  }

  /// Groups helper processes into their outermost `.app` bundle, otherwise by executable path.
  nonisolated static func identity(forExecutablePath path: String) -> AppIdentity {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    if let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") && $0.count > 4 }) {
      let bundlePath = components[...appIndex].joined(separator: "/")
      let name = String(components[appIndex].dropLast(4))
      return AppIdentity(id: "app:\(bundlePath)", name: name, path: bundlePath)
    }

    let executableName = components.last.map(String.init) ?? path
    return AppIdentity(
      id: "exec:\(path)",
      name: executableName.isEmpty ? path : executableName,
      path: path
    )
  }

  nonisolated static func fallbackIdentity(forCommand command: String) -> AppIdentity {
    let name = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = name.isEmpty ? "Unknown" : name
    return AppIdentity(id: "name:\(displayName)", name: displayName, path: nil)
  }

  nonisolated private static func executablePath(
    for pid: Int32,
    buffer: inout [CChar]
  ) -> String? {
    guard pid > 0 else { return nil }

    let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
    guard length > 0 else { return nil }

    let bytes = buffer.prefix(length).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// The path the process was started from, kept with its arguments. `proc_pidpath` fails once
  /// the executable is deleted, as when an app updates itself while running, and the app would
  /// then be grouped apart from its helpers. Only readable for the current user's processes.
  nonisolated static func launchPath(for pid: Int32) -> String? {
    guard pid > 0 else { return nil }
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, u_int(mib.count), &bytes, &size, nil, 0) == 0,
      let path = launchPath(fromArguments: Array(bytes.prefix(size)))
    else { return nil }
    // Unlike `proc_pidpath`, this is the path as typed, which can go through a symlink or `..`.
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }

  /// Reads the executable path that follows `argc` in a `KERN_PROCARGS2` buffer. A relative path
  /// depends on the process's working directory, so it is ignored.
  nonisolated static func launchPath(fromArguments bytes: [UInt8]) -> String? {
    let path = bytes.dropFirst(MemoryLayout<Int32>.size).prefix { $0 != 0 }
    guard path.first == UInt8(ascii: "/") else { return nil }
    return String(decoding: path, as: UTF8.self)
  }
}

enum AppMemoryAggregator {
  nonisolated static func aggregate(
    processes: [ProcessSnapshot],
    identities: [Int32: AppIdentity],
    limit: Int? = nil
  ) -> [AppMemoryUsage] {
    var identityByID: [String: AppIdentity] = [:]
    var bytesByID: [String: UInt64] = [:]
    var pidsByID: [String: [Int32]] = [:]

    for process in processes {
      let identity =
        identities[process.pid]
        ?? AppIdentityResolver.fallbackIdentity(forCommand: process.command)
      identityByID[identity.id] = identity
      bytesByID[identity.id, default: 0] += process.rssBytes
      pidsByID[identity.id, default: []].append(process.pid)
    }

    let apps =
      identityByID.values
      .map { identity in
        AppMemoryUsage(
          id: identity.id,
          name: identity.name,
          path: identity.path,
          bytes: bytesByID[identity.id, default: 0],
          processCount: pidsByID[identity.id, default: []].count,
          pids: pidsByID[identity.id, default: []]
        )
      }
      .sorted { lhs, rhs in
        if lhs.bytes == rhs.bytes {
          return lhs.name < rhs.name
        }
        return lhs.bytes > rhs.bytes
      }

    if let limit {
      return Array(apps.prefix(max(limit, 0)))
    }

    return apps
  }
}
