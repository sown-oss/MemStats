import AppKit
import Darwin

/// Quit asks a process to exit (a quit Apple event for apps, SIGTERM otherwise). Force Quit
/// cannot be ignored (SIGKILL, or a forced termination for apps).
nonisolated enum ProcessQuitMode: Sendable, Equatable {
  case quit
  case forceQuit
}

/// A process as the kernel saw it when the user asked to quit it, so a reused PID is never
/// signaled.
nonisolated struct ProcessTarget: Sendable, Equatable {
  let pid: Int32
  /// Real uid, the one `kill(2)` checks against.
  let uid: uid_t
  /// Start time in microseconds since 1970. A new process with the same PID has a later one.
  let startMicroseconds: Int64
  /// Kernel short name (`p_comm`, at most 16 characters).
  let name: String

  var startDate: Date {
    Date(timeIntervalSince1970: Double(startMicroseconds) / 1_000_000)
  }
}

nonisolated enum ProcessTerminationError: Error, Equatable {
  case notRunning
  /// The PID now belongs to a process that started after the one the user picked.
  case processChanged
  case notOwned
  case protected
  case signalFailed(Int32)
}

protocol ProcessTerminating {
  func target(pid: Int32) -> ProcessTarget?
  /// Checks every target again, then signals them. Throws only when nothing was signaled.
  func terminate(_ targets: [ProcessTarget], mode: ProcessQuitMode) throws(ProcessTerminationError)
}

struct ProcessTerminator: ProcessTerminating {
  /// Killing these hangs the Mac or logs the user out. Most run as root and are already blocked
  /// by the ownership check, but `loginwindow` runs as the user.
  nonisolated static let protectedNames: Set<String> = [
    "kernel_task", "launchd", "loginwindow", "WindowServer",
  ]

  nonisolated static func isProtected(pid: Int32, name: String) -> Bool {
    pid <= 1 || pid == getpid() || protectedNames.contains(name)
  }

  /// Reads the process from `sysctl`, which works for every user's processes without privileges.
  nonisolated func target(pid: Int32) -> ProcessTarget? {
    guard pid > 0 else { return nil }
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }

    let start = info.kp_proc.p_un.__p_starttime
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) { buffer in
      String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
    return ProcessTarget(
      pid: pid,
      uid: info.kp_eproc.e_pcred.p_ruid,
      startMicroseconds: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec),
      name: name
    )
  }

  func terminate(_ targets: [ProcessTarget], mode: ProcessQuitMode) throws(ProcessTerminationError)
  {
    var firstError: ProcessTerminationError?
    var checked: [ProcessTarget] = []
    for target in targets {
      do {
        try verify(target)
        checked.append(target)
      } catch {
        firstError = firstError ?? error
      }
    }

    // Quit only asks the app itself when there is one: its helpers exit with it, and a graceful
    // quit lets the app save its work instead of having its helpers killed under it. Force Quit
    // signals everything, so no helper is left behind.
    let apps = checked.filter { Self.regularApp(pid: $0.pid) != nil }
    let signaled = mode == .quit && !apps.isEmpty ? apps : checked
    var signaledCount = 0
    for target in signaled {
      do {
        try signal(target, mode: mode)
        signaledCount += 1
      } catch {
        firstError = firstError ?? error
      }
    }
    if signaledCount == 0 {
      throw firstError ?? .notRunning
    }
  }

  private static func regularApp(pid: Int32) -> NSRunningApplication? {
    guard let app = NSRunningApplication(processIdentifier: pid),
      app.activationPolicy == .regular
    else { return nil }
    return app
  }

  private func verify(_ expected: ProcessTarget) throws(ProcessTerminationError) {
    guard let current = target(pid: expected.pid) else { throw .notRunning }
    guard current.startMicroseconds == expected.startMicroseconds else { throw .processChanged }
    guard current.uid == getuid() else { throw .notOwned }
    guard !Self.isProtected(pid: current.pid, name: current.name) else { throw .protected }
  }

  private func signal(_ target: ProcessTarget, mode: ProcessQuitMode)
    throws(ProcessTerminationError)
  {
    // Apps get the same request as the Dock's Quit. Agents and helpers often ignore it, so they
    // get a signal. `false` means the request could not be sent, so fall back to a signal too.
    if let app = Self.regularApp(pid: target.pid) {
      let sent = mode == .quit ? app.terminate() : app.forceTerminate()
      if sent { return }
    }
    guard kill(target.pid, mode == .quit ? SIGTERM : SIGKILL) == 0 else {
      let code = errno
      switch code {
      case ESRCH: throw .notRunning
      case EPERM: throw .notOwned
      default: throw .signalFailed(code)
      }
    }
  }
}
