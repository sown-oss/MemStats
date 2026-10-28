import Darwin
import Foundation
import Testing

@testable import MemStats

struct ProcessQuitTests {
  private final class StubProcessTerminator: ProcessTerminating {
    var targetsByPID: [Int32: ProcessTarget] = [:]
    var error: ProcessTerminationError?
    private(set) var terminatedTargets: [[ProcessTarget]] = []
    private(set) var terminatedModes: [ProcessQuitMode] = []

    func target(pid: Int32) -> ProcessTarget? {
      targetsByPID[pid]
    }

    func terminate(_ targets: [ProcessTarget], mode: ProcessQuitMode)
      throws(ProcessTerminationError)
    {
      terminatedTargets.append(targets)
      terminatedModes.append(mode)
      if let error {
        throw error
      }
    }
  }

  private struct StubMemoryProvider: MemoryStatsProviding {
    nonisolated func fetchMemoryStats() throws -> MemoryStats {
      MemoryStats(
        totalBytes: 1_000,
        usedBytes: 600,
        freeBytes: 400,
        activeBytes: 0,
        inactiveBytes: 0,
        wiredBytes: 0,
        compressedBytes: 0,
        swapUsedBytes: 0,
        pressureLevel: .normal
      )
    }
  }

  /// Keeps samples triggered by the app state away from the real `top`.
  private struct StubProcessProvider: ProcessSnapshotProviding {
    let processes: [ProcessSnapshot]

    nonisolated func fetchProcesses(includeRootUser: Bool, includeSystemUsers: Bool) throws
      -> [ProcessSnapshot]
    {
      processes
    }

    nonisolated func fetchTopProcesses(
      limit: Int,
      includeRootUser: Bool,
      includeSystemUsers: Bool
    ) throws -> [ProcessSnapshot] {
      Array(processes.prefix(limit))
    }
  }

  private static func target(pid: Int32, startedAt start: Date = .distantPast) -> ProcessTarget {
    ProcessTarget(
      pid: pid,
      uid: getuid(),
      startMicroseconds: Int64(start.timeIntervalSince1970 * 1_000_000),
      name: "test"
    )
  }

  @MainActor private static func makeAppState(
    terminator: StubProcessTerminator,
    suiteName: String,
    processes: [ProcessSnapshot] = []
  ) -> MemStatsAppState {
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return MemStatsAppState(
      startSampling: false,
      defaults: defaults,
      memoryService: StubMemoryProvider(),
      processService: StubProcessProvider(processes: processes),
      processTerminator: terminator,
      currentUser: "alice"
    )
  }

  private static func launchSleep() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    return process
  }

  // MARK: - ProcessTerminator

  @Test func terminatorProtectsSystemProcessesAndItself() {
    #expect(ProcessTerminator.isProtected(pid: 0, name: "kernel_task"))
    #expect(ProcessTerminator.isProtected(pid: 1, name: "launchd"))
    #expect(ProcessTerminator.isProtected(pid: getpid(), name: "MemStats"))
    #expect(ProcessTerminator.isProtected(pid: 500, name: "loginwindow"))
    #expect(ProcessTerminator.isProtected(pid: 500, name: "WindowServer"))
    #expect(!ProcessTerminator.isProtected(pid: 500, name: "Safari"))
  }

  @MainActor @Test func terminatorReadsOwnerAndStartTime() throws {
    let process = try Self.launchSleep()
    defer { process.terminate() }

    let target = try #require(ProcessTerminator().target(pid: process.processIdentifier))
    #expect(target.uid == getuid())
    #expect(target.name == "sleep")
    #expect(target.startDate <= Date())
    #expect(target.startDate > Date().addingTimeInterval(-60))
  }

  @MainActor @Test func terminatorQuitSendsSigterm() throws {
    let process = try Self.launchSleep()
    let terminator = ProcessTerminator()
    let target = try #require(terminator.target(pid: process.processIdentifier))

    try terminator.terminate([target], mode: .quit)
    process.waitUntilExit()

    #expect(process.terminationReason == .uncaughtSignal)
    #expect(process.terminationStatus == SIGTERM)
  }

  @MainActor @Test func terminatorForceQuitSendsSigkill() throws {
    let process = try Self.launchSleep()
    let terminator = ProcessTerminator()
    let target = try #require(terminator.target(pid: process.processIdentifier))

    try terminator.terminate([target], mode: .forceQuit)
    process.waitUntilExit()

    #expect(process.terminationReason == .uncaughtSignal)
    #expect(process.terminationStatus == SIGKILL)
  }

  @MainActor @Test func terminatorSkipsReusedPID() throws {
    let process = try Self.launchSleep()
    defer { process.terminate() }
    let terminator = ProcessTerminator()
    let current = try #require(terminator.target(pid: process.processIdentifier))
    let older = ProcessTarget(
      pid: current.pid,
      uid: current.uid,
      startMicroseconds: current.startMicroseconds - 1,
      name: current.name
    )

    #expect(throws: ProcessTerminationError.processChanged) {
      try terminator.terminate([older], mode: .forceQuit)
    }
    #expect(process.isRunning)
  }

  @MainActor @Test func terminatorRefusesOtherUsersProcesses() throws {
    let terminator = ProcessTerminator()
    // launchd runs as root, so the ownership check fails before any signal is sent.
    let launchd = try #require(terminator.target(pid: 1))
    #expect(launchd.uid == 0)

    #expect(throws: ProcessTerminationError.notOwned) {
      try terminator.terminate([launchd], mode: .quit)
    }
  }

  // MARK: - ProcessViewModel

  @MainActor @Test func quitIsOnlyAvailableForOwnUnprotectedProcesses() {
    let vm = ProcessViewModel(currentUser: "alice")
    let own = ProcessSnapshot(user: "alice", pid: 100, rssBytes: 300, command: "/bin/a")
    let other = ProcessSnapshot(user: "bob", pid: 101, rssBytes: 200, command: "/bin/b")
    let login = ProcessSnapshot(
      user: "alice", pid: 102, rssBytes: 100,
      command: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow")
    vm.apply(snapshots: [own, other, login])

    #expect(vm.quitAvailability(for: own) == .available)
    #expect(vm.quitAvailability(for: other) == .otherUser)
    #expect(vm.quitAvailability(for: login) == .protected)
  }

  @MainActor @Test func appQuitOnlyTargetsOwnProcesses() throws {
    let shared = AppIdentity(id: "app:/A.app", name: "A", path: "/A.app")
    let others = AppIdentity(id: "app:/B.app", name: "B", path: "/B.app")
    let vm = ProcessViewModel(currentUser: "alice")
    vm.apply(
      snapshots: [
        ProcessSnapshot(user: "alice", pid: 100, rssBytes: 500, command: "A"),
        ProcessSnapshot(user: "bob", pid: 101, rssBytes: 400, command: "A"),
        ProcessSnapshot(user: "alice", pid: 102, rssBytes: 300, command: "A Helper"),
        ProcessSnapshot(user: "bob", pid: 103, rssBytes: 200, command: "B"),
      ],
      appIdentities: [100: shared, 101: shared, 102: shared, 103: others]
    )

    let appA = try #require(vm.visibleApps.first { $0.name == "A" })
    let appB = try #require(vm.visibleApps.first { $0.name == "B" })
    #expect(vm.quitPIDs(for: appA) == [100, 102])
    #expect(vm.quitAvailability(for: appA) == .available)
    #expect(vm.hasOtherUsersProcesses(appA))
    #expect(vm.quitPIDs(for: appB).isEmpty)
    #expect(vm.quitAvailability(for: appB) == .otherUser)
  }

  // MARK: - MemStatsAppState

  @MainActor @Test func quitWaitsForConfirmation() {
    let terminator = StubProcessTerminator()
    terminator.targetsByPID[100] = Self.target(pid: 100)
    let appState = Self.makeAppState(terminator: terminator, suiteName: "MemStatsTests.QuitConfirm")
    let process = ProcessSnapshot(user: "alice", pid: 100, rssBytes: 500, command: "/bin/a")
    appState.applySample(stats: nil, processes: [process])

    appState.requestQuit(process: process, mode: .forceQuit)

    #expect(terminator.terminatedTargets.isEmpty)
    #expect(appState.pendingQuit?.section == .topProcesses)
    #expect(appState.pendingQuit?.pid == 100)
    #expect(appState.pendingQuit?.mode == .forceQuit)

    appState.confirmQuit()

    #expect(appState.pendingQuit == nil)
    #expect(terminator.terminatedTargets == [[Self.target(pid: 100)]])
    #expect(terminator.terminatedModes == [.forceQuit])
    #expect(appState.quitFailure == nil)
  }

  @MainActor @Test func cancelledQuitSignalsNothing() {
    let terminator = StubProcessTerminator()
    terminator.targetsByPID[100] = Self.target(pid: 100)
    let appState = Self.makeAppState(terminator: terminator, suiteName: "MemStatsTests.QuitCancel")
    let process = ProcessSnapshot(user: "alice", pid: 100, rssBytes: 500, command: "/bin/a")
    appState.applySample(stats: nil, processes: [process])

    appState.requestQuit(process: process, mode: .quit)
    appState.cancelQuit()
    appState.confirmQuit()

    #expect(appState.pendingQuit == nil)
    #expect(terminator.terminatedTargets.isEmpty)
  }

  @MainActor @Test func quitIgnoresOtherUsersProcesses() {
    let terminator = StubProcessTerminator()
    terminator.targetsByPID[101] = Self.target(pid: 101)
    let appState = Self.makeAppState(terminator: terminator, suiteName: "MemStatsTests.QuitOther")
    let process = ProcessSnapshot(user: "bob", pid: 101, rssBytes: 500, command: "/bin/b")
    appState.applySample(stats: nil, processes: [process])

    appState.requestQuit(process: process, mode: .quit)

    #expect(appState.pendingQuit == nil)
    #expect(appState.quitFailure == nil)
  }

  @MainActor @Test func quitRejectsProcessStartedAfterSnapshot() {
    let terminator = StubProcessTerminator()
    terminator.targetsByPID[100] = Self.target(
      pid: 100, startedAt: Date().addingTimeInterval(3_600))
    let appState = Self.makeAppState(terminator: terminator, suiteName: "MemStatsTests.QuitReused")
    let process = ProcessSnapshot(user: "alice", pid: 100, rssBytes: 500, command: "/bin/a")
    appState.applySample(stats: nil, processes: [process])

    appState.requestQuit(process: process, mode: .quit)

    #expect(appState.pendingQuit == nil)
    #expect(
      appState.quitFailure
        == MemStatsAppState.QuitFailure(section: .topProcesses, error: .processChanged))
  }

  @MainActor @Test func quitFailureIsShownInItsSection() throws {
    let terminator = StubProcessTerminator()
    terminator.targetsByPID[100] = Self.target(pid: 100)
    terminator.error = .notRunning
    let app = AppIdentity(id: "app:/A.app", name: "A", path: "/A.app")
    let appState = Self.makeAppState(terminator: terminator, suiteName: "MemStatsTests.QuitFail")
    appState.applySample(
      stats: nil,
      processes: [ProcessSnapshot(user: "alice", pid: 100, rssBytes: 500, command: "A")],
      appIdentities: [100: app]
    )
    let usage = try #require(appState.processVM.visibleApps.first)

    appState.requestQuit(app: usage, mode: .quit)
    #expect(appState.pendingQuit?.section == .topApps)
    #expect(appState.pendingQuit?.skipsOtherUsers == false)
    appState.confirmQuit()

    #expect(
      appState.quitFailure
        == MemStatsAppState.QuitFailure(section: .topApps, error: .notRunning))
    appState.dismissQuitFailure()
    #expect(appState.quitFailure == nil)
  }

  @MainActor @Test func appQuitKeepsOnlyProcessesFromTheSnapshot() throws {
    let terminator = StubProcessTerminator()
    terminator.targetsByPID[100] = Self.target(pid: 100)
    // 101 exited, 102 is a reused PID that started after the snapshot.
    terminator.targetsByPID[102] = Self.target(pid: 102, startedAt: Date().addingTimeInterval(60))
    terminator.targetsByPID[103] = Self.target(pid: 103)
    let app = AppIdentity(id: "app:/A.app", name: "A", path: "/A.app")
    let appState = Self.makeAppState(terminator: terminator, suiteName: "MemStatsTests.QuitApp")
    appState.applySample(
      stats: nil,
      processes: [
        ProcessSnapshot(user: "alice", pid: 100, rssBytes: 500, command: "A"),
        ProcessSnapshot(user: "alice", pid: 101, rssBytes: 400, command: "A Helper"),
        ProcessSnapshot(user: "alice", pid: 102, rssBytes: 300, command: "A Helper"),
        ProcessSnapshot(user: "bob", pid: 103, rssBytes: 200, command: "A"),
      ],
      appIdentities: [100: app, 101: app, 102: app, 103: app]
    )
    let usage = try #require(appState.processVM.visibleApps.first)

    appState.requestQuit(app: usage, mode: .forceQuit)

    #expect(appState.pendingQuit?.targets == [Self.target(pid: 100)])
    #expect(appState.pendingQuit?.skipsOtherUsers == true)
    #expect(appState.pendingQuit?.pid == nil)
    #expect(appState.quitFailure == nil)
  }

  @MainActor @Test func pendingQuitIsDroppedWhenProcessExitsOrPopoverCloses() {
    let terminator = StubProcessTerminator()
    terminator.targetsByPID[100] = Self.target(pid: 100)
    let process = ProcessSnapshot(user: "alice", pid: 100, rssBytes: 500, command: "/bin/a")
    let other = ProcessSnapshot(user: "alice", pid: 200, rssBytes: 400, command: "/bin/c")
    let appState = Self.makeAppState(
      terminator: terminator, suiteName: "MemStatsTests.QuitDrop", processes: [process, other])
    appState.applySample(stats: nil, processes: [process, other])

    appState.requestQuit(process: process, mode: .quit)
    appState.applySample(stats: nil, processes: [process, other])
    #expect(appState.pendingQuit != nil)

    appState.applySample(stats: nil, processes: [other])
    #expect(appState.pendingQuit == nil)

    appState.applySample(stats: nil, processes: [process, other])
    appState.setPopoverPresented(true)
    appState.requestQuit(process: process, mode: .quit)
    #expect(appState.pendingQuit != nil)
    appState.setPopoverPresented(false)
    #expect(appState.pendingQuit == nil)
  }
}
