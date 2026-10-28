import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI
import Testing

@testable import MemStats

struct MemStatsTests {
  private struct StubMemoryStatsProvider: MemoryStatsProviding {
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

  /// Blocks the first fetch until `releaseFirstFetch()`, so a test can request samples while
  /// one is still running.
  private final class GatedProcessProvider: ProcessSnapshotProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    // Guarded by `lock`.
    nonisolated(unsafe) private var calls = 0

    nonisolated var fetchCount: Int {
      lock.withLock { calls }
    }

    nonisolated func releaseFirstFetch() {
      gate.signal()
    }

    nonisolated func fetchProcesses(includeRootUser: Bool, includeSystemUsers: Bool) throws
      -> [ProcessSnapshot]
    {
      let call = lock.withLock {
        calls += 1
        return calls
      }
      if call == 1 {
        gate.wait()
      }
      return [ProcessSnapshot(user: "alice", pid: 1, rssBytes: 500, command: "/a")]
    }

    nonisolated func fetchTopProcesses(
      limit: Int,
      includeRootUser: Bool,
      includeSystemUsers: Bool
    ) throws -> [ProcessSnapshot] {
      try fetchProcesses(includeRootUser: includeRootUser, includeSystemUsers: includeSystemUsers)
    }
  }

  private struct FailingMemoryStatsProvider: MemoryStatsProviding {
    nonisolated func fetchMemoryStats() throws -> MemoryStats {
      throw CocoaError(.featureUnsupported)
    }
  }

  private struct FailingProcessProvider: ProcessSnapshotProviding {
    nonisolated func fetchProcesses(includeRootUser: Bool, includeSystemUsers: Bool) throws
      -> [ProcessSnapshot]
    {
      throw CocoaError(.featureUnsupported)
    }

    nonisolated func fetchTopProcesses(
      limit: Int,
      includeRootUser: Bool,
      includeSystemUsers: Bool
    ) throws -> [ProcessSnapshot] {
      throw CocoaError(.featureUnsupported)
    }
  }

  private final class TopCommandRunnerSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let resultForCall: (Int) throws -> String
    private var recordedLimits: [Int] = []

    init(resultForCall: @escaping (Int) throws -> String) {
      self.resultForCall = resultForCall
    }

    var limits: [Int] {
      lock.withLock { recordedLimits }
    }

    nonisolated func run(processLimit: Int, timeout _: DispatchTimeInterval) throws -> String {
      let call = lock.withLock {
        recordedLimits.append(processLimit)
        return recordedLimits.count
      }
      return try resultForCall(call)
    }
  }

  private final class MockLoginItemRegistrant: LoginItemRegistrant {
    var status: SMAppService.Status
    var statusAfterRegister: SMAppService.Status
    var didRegister = false
    var didUnregister = false

    init(
      status: SMAppService.Status = .notRegistered,
      statusAfterRegister: SMAppService.Status = .enabled
    ) {
      self.status = status
      self.statusAfterRegister = statusAfterRegister
    }

    func register() throws {
      didRegister = true
      status = statusAfterRegister
    }

    func unregister() throws {
      didUnregister = true
      status = .notRegistered
    }
  }

  @Test func donutBuilderMergesTinyUsersAndKeepsFreeLast() {
    let snapshots = [
      ProcessSnapshot(user: "alice", pid: 1, rssBytes: 500, command: "/a"),
      ProcessSnapshot(user: "bob", pid: 2, rssBytes: 30, command: "/b"),
      ProcessSnapshot(user: "carol", pid: 3, rssBytes: 10, command: "/c"),
    ]

    let slices = DonutDataBuilder.buildSlices(
      totalBytes: 1_000,
      freeBytes: 400,
      snapshots: snapshots,
      tinyThreshold: 0.05
    )

    #expect(slices.count == 4)
    #expect(slices[0].label == "alice")
    #expect(slices[1].label == "Others")
    #expect(slices[2].label == "Unattributed Used")
    #expect(slices[2].bytes == 60)
    #expect(slices[3].label == "Free")
    #expect(slices[3].bytes == 400)
  }

  @Test func donutBuilderNormalizesUserBytesWhenMeasuredExceedsUsed() {
    let snapshots = [
      ProcessSnapshot(user: "alice", pid: 1, rssBytes: 800, command: "/a"),
      ProcessSnapshot(user: "bob", pid: 2, rssBytes: 600, command: "/b"),
    ]

    let slices = DonutDataBuilder.buildSlices(
      totalBytes: 1_000,
      freeBytes: 600,
      snapshots: snapshots
    )

    let totalSliceBytes = slices.reduce(UInt64(0)) { $0 + $1.bytes }
    let hasUnattributed = slices.contains { $0.label == "Unattributed Used" }

    #expect(totalSliceBytes == 1_000)
    #expect(hasUnattributed == false)
  }

  @Test func donutSelectionPicksExpectedSlice() {
    let slices = [
      DonutSlice(id: "a", label: "A", category: .user("a"), bytes: 300, fractionOfTotal: 0.3),
      DonutSlice(id: "b", label: "B", category: .user("b"), bytes: 200, fractionOfTotal: 0.2),
      DonutSlice(id: "f", label: "Free", category: .free, bytes: 500, fractionOfTotal: 0.5),
    ]

    let picked = DonutDataBuilder.sliceForSelection(angleValue: 450, in: slices)

    #expect(picked?.label == "B")
  }

  @MainActor @Test func memoryViewModelKeepsBoundedHistory() {
    let vm = MemoryViewModel(maxSamples: 3)
    let baseStats = MemoryStats(
      totalBytes: 1000,
      usedBytes: 500,
      freeBytes: 500,
      activeBytes: 100,
      inactiveBytes: 100,
      wiredBytes: 100,
      compressedBytes: 100,
      swapUsedBytes: 100,
      pressureLevel: .normal
    )

    vm.apply(stats: baseStats, sampledAt: Date(timeIntervalSince1970: 1))
    vm.apply(stats: baseStats, sampledAt: Date(timeIntervalSince1970: 2))
    vm.apply(stats: baseStats, sampledAt: Date(timeIntervalSince1970: 3))
    vm.apply(stats: baseStats, sampledAt: Date(timeIntervalSince1970: 4))

    #expect(vm.history.count == 3)
    #expect(vm.history[0].timestamp == Date(timeIntervalSince1970: 2))
    #expect(vm.history[2].timestamp == Date(timeIntervalSince1970: 4))
  }

  @MainActor @Test func memoryViewModelMakesTimestampsMonotonic() {
    let vm = MemoryViewModel(maxSamples: 3)
    let baseStats = MemoryStats(
      totalBytes: 1000,
      usedBytes: 500,
      freeBytes: 500,
      activeBytes: 100,
      inactiveBytes: 100,
      wiredBytes: 100,
      compressedBytes: 100,
      swapUsedBytes: 100,
      pressureLevel: .normal
    )

    let sampleTime = Date(timeIntervalSince1970: 1)
    vm.apply(stats: baseStats, sampledAt: sampleTime)
    vm.apply(stats: baseStats, sampledAt: sampleTime)

    #expect(vm.history.count == 2)
    #expect(vm.history[1].timestamp > vm.history[0].timestamp)
  }

  @MainActor @Test func processViewModelResetsMissingSelectedUser() {
    let vm = ProcessViewModel()
    vm.selectedUser = "alice"

    vm.apply(
      snapshots: [
        ProcessSnapshot(user: "bob", pid: 1, rssBytes: 1024, command: "/bin/test")
      ]
    )

    #expect(vm.selectedUser == nil)
  }

  @MainActor @Test func processViewModelFiltersBySelectedUser() {
    let vm = ProcessViewModel()
    vm.apply(
      snapshots: [
        ProcessSnapshot(user: "alice", pid: 1, rssBytes: 1024, command: "/bin/a"),
        ProcessSnapshot(user: "bob", pid: 2, rssBytes: 2048, command: "/bin/b"),
      ]
    )

    vm.selectedUser = "alice"

    #expect(vm.visibleProcesses.count == 1)
    #expect(vm.visibleProcesses.first?.user == "alice")
  }

  @MainActor @Test func processViewModelSelectedUserUsesTopLimitFromAllProcesses() {
    let vm = ProcessViewModel(topProcessesLimit: 2)
    vm.apply(
      snapshots: [
        ProcessSnapshot(user: "bob", pid: 1, rssBytes: 900, command: "/bin/b1"),
        ProcessSnapshot(user: "alice", pid: 2, rssBytes: 800, command: "/bin/a1"),
        ProcessSnapshot(user: "alice", pid: 3, rssBytes: 700, command: "/bin/a2"),
        ProcessSnapshot(user: "alice", pid: 4, rssBytes: 600, command: "/bin/a3"),
      ]
    )

    vm.selectedUser = "alice"

    #expect(vm.topProcesses.count == 2)
    #expect(vm.visibleProcesses.count == 2)
    #expect(vm.visibleProcesses[0].pid == 2)
    #expect(vm.visibleProcesses[1].pid == 3)
  }

  @MainActor @Test func processViewModelTracksSelectedUserHistoryWithBounds() {
    let vm = ProcessViewModel(maxSamples: 2)

    vm.apply(
      snapshots: [
        ProcessSnapshot(user: "alice", pid: 1, rssBytes: 100, command: "/bin/a")
      ],
      sampledAt: Date(timeIntervalSince1970: 1)
    )
    vm.apply(
      snapshots: [
        ProcessSnapshot(user: "alice", pid: 1, rssBytes: 200, command: "/bin/a")
      ],
      sampledAt: Date(timeIntervalSince1970: 2)
    )
    vm.apply(
      snapshots: [
        ProcessSnapshot(user: "alice", pid: 1, rssBytes: 300, command: "/bin/a")
      ],
      sampledAt: Date(timeIntervalSince1970: 3)
    )

    vm.selectedUser = "alice"

    #expect(vm.selectedUserHistory.count == 2)
    #expect(vm.selectedUserHistory[0].timestamp == Date(timeIntervalSince1970: 2))
    #expect(vm.selectedUserHistory[1].rssBytes == 300)
  }

  @MainActor @Test func processViewModelMakesUserHistoryTimestampsMonotonic() {
    let vm = ProcessViewModel(maxSamples: 3)
    let snapshots = [
      ProcessSnapshot(user: "alice", pid: 1, rssBytes: 100, command: "/bin/a")
    ]
    let sampleTime = Date(timeIntervalSince1970: 1)

    vm.apply(snapshots: snapshots, sampledAt: sampleTime)
    vm.apply(snapshots: snapshots, sampledAt: sampleTime)
    vm.selectedUser = "alice"

    #expect(vm.selectedUserHistory.count == 2)
    #expect(vm.selectedUserHistory[1].timestamp > vm.selectedUserHistory[0].timestamp)
  }

  @MainActor @Test func processViewModelScalesUserHistoryToUsedRAMForDisplay() {
    let vm = ProcessViewModel(maxSamples: 3)
    // Summed RSS (400) is double the used RAM (200), so display bytes are halved.
    vm.apply(
      snapshots: [
        ProcessSnapshot(user: "alice", pid: 1, rssBytes: 300, command: "/bin/a"),
        ProcessSnapshot(user: "bob", pid: 2, rssBytes: 100, command: "/bin/b"),
      ],
      targetUsedBytes: 200,
      sampledAt: Date(timeIntervalSince1970: 1)
    )
    vm.selectedUser = "alice"

    #expect(vm.selectedUserHistory.last?.rssBytes == 300)
    #expect(vm.selectedUserHistory.last?.displayBytes == 150)
    #expect(vm.history(for: "bob").last?.displayBytes == 50)
  }

  @MainActor @Test func processViewModelCapsTopProcessesToLimit() {
    let vm = ProcessViewModel()
    let snapshots = (1...30).map { index in
      ProcessSnapshot(
        user: "u\(index)",
        pid: Int32(index),
        rssBytes: UInt64((31 - index) * 100),
        command: "/bin/\(index)"
      )
    }

    vm.apply(snapshots: snapshots)

    #expect(vm.allProcesses.count == 30)
    #expect(vm.topProcesses.count == 8)
    #expect(vm.topProcesses.first?.pid == 1)
    #expect(vm.topProcesses.last?.pid == 8)
  }

  @MainActor @Test func processViewModelApplyEmptySnapshotsClearsVisibleState() {
    let vm = ProcessViewModel()
    vm.apply(
      snapshots: [
        ProcessSnapshot(user: "alice", pid: 1, rssBytes: 1024, command: "/bin/a")
      ]
    )
    vm.selectedUser = "alice"

    vm.apply(snapshots: [])

    #expect(vm.allProcesses.isEmpty)
    #expect(vm.topProcesses.isEmpty)
    #expect(vm.visibleProcesses.isEmpty)
    #expect(vm.selectedUser == nil)
  }

  @Test func parseTopOutputSortsByMemoryDescending() {
    let output = """
      100 son 400M /usr/bin/vim
      1 root 900M /sbin/launchd
      44 son 650M /Applications/Xcode.app
      """

    let snapshots = TopProcessSnapshotParser.parse(
      topOutput: output,
      limit: 8,
      includeRootUser: false
    )

    #expect(snapshots.count == 2)
    #expect(snapshots[0].pid == 44)
    #expect(snapshots[1].pid == 100)
  }

  @Test func parseTopOutputFiltersUnderscoreUsersAndCanIncludeRoot() {
    let output = """
      10 _windowserver 500M /System/Library/windowserver
      1 root 900M /sbin/launchd
      44 son 650M /Applications/Xcode.app
      """

    let defaultFiltered = TopProcessSnapshotParser.parse(
      topOutput: output,
      limit: 8,
      includeRootUser: false,
      includeSystemUsers: false
    )
    #expect(defaultFiltered.count == 1)
    #expect(defaultFiltered[0].user == "son")

    let withRoot = TopProcessSnapshotParser.parse(
      topOutput: output,
      limit: 8,
      includeRootUser: true,
      includeSystemUsers: false
    )
    #expect(withRoot.count == 2)
    #expect(withRoot[0].user == "root")
    #expect(withRoot[1].user == "son")
  }

  @Test func parseTopOutputDefaultsToAllUsersIncludingSystemAndRoot() {
    let output = """
      10 _windowserver 500M /System/Library/windowserver
      1 root 900M /sbin/launchd
      44 son 650M /Applications/Xcode.app
      """

    let snapshots = TopProcessSnapshotParser.parse(topOutput: output, limit: 8)
    #expect(snapshots.count == 3)
    #expect(snapshots[0].user == "root")
    #expect(snapshots[1].user == "son")
    #expect(snapshots[2].user == "_windowserver")
  }

  @Test func parseTopOutputCapsAtLimit() {
    let lines = (1...30).map { index in
      "\(index) u\(index) \(index)M /cmd/\(index)"
    }
    let output = lines.joined(separator: "\n")

    let snapshots = TopProcessSnapshotParser.parse(topOutput: output, limit: 8)

    #expect(snapshots.count == 8)
    #expect(snapshots.first?.pid == 30)
    #expect(snapshots.last?.pid == 23)
  }

  @Test func parseTopOutputReturnsAllWhenNoLimitProvided() {
    let output = """
      100 son 400M /usr/bin/vim
      44 son 650M /Applications/Xcode.app
      45 son 300M /Applications/Code.app
      """

    let snapshots = TopProcessSnapshotParser.parse(topOutput: output, limit: nil)

    #expect(snapshots.count == 3)
    #expect(snapshots.first?.pid == 44)
    #expect(snapshots.last?.pid == 45)
  }

  @Test func parseTopOutputKeepsFullCommandLineWhenUsingCommandField() {
    let output = """
      19538 son 2.88G lldb-rpc-server --stdio --foo bar
      53462 son 2.57G dart:dartdev_aot.dart.snapshot --packages=.dart_tool/package_config.json
      """

    let snapshots = TopProcessSnapshotParser.parse(topOutput: output, limit: nil)

    #expect(snapshots.count == 2)
    #expect(snapshots[0].pid == 19538)
    #expect(snapshots[0].command == "lldb-rpc-server --stdio --foo bar")
    #expect(snapshots[1].pid == 53462)
    #expect(
      snapshots[1].command
        == "dart:dartdev_aot.dart.snapshot --packages=.dart_tool/package_config.json"
    )
  }

  @Test func appIdentityGroupsHelperIntoOutermostAppBundle() {
    let main = AppIdentityResolver.identity(
      forExecutablePath: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"
    )
    let helper = AppIdentityResolver.identity(
      forExecutablePath:
        "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Renderer).app/Contents/MacOS/Code Helper (Renderer)"
    )

    #expect(main.id == helper.id)
    #expect(helper.name == "Visual Studio Code")
    #expect(helper.path == "/Applications/Visual Studio Code.app")
  }

  @Test func appIdentityUsesExecutableNameOutsideAppBundle() {
    let identity = AppIdentityResolver.identity(forExecutablePath: "/usr/local/bin/mysqld")

    #expect(identity.id == "exec:/usr/local/bin/mysqld")
    #expect(identity.name == "mysqld")
  }

  @Test func appIdentityReadsLaunchPathFromArguments() {
    func arguments(_ strings: [String]) -> [UInt8] {
      withUnsafeBytes(of: Int32(1)) { Array($0) } + strings.flatMap { Array($0.utf8) + [0] }
    }

    #expect(
      AppIdentityResolver.launchPath(
        fromArguments: arguments(["/Applications/Edge.app/Contents/MacOS/Edge", "", "Edge"]))
        == "/Applications/Edge.app/Contents/MacOS/Edge")
    #expect(AppIdentityResolver.launchPath(fromArguments: arguments(["bin/tool", "tool"])) == nil)
    #expect(AppIdentityResolver.launchPath(fromArguments: arguments(["", "tool"])) == nil)
    #expect(AppIdentityResolver.launchPath(fromArguments: [1, 0]) == nil)
  }

  @Test func appIdentityReadsLaunchPathOfRunningProcess() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    defer { process.terminate() }

    #expect(AppIdentityResolver.launchPath(for: process.processIdentifier) == "/bin/sleep")
    // Another user's arguments are not readable.
    #expect(AppIdentityResolver.launchPath(for: 1) == nil)
  }

  @Test func appAggregatorSumsMemoryAndSortsDescending() {
    let code = AppIdentity(id: "app:/Code.app", name: "Code", path: "/Code.app")
    let edge = AppIdentity(id: "app:/Edge.app", name: "Edge", path: "/Edge.app")
    let processes = [
      ProcessSnapshot(user: "son", pid: 1, rssBytes: 300, command: "Code"),
      ProcessSnapshot(user: "son", pid: 2, rssBytes: 400, command: "Code Helper"),
      ProcessSnapshot(user: "son", pid: 3, rssBytes: 500, command: "Microsoft Edge"),
      ProcessSnapshot(user: "son", pid: 4, rssBytes: 50, command: "unknownd"),
    ]

    let apps = AppMemoryAggregator.aggregate(
      processes: processes,
      identities: [1: code, 2: code, 3: edge]
    )

    #expect(apps.count == 3)
    #expect(apps[0].name == "Code")
    #expect(apps[0].bytes == 700)
    #expect(apps[0].processCount == 2)
    #expect(apps[0].pids == [1, 2])
    #expect(apps[1].name == "Edge")
    #expect(apps[2].name == "unknownd")
    #expect(apps[2].path == nil)
  }

  @MainActor @Test func processViewModelScopesAppsToSelectedUser() {
    let app = AppIdentity(id: "app:/A.app", name: "A", path: "/A.app")
    let vm = ProcessViewModel()
    vm.apply(
      snapshots: [
        ProcessSnapshot(user: "bob", pid: 1, rssBytes: 900, command: "A"),
        ProcessSnapshot(user: "alice", pid: 2, rssBytes: 100, command: "A"),
      ],
      appIdentities: [1: app, 2: app]
    )

    #expect(vm.visibleApps.first?.bytes == 1_000)

    vm.selectedUser = "alice"

    #expect(vm.visibleApps.count == 1)
    #expect(vm.visibleApps.first?.bytes == 100)
    #expect(vm.visibleApps.first?.processCount == 1)
  }

  @Test func treemapLayoutFillsTheRectInProportion() {
    let bounds = CGRect(x: 0, y: 0, width: 300, height: 150)
    let values: [Double] = [600, 300, 200, 100, 50, 0]
    let rects = TreemapLayout.layout(values: values, in: bounds)

    #expect(rects.count == values.count)
    let totalArea = rects.reduce(0) { $0 + Double($1.width * $1.height) }
    #expect(abs(totalArea - 300 * 150) < 0.01)
    for (rect, value) in zip(rects, values) {
      #expect(bounds.insetBy(dx: -0.001, dy: -0.001).contains(rect))
      #expect(abs(Double(rect.width * rect.height) - value / 1_250 * 45_000) < 0.01)
    }
    #expect(rects.last == .zero)
    #expect(TreemapLayout.layout(values: [], in: bounds).isEmpty)
    #expect(TreemapLayout.layout(values: [1, 2], in: .zero) == [.zero, .zero])
    #expect(TreemapLayout.layout(values: [5], in: bounds) == [bounds])

    // Input order does not matter: a zero in the middle must not drop later tiles.
    let unsorted = TreemapLayout.layout(values: [100, 0, 300], in: bounds)
    #expect(unsorted[1] == .zero)
    #expect(abs(Double(unsorted[0].width * unsorted[0].height) - 11_250) < 0.01)
    #expect(abs(Double(unsorted[2].width * unsorted[2].height) - 33_750) < 0.01)
  }

  @Test func treemapToneAndChangeText() {
    func item(_ change: Double?) -> TreemapItem {
      TreemapItem(id: "a", name: "A", bytes: 1, details: [], change: change)
    }
    #expect(item(nil).tone == 0)
    #expect(item(0.004).tone == 0)
    #expect(item(0.01).tone == 1)
    #expect(item(0.03).tone == 2)
    #expect(item(0.5).tone == 3)
    #expect(item(-0.01).tone == -1)
    #expect(item(-0.5).tone == -3)

    // Small tiles drop the least important line first and keep the display order.
    let details = [
      TreemapDetail(text: "PID 1", priority: 1),
      TreemapDetail(text: "1 GB", priority: 0),
      TreemapDetail(text: "alice", priority: 2),
    ]
    let tile = TreemapItem(id: "a", name: "A", bytes: 1, details: details, change: nil)
    #expect(tile.visibleDetails(lineCount: 3).map(\.text) == ["PID 1", "1 GB", "alice"])
    #expect(tile.visibleDetails(lineCount: 2).map(\.text) == ["PID 1", "1 GB"])
    #expect(tile.visibleDetails(lineCount: 1).map(\.text) == ["1 GB"])
    #expect(tile.visibleDetails(lineCount: 0).isEmpty)
  }

  @MainActor @Test func processViewModelResolvesIconPathFromAppIdentity() {
    let app = AppIdentity(id: "app:/A.app", name: "A", path: "/A.app")
    let vm = ProcessViewModel()
    let known = ProcessSnapshot(user: "bob", pid: 1, rssBytes: 10, command: "A")
    let unknown = ProcessSnapshot(user: "bob", pid: 2, rssBytes: 10, command: "B")
    vm.apply(snapshots: [known, unknown], appIdentities: [1: app])

    #expect(vm.iconPath(for: known) == "/A.app")
    #expect(vm.iconPath(for: unknown) == nil)
  }

  @MainActor @Test func processViewModelReportsChangeSincePreviousSample() {
    let app = AppIdentity(id: "app:/A.app", name: "A", path: "/A.app")
    let vm = ProcessViewModel()
    func snapshots(_ bob: UInt64, _ alice: UInt64) -> [ProcessSnapshot] {
      [
        ProcessSnapshot(user: "bob", pid: 1, rssBytes: bob, command: "A"),
        ProcessSnapshot(user: "alice", pid: 2, rssBytes: alice, command: "A"),
      ]
    }

    vm.apply(snapshots: snapshots(900, 100), appIdentities: [1: app, 2: app])
    // No earlier sample yet.
    #expect(vm.change(for: vm.visibleProcesses[0]) == nil)
    #expect(vm.change(for: vm.visibleApps[0]) == nil)

    vm.apply(snapshots: snapshots(990, 100), appIdentities: [1: app, 2: app])
    #expect(abs((vm.change(for: vm.visibleProcesses[0]) ?? 0) - 0.1) < 1e-9)
    #expect(abs((vm.change(for: vm.visibleApps[0]) ?? 0) - 0.09) < 1e-9)

    // Filtered apps compare against the same user's earlier bytes (100 -> 100).
    vm.selectedUser = "alice"
    #expect(abs(vm.change(for: vm.visibleApps[0]) ?? 1) < 1e-9)

    // A process without an earlier reading has no change.
    vm.apply(
      snapshots: snapshots(990, 100) + [
        ProcessSnapshot(user: "bob", pid: 3, rssBytes: 50, command: "B")
      ],
      appIdentities: [1: app, 2: app])
    vm.selectedUser = nil
    #expect(vm.visibleProcesses.first { $0.pid == 3 }.flatMap { vm.change(for: $0) } == nil)
  }

  @Test func memoryStatsServiceReturnsPositiveTotals() throws {
    let service = MemoryStatsService()
    let stats = try service.fetchMemoryStats()

    #expect(stats.totalBytes > 0)
    #expect(stats.usedBytes <= stats.totalBytes)
    #expect(stats.freeBytes <= stats.totalBytes)
    #expect(stats.usedBytes + stats.freeBytes == stats.totalBytes)
  }

  @Test func donutPaletteIndexIsStableAndInRange() {
    // FNV-1a("alice") = 0x508b2abb65a03907, so the index never changes between launches.
    #expect(DonutDataBuilder.paletteIndex(for: "alice", paletteCount: 8) == 7)
    #expect(DonutDataBuilder.paletteIndex(for: "", paletteCount: 8) < 8)
    #expect(DonutDataBuilder.paletteIndex(for: "root", paletteCount: 0) == 0)
  }

  @Test func historySegmentsPairAdjacentSamplesAndUseEndPressure() {
    let start = Date(timeIntervalSince1970: 1_000)
    let samples = [
      MemoryHistorySample(
        timestamp: start, usedBytes: 10, swapUsedBytes: 0, pressureLevel: .normal),
      MemoryHistorySample(
        timestamp: start.addingTimeInterval(5), usedBytes: 20, swapUsedBytes: 0,
        pressureLevel: .warning),
      MemoryHistorySample(
        timestamp: start.addingTimeInterval(10), usedBytes: 15, swapUsedBytes: 0,
        pressureLevel: .normal),
    ]

    let points = MemoryHistorySegmentPoint.segments(from: samples)

    #expect(points.count == 4)
    #expect(Set(points.map(\.segmentID)).count == 2)
    #expect(Set(points.map(\.id)).count == 4)
    #expect(points.map(\.usedBytes) == [10, 20, 20, 15])
    #expect(points.map(\.pressureLevel) == [.warning, .warning, .normal, .normal])
    #expect(MemoryHistorySegmentPoint.segments(from: Array(samples.prefix(1))).isEmpty)
  }

  @Test func usedMemoryCountsAppWiredAndCompressedPages() {
    let used = MemoryStatsService.usedMemoryBytes(
      internalPages: 100,
      purgeablePages: 20,
      wiredPages: 30,
      compressedPages: 10,
      pageSize: 4,
      totalBytes: 10_000
    )
    #expect(used == (80 + 30 + 10) * 4)
  }

  @Test func usedMemoryClampsPurgeableAndTotal() {
    let noAppMemory = MemoryStatsService.usedMemoryBytes(
      internalPages: 10,
      purgeablePages: 50,
      wiredPages: 5,
      compressedPages: 0,
      pageSize: 1,
      totalBytes: 100
    )
    #expect(noAppMemory == 5)

    let capped = MemoryStatsService.usedMemoryBytes(
      internalPages: 1_000,
      purgeablePages: 0,
      wiredPages: 0,
      compressedPages: 0,
      pageSize: 1,
      totalBytes: 100
    )
    #expect(capped == 100)
  }

  @Test func memorystatusPressureMappingUsesExpectedBands() {
    #expect(MemoryStatsService.levelFromMemorystatusPressure(1) == .normal)
    #expect(MemoryStatsService.levelFromMemorystatusPressure(2) == .warning)
    #expect(MemoryStatsService.levelFromMemorystatusPressure(4) == .critical)
  }

  @Test func effectiveIntervalUsesSettingWhenActiveAndAtLeast15sForMemoryWhenIdle() {
    #expect(MemStatsAppState.effectiveInterval(setting: 5, mode: .active, kind: .memory) == 5)
    #expect(MemStatsAppState.effectiveInterval(setting: 1, mode: .active, kind: .memory) == 1)
    #expect(MemStatsAppState.effectiveInterval(setting: 5, mode: .idle, kind: .memory) == 15)
    #expect(MemStatsAppState.effectiveInterval(setting: 15, mode: .idle, kind: .memory) == 15)
    #expect(MemStatsAppState.effectiveInterval(setting: 30, mode: .idle, kind: .memory) == 30)
  }

  @Test func effectiveIntervalUsesSettingWhenActiveAndAtLeast60sForProcessesWhenIdle() {
    #expect(MemStatsAppState.effectiveInterval(setting: 3, mode: .active, kind: .process) == 3)
    #expect(MemStatsAppState.effectiveInterval(setting: 5, mode: .idle, kind: .process) == 60)
    #expect(MemStatsAppState.effectiveInterval(setting: 30, mode: .idle, kind: .process) == 60)
    #expect(MemStatsAppState.effectiveInterval(setting: 60, mode: .idle, kind: .process) == 60)
  }

  @MainActor @Test func appStateStartsIdleWithSlowerProcessInterval() {
    let suiteName = "MemStatsTests.IdleIntervals"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let appState = MemStatsAppState(startSampling: false, defaults: defaults)
    #expect(appState.samplingMode == .idle)
    #expect(appState.memorySamplingInterval == 15)
    #expect(appState.processSamplingInterval == 60)
  }

  @Test func historyCapacityKeepsAboutTenMinutes() {
    #expect(MemStatsAppState.historyCapacity(interval: 5) == 120)
    #expect(MemStatsAppState.historyCapacity(interval: 1) == 600)
    #expect(MemStatsAppState.historyCapacity(interval: 3) == 200)
    #expect(MemStatsAppState.historyCapacity(interval: 60) == 10)
    #expect(MemStatsAppState.historyCapacity(interval: 0) == 600)
  }

  @Test func historyHeatmapFillsFromTheRightAndScalesLevelsToTheWindow() {
    func sample(_ used: UInt64, _ pressure: MemoryPressureLevel = .normal) -> MemoryHistorySample {
      MemoryHistorySample(
        timestamp: Date(), usedBytes: used, swapUsedBytes: 0, pressureLevel: pressure)
    }

    #expect(HistoryHeatmap.cells(from: [sample(1)], columns: 0).isEmpty)

    let cells = HistoryHeatmap.cells(
      from: [sample(100), sample(200, .warning), sample(300)], columns: 2)
    #expect(cells.count == 2 * HistoryHeatmap.rows)
    #expect(cells.prefix(11).allSatisfy { $0 == nil })
    #expect(cells[11]?.level == 1)
    #expect(cells[12]?.pressureLevel == .warning)
    #expect(cells[13]?.level == HistoryHeatmap.levelCount)

    // More samples than slots keeps the newest ones.
    let many = (0..<20).map { sample(UInt64($0)) }
    let trimmed = HistoryHeatmap.cells(from: many, columns: 2)
    #expect(trimmed.allSatisfy { $0 != nil })
    #expect(trimmed.last??.level == HistoryHeatmap.levelCount)

    // A flat window reads as one mid level.
    let flat = HistoryHeatmap.cells(from: [sample(5), sample(5)], columns: 1)
    #expect(flat[5]?.level == flat[6]?.level)
    #expect(HistoryHeatmapView.columnCount(for: 0) == 0)
    #expect(HistoryHeatmapView.columnCount(for: 328) == 23)
    #expect(HistoryChartStyle.line.toggled == .heatmap)
    #expect(TopListStyle.list.toggled == .treemap)
    #expect(HistoryHeatmapView.columnCount(for: 10) == 0)
    #expect(HistoryHeatmapView.columnCount(for: 11) == 1)
    #expect(HistoryHeatmapView.columnCount(for: 24) == 1)
    #expect(HistoryHeatmapView.columnCount(for: 25) == 2)

    // Bucket boundaries over 0...100.
    #expect(HistoryHeatmap.level(for: 0, low: 0, high: 100) == 1)
    #expect(HistoryHeatmap.level(for: 24, low: 0, high: 100) == 1)
    #expect(HistoryHeatmap.level(for: 25, low: 0, high: 100) == 2)
    #expect(HistoryHeatmap.level(for: 75, low: 0, high: 100) == 4)
    #expect(HistoryHeatmap.level(for: 100, low: 0, high: 100) == HistoryHeatmap.levelCount)

    // Pressure colors only replace green above normal.
    let normal = HistoryHeatmapCell(level: 2, pressureLevel: .normal)
    let critical = HistoryHeatmapCell(level: 2, pressureLevel: .critical)
    #expect(HistoryHeatmapView.color(for: normal) == HistoryHeatmapView.levelColor(2))
    #expect(HistoryHeatmapView.color(for: critical) != HistoryHeatmapView.levelColor(2))
  }

  @Test func settingsStoreFallsBackToLineForInvalidHistoryChartStyle() {
    let suiteName = "MemStatsTests.SettingsStore.ChartStyle"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set("bogus", forKey: SettingsStore.historyChartStyleKey)
    #expect(SettingsStore(defaults: defaults).historyChartStyle == .line)
  }

  @Test func settingsStoreUsesDefaultsPersistsAndRejectsInvalidValues() {
    let suiteName = "MemStatsTests.SettingsStore"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let store = SettingsStore(defaults: defaults)
    #expect(store.memoryInterval == 5)
    #expect(store.processInterval == 5)
    #expect(store.topAppsCount == 8)
    #expect(store.topProcessesCount == 8)
    #expect(store.theme == .system)
    #expect(store.language == .system)
    #expect(store.historyChartStyle == .line)
    #expect(store.topAppsStyle == .list)
    #expect(store.topProcessesStyle == .list)
    #expect(store.glassBackground == false)
    #expect(store.glassOpacity == SettingsStore.defaultGlassOpacity)

    store.memoryInterval = 2
    store.processInterval = 30
    store.topAppsCount = 15
    store.topProcessesCount = 20
    store.theme = .dark
    store.language = .vietnamese
    store.historyChartStyle = .heatmap
    store.topAppsStyle = .treemap
    store.glassBackground = true
    store.glassOpacity = 0.7
    let restored = SettingsStore(defaults: defaults)
    #expect(restored.memoryInterval == 2)
    #expect(restored.processInterval == 30)
    #expect(restored.topAppsCount == 15)
    #expect(restored.topProcessesCount == 20)
    #expect(restored.theme == .dark)
    #expect(restored.language == .vietnamese)
    #expect(restored.historyChartStyle == .heatmap)
    #expect(restored.topAppsStyle == .treemap)
    #expect(restored.topProcessesStyle == .list)
    #expect(restored.glassBackground == true)
    #expect(restored.glassOpacity == 0.7)

    restored.glassOpacity = 0.1
    #expect(restored.glassOpacity == 0.1)
    restored.glassOpacity = 0.9
    #expect(restored.glassOpacity == 0.9)

    // A value outside the options falls back to the default, both when set and when read.
    restored.processInterval = 1
    #expect(restored.processInterval == 5)
    #expect(defaults.integer(forKey: SettingsStore.processIntervalKey) == 5)

    defaults.set(7, forKey: SettingsStore.memoryIntervalKey)
    defaults.set("many", forKey: SettingsStore.topAppsCountKey)
    defaults.set(0, forKey: SettingsStore.topProcessesCountKey)
    defaults.set("invalid", forKey: SettingsStore.themeKey)
    defaults.set("invalid", forKey: SettingsStore.languageKey)
    defaults.set("invalid", forKey: SettingsStore.glassBackgroundKey)
    defaults.set("invalid", forKey: SettingsStore.glassOpacityKey)
    let invalid = SettingsStore(defaults: defaults)
    #expect(invalid.memoryInterval == 5)
    #expect(invalid.topAppsCount == 8)
    #expect(invalid.topProcessesCount == 8)
    #expect(invalid.theme == .system)
    #expect(invalid.language == .system)
    #expect(invalid.glassBackground == false)
    #expect(invalid.glassOpacity == SettingsStore.defaultGlassOpacity)
  }

  @Test func popoverSectionNormalizationKeepsEverySectionOnce() {
    #expect(PopoverSection.normalizedOrder([]) == PopoverSection.defaultOrder)
    #expect(
      PopoverSection.normalizedOrder(["topApps", "bogus", "topApps", "history"])
        == [.topApps, .history, .topUsers, .topProcesses])

    #expect(PopoverSection.normalizedHidden(["history", "bogus"]) == [.history])
    // Hiding every section would leave an empty popover.
    #expect(PopoverSection.normalizedHidden(PopoverSection.allCases.map(\.rawValue)).isEmpty)
  }

  @Test func settingsStoreMovesHidesAndResetsSections() {
    let suiteName = "MemStatsTests.SettingsStore.Sections.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = SettingsStore(defaults: defaults)
    #expect(store.sectionOrder == PopoverSection.defaultOrder)
    #expect(store.visibleSections == PopoverSection.defaultOrder)
    #expect(store.isDefaultSectionLayout)

    #expect(!store.canMoveSection(.topUsers, by: -1))
    #expect(!store.canMoveSection(.topProcesses, by: 1))
    store.moveSection(.topUsers, by: -1)
    #expect(store.sectionOrder == PopoverSection.defaultOrder)

    store.moveSection(.topProcesses, by: -1)
    store.moveSection(.topUsers, by: 1)
    #expect(store.sectionOrder == [.history, .topUsers, .topProcesses, .topApps])

    store.setSection(.history, visible: false)
    #expect(!store.isSectionVisible(.history))
    #expect(store.visibleSections == [.topUsers, .topProcesses, .topApps])

    let restored = SettingsStore(defaults: defaults)
    #expect(restored.sectionOrder == [.history, .topUsers, .topProcesses, .topApps])
    #expect(restored.hiddenSections == [.history])
    #expect(!restored.isDefaultSectionLayout)

    // The last shown section cannot be hidden.
    restored.setSection(.topUsers, visible: false)
    restored.setSection(.topProcesses, visible: false)
    restored.setSection(.topApps, visible: false)
    #expect(restored.visibleSections == [.topApps])
    restored.setSection(.topApps, visible: true)
    restored.setSection(.history, visible: true)
    #expect(restored.visibleSections == [.history, .topApps])

    restored.resetSectionLayout()
    #expect(restored.isDefaultSectionLayout)
    let reset = SettingsStore(defaults: defaults)
    #expect(reset.sectionOrder == PopoverSection.defaultOrder)
    #expect(reset.hiddenSections.isEmpty)
  }

  @MainActor @Test func hidingTopUsersClearsTheUserFilter() {
    let suiteName = "MemStatsTests.Sections.UserFilter.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let appState = MemStatsAppState(startSampling: false, defaults: defaults)
    appState.processVM.apply(snapshots: [
      ProcessSnapshot(user: "alice", pid: 1, rssBytes: 500, command: "/a")
    ])
    appState.processVM.selectedUser = "alice"

    appState.settings.setSection(.history, visible: false)
    #expect(appState.processVM.selectedUser == "alice")
    appState.settings.setSection(.topUsers, visible: false)
    #expect(appState.processVM.selectedUser == nil)
  }

  @Test func appThemeMapsToExpectedAppearanceOverrides() {
    #expect(AppTheme.system.nsAppearance == nil)
    #expect(AppTheme.light.nsAppearance?.name == .aqua)
    #expect(AppTheme.dark.nsAppearance?.name == .darkAqua)
    #expect(AppTheme.system.swiftUIColorScheme == nil)
    #expect(AppTheme.light.swiftUIColorScheme == .light)
    #expect(AppTheme.dark.swiftUIColorScheme == .dark)
  }

  @Test func glassBackgroundHonorsReduceTransparency() {
    #expect(
      GlassBackgroundResolver.shouldUseGlass(
        preferenceEnabled: false, reduceTransparency: false
      ) == false
    )
    #expect(
      GlassBackgroundResolver.shouldUseGlass(
        preferenceEnabled: true, reduceTransparency: false
      ) == true
    )
    #expect(
      GlassBackgroundResolver.shouldUseGlass(
        preferenceEnabled: true, reduceTransparency: true
      ) == false
    )
  }

  @MainActor @Test func glassToggleUsesLatestValuesAndPreservesOpacity() {
    let suiteName = "MemStatsTests.GlassToggle.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = SettingsStore(defaults: defaults)
    let background = GlassBackgroundContainerView(frame: .zero)
    let observation = GlassSettingsObservation.observe(settings) { isEnabled, opacity in
      background.preferenceEnabled = isEnabled
      background.glassOpacity = opacity
    }
    defer { observation.cancel() }

    settings.glassBackground = true
    #expect(background.preferenceEnabled)
    settings.glassOpacity = 0.7
    #expect(background.glassOpacity == 0.7)

    settings.glassBackground = false
    #expect(!background.preferenceEnabled)
    #expect(background.glassOpacity == 0.7)
    #expect(background.layer?.backgroundColor != nil)
    if let solidColor = background.layer?.backgroundColor {
      #expect(solidColor.alpha == 1)
    }

    settings.glassBackground = true
    #expect(background.preferenceEnabled)
    #expect(background.glassOpacity == 0.7)
  }

  @MainActor @Test func glassBackgroundFollowsWindowAppearance() {
    let background = GlassBackgroundContainerView(frame: .zero)
    background.preferenceEnabled = true
    background.glassOpacity = 1
    background.appearance = NSAppearance(named: .aqua)
    let lightColor = background.subviews.last?.layer?.backgroundColor.flatMap(
      NSColor.init(cgColor:))?
      .usingColorSpace(.deviceRGB)

    background.appearance = NSAppearance(named: .darkAqua)
    let darkColor = background.subviews.last?.layer?.backgroundColor.flatMap(
      NSColor.init(cgColor:))?
      .usingColorSpace(.deviceRGB)

    #expect(lightColor != nil)
    #expect(darkColor != nil)
    if let lightColor, let darkColor {
      #expect(lightColor.brightnessComponent > darkColor.brightnessComponent + 0.3)
    }

    background.preferenceEnabled = false
    let darkSolidColor = background.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?
      .usingColorSpace(.deviceRGB)
    background.appearance = NSAppearance(named: .aqua)
    let lightSolidColor = background.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?
      .usingColorSpace(.deviceRGB)
    #expect(lightSolidColor?.alphaComponent == 1)
    #expect(darkSolidColor?.alphaComponent == 1)
    if let lightSolidColor, let darkSolidColor {
      #expect(lightSolidColor.brightnessComponent > darkSolidColor.brightnessComponent + 0.3)
    }
  }

  @Test func glassTintIsLighterAtAnExistingSliderValue() {
    #expect(abs(GlassSurfaceStyle.effectiveOpacity(0.52) - 0.416) < 0.000_001)
    #expect(GlassSurfaceStyle.effectiveOpacity(0) == 0)
    #expect(GlassSurfaceStyle.effectiveOpacity(2) == 0.8)
  }

  @Test func glassMaterialRetainsMostOfTheNativeBlur() {
    #expect(GlassSurfaceStyle.materialAlpha == 1.0)
  }

  @Test func appLanguageUsesNativeNamesAndExpectedLocales() {
    #expect(AppLanguage.system.displayName == "System")
    #expect(AppLanguage.vietnamese.displayName == "Tiếng Việt")
    #expect(AppLanguage.simplifiedChinese.locale.identifier == "zh-Hans")
    #expect(AppLanguage.japanese.locale.identifier == "ja")
    #expect(AppLanguage.german.locale.identifier == "de")
    #expect(AppLanguage.allCases.count == 9)
  }

  @MainActor @Test func appLocalizationUsesTheChosenLanguage() {
    #expect(AppLocalization.string("%lld seconds", language: .vietnamese) == "%lld giây")
    #expect(AppLocalization.string("Heatmap", language: .french) == "Carte de chaleur")
    #expect(AppLocalization.formatted("%lld seconds", language: .german, Int64(5)) == "5 Sekunden")
    #expect(AppLocalization.string("Move Up", language: .english) == "Move Up")
    #expect(AppLocalization.string("not a key", language: .japanese) == "not a key")

    // Every translated language reads from its own strings, not the system language.
    for language in AppLanguage.allCases where language != .system && language != .english {
      #expect(AppLocalization.string("Move Up", language: language) != "Move Up")
    }
  }

  @Test func languageChangesPublishImmediately() {
    let suiteName = "MemStatsTests.SettingsStore.LanguagePublisher"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let store = SettingsStore(defaults: defaults)
    var publishedLanguage: AppLanguage?
    let cancellable = store.$language.dropFirst().sink { publishedLanguage = $0 }

    store.language = .german

    #expect(publishedLanguage == .german)
    withExtendedLifetime(cancellable) {}
    defaults.removePersistentDomain(forName: suiteName)
  }

  @MainActor @Test func processViewModelReportsFirstSample() {
    let vm = ProcessViewModel()
    #expect(!vm.hasSampled)

    // An empty snapshot still counts, so the lists move from "Loading…" to "No data".
    vm.apply(snapshots: [])
    #expect(vm.hasSampled)
  }

  @MainActor @Test func processViewModelUsesSeparateLimitsForAppsAndProcesses() {
    let vm = ProcessViewModel(topAppsLimit: 2, topProcessesLimit: 5)
    let snapshots = (1...10).map { index in
      ProcessSnapshot(
        user: "alice",
        pid: Int32(index),
        rssBytes: UInt64((11 - index) * 100),
        command: "/bin/tool\(index)"
      )
    }
    vm.apply(snapshots: snapshots)

    #expect(vm.topProcesses.count == 5)
    #expect(vm.visibleApps.count == 2)

    // Changing the row counts re-slices the current snapshot without a new sample.
    vm.setLimits(topApps: 8, topProcesses: 3)
    #expect(vm.topProcesses.map(\.pid) == [1, 2, 3])
    #expect(vm.visibleApps.count == 8)

    vm.selectedUser = "alice"
    #expect(vm.visibleProcesses.count == 3)
  }

  @MainActor @Test func appStateAppliesRowCountAndHistorySettings() {
    let suiteName = "MemStatsTests.AppStateSettings"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let appState = MemStatsAppState(startSampling: false, defaults: defaults)
    #expect(appState.memoryVM.maxSamples == 120)
    #expect(appState.processVM.topProcessesLimit == 8)

    appState.settings.memoryInterval = 1
    appState.settings.processInterval = 10
    appState.settings.topAppsCount = 5
    appState.settings.topProcessesCount = 15

    #expect(appState.memoryVM.maxSamples == 600)
    #expect(appState.processVM.maxSamples == 60)
    #expect(appState.processVM.topAppsLimit == 5)
    #expect(appState.processVM.topProcessesLimit == 15)
  }

  @Test func growthDetectorFlagsContinuousGrowth() {
    let mb: UInt64 = 1024 * 1024
    let total: UInt64 = 16 * 1024 * mb
    let growing = (0..<12).map { UInt64($0) * 20 * mb + 1_000 * mb }

    let hint = MemoryGrowthDetector.hint(user: "alice", history: growing, totalBytes: total)
    #expect(
      hint
        == MemoryGrowthHint(
          user: "alice", kind: .continuousGrowth(samples: 12), growthBytes: 220 * mb))

    // One dip in the window breaks the streak.
    var withDip = growing
    withDip[6] = withDip[5]
    #expect(MemoryGrowthDetector.hint(user: "alice", history: withDip, totalBytes: total) == nil)

    // Too few samples, or growth too small to matter.
    let shortHistory = Array(growing.prefix(11))
    let shortHint = MemoryGrowthDetector.hint(
      user: "alice", history: shortHistory, totalBytes: total)
    #expect(shortHint == nil)
    let tinyGrowth = (0..<12).map { UInt64($0) * mb + 1_000 * mb }
    #expect(MemoryGrowthDetector.hint(user: "alice", history: tinyGrowth, totalBytes: total) == nil)
  }

  @MainActor @Test func processViewModelResetsHistoryForUsersThatDisappear() {
    let vm = ProcessViewModel()
    let start = Date(timeIntervalSince1970: 1_000)
    let alice = ProcessSnapshot(user: "alice", pid: 1, rssBytes: 100, command: "/a")
    let bob = ProcessSnapshot(user: "bob", pid: 2, rssBytes: 50, command: "/b")

    vm.apply(snapshots: [alice, bob], sampledAt: start)
    vm.apply(snapshots: [bob], sampledAt: start.addingTimeInterval(5))
    vm.apply(snapshots: [alice, bob], sampledAt: start.addingTimeInterval(10))

    #expect(vm.history(for: "alice").count == 1)
    #expect(vm.history(for: "bob").count == 3)
  }

  @Test func growthDetectorFlagsSuddenJumpAboveThreshold() {
    let mb: UInt64 = 1024 * 1024
    let total: UInt64 = 16 * 1024 * mb  // 5% = ~819 MB, above the 500 MB floor.

    let jump = MemoryGrowthDetector.hint(
      user: "bob", history: [1_000 * mb, 1_900 * mb], totalBytes: total)
    #expect(jump == MemoryGrowthHint(user: "bob", kind: .suddenJump, growthBytes: 900 * mb))

    let belowThreshold = MemoryGrowthDetector.hint(
      user: "bob", history: [1_000 * mb, 1_700 * mb], totalBytes: total)
    #expect(belowThreshold == nil)

    let drop = MemoryGrowthDetector.hint(
      user: "bob", history: [1_900 * mb, 1_000 * mb], totalBytes: total)
    #expect(drop == nil)
  }

  @Test func initialSamplingDelaySkipsResampleRightAfterASample() {
    let now = Date(timeIntervalSince1970: 1_000)

    #expect(PeriodicSampler.initialDelay(lastSampleAt: nil, now: now, interval: 5) == 0)
    #expect(
      PeriodicSampler.initialDelay(
        lastSampleAt: now.addingTimeInterval(-0.5), now: now, interval: 5) == 4.5)
    #expect(
      PeriodicSampler.initialDelay(
        lastSampleAt: now.addingTimeInterval(-3), now: now, interval: 5) == 0)
    // Clock moved backwards: sample right away instead of waiting.
    #expect(
      PeriodicSampler.initialDelay(
        lastSampleAt: now.addingTimeInterval(10), now: now, interval: 5) == 0)
  }

  @Test func initialSamplingDelayWaitsFullIntervalWhenPopoverCloses() {
    let now = Date(timeIntervalSince1970: 1_000)

    // Closing never samples right away: the next sample lands one idle interval after the last.
    #expect(
      PeriodicSampler.initialDelay(
        lastSampleAt: now.addingTimeInterval(-3), now: now, interval: 15, minimumGap: .infinity
      ) == 12)
    #expect(
      PeriodicSampler.initialDelay(
        lastSampleAt: now.addingTimeInterval(-20), now: now, interval: 15, minimumGap: .infinity
      ) == 0)
  }

  @MainActor @Test func periodicSamplerRunsOneFollowUpForRequestsDuringARun() {
    var runs = 0
    var pendingCompletion: (@MainActor () -> Void)?
    let sampler = PeriodicSampler(timerQueue: DispatchQueue(label: "test.sampler")) { completion in
      runs += 1
      pendingCompletion = completion
    }

    sampler.sampleNow()
    #expect(runs == 1)
    #expect(sampler.isSampling)

    // Several requests during a run collapse into one follow-up.
    sampler.sampleNow()
    sampler.sampleNow()
    #expect(runs == 1)

    pendingCompletion?()
    #expect(runs == 2)
    #expect(sampler.isSampling)

    pendingCompletion?()
    #expect(runs == 2)
    #expect(!sampler.isSampling)
  }

  @Test func memoryFormatUsesMegabytesBelowOneGigabyte() {
    let mb: UInt64 = 1_048_576
    let gb: UInt64 = 1_073_741_824

    #expect(MemoryFormat.size(0) == "0 MB")
    #expect(MemoryFormat.size(512 * mb) == "512 MB")
    #expect(MemoryFormat.size(1023 * mb) == "1023 MB")
    // 1023.6 MB would print as "1024 MB", so it switches to GB.
    #expect(MemoryFormat.size(1023 * mb + 600 * 1024) == "1.00 GB")
    #expect(MemoryFormat.size(gb) == "1.00 GB")
    #expect(MemoryFormat.size(gb * 3 / 2) == "1.50 GB")
  }

  @Test func memoryFormatAxisTicksUseWholeGigabytes() {
    let gb = 1_073_741_824.0

    #expect(MemoryFormat.axisTickValues(upperBound: 16 * gb) == [0, 4, 8, 12, 16].map { $0 * gb })
    #expect(MemoryFormat.axisTickValues(upperBound: 24 * gb) == [0, 8, 16, 24].map { $0 * gb })
    #expect(MemoryFormat.axisTickValues(upperBound: 18 * gb) == [0, 8, 18].map { $0 * gb })
    #expect(MemoryFormat.axisTickValues(upperBound: 36 * gb) == [0, 16, 36].map { $0 * gb })
    #expect(MemoryFormat.axisTickValues(upperBound: 0.5 * gb) == [0])
    #expect(MemoryFormat.axisTick(0) == "0 GB")
    #expect(MemoryFormat.axisTick(8 * gb) == "8 GB")
  }

  @Test func processCommandNameParsesExecutable() {
    #expect(ProcessCommandName.displayName(from: "/usr/bin/swift build -c release") == "swift")
    #expect(
      ProcessCommandName.displayName(from: "/Applications/My\\ App.app/Contents/MacOS/My\\ App -x")
        == "My App")
    #expect(ProcessCommandName.displayName(from: "\"/opt/a b/tool\" --flag") == "tool")
    #expect(ProcessCommandName.displayName(from: "launchd") == "launchd")
    #expect(ProcessCommandName.displayName(from: "   ") == "Unknown")
  }

  @MainActor @Test func memoryViewModelBuildsSegmentsOnSample() {
    let vm = MemoryViewModel(maxSamples: 3)
    let start = Date(timeIntervalSince1970: 1_000)
    for index in 0..<4 {
      vm.apply(
        stats: MemoryStats(
          totalBytes: 1_000, usedBytes: UInt64(100 * index), freeBytes: 0, activeBytes: 0,
          inactiveBytes: 0, wiredBytes: 0, compressedBytes: 0, swapUsedBytes: 0,
          pressureLevel: .normal),
        sampledAt: start.addingTimeInterval(Double(index)))
    }

    #expect(vm.historySegments == MemoryHistorySegmentPoint.segments(from: vm.history))
    #expect(vm.historySegments.count == 4)

    vm.setMaxSamples(2)
    #expect(vm.historySegments == MemoryHistorySegmentPoint.segments(from: vm.history))
    #expect(vm.historySegments.count == 2)
  }

  @MainActor @Test func processViewModelCachesVisibleRowsAndNames() {
    let vm = ProcessViewModel(topProcessesLimit: 2)
    vm.apply(snapshots: [
      ProcessSnapshot(user: "alice", pid: 1, rssBytes: 300, command: "/bin/a --x"),
      ProcessSnapshot(user: "bob", pid: 2, rssBytes: 200, command: "/bin/b"),
      ProcessSnapshot(user: "alice", pid: 3, rssBytes: 100, command: "/bin/c"),
    ])
    #expect(vm.visibleProcesses.map(\.pid) == [1, 2])
    #expect(vm.displayName(for: vm.visibleProcesses[0]) == "a")

    vm.selectedUser = "alice"
    #expect(vm.visibleProcesses.map(\.pid) == [1, 3])
    #expect(vm.displayName(for: vm.visibleProcesses[1]) == "c")

    vm.setLimits(topApps: 8, topProcesses: 1)
    #expect(vm.visibleProcesses.map(\.pid) == [1])

    // The selected user is gone, so the filter resets and the rows follow.
    vm.apply(snapshots: [ProcessSnapshot(user: "bob", pid: 2, rssBytes: 200, command: "/bin/b")])
    #expect(vm.selectedUser == nil)
    #expect(vm.visibleProcesses.map(\.pid) == [2])
    #expect(vm.displayName(for: vm.visibleProcesses[0]) == "b")
  }

  @Test func menuBarPercentHasNoPadding() {
    #expect(AppDelegate.percentText(5) == "5%")
    #expect(AppDelegate.percentText(45) == "45%")
    #expect(AppDelegate.percentText(100) == "100%")
    #expect(AppDelegate.percentText(150) == "100%")
    #expect(AppDelegate.percentText(nil) == "\u{2012}\u{2012}%")
  }

  @Test func growthHintIDsAreUniquePerUserAndKind() {
    let growth = MemoryGrowthHint(
      user: "alice", kind: .continuousGrowth(samples: 12), growthBytes: 1)
    let jump = MemoryGrowthHint(user: "alice", kind: .suddenJump, growthBytes: 1)
    #expect(growth.id != jump.id)
    #expect(growth == growth)
  }

  @Test func parseTopMemoryTokenHandlesChangeMarkersAndClamps() {
    #expect(TopProcessSnapshotParser.parseTopMemoryToken("12G+") == UInt64(12) * 1_073_741_824)
    #expect(TopProcessSnapshotParser.parseTopMemoryToken("512K-") == UInt64(512) * 1_024)
    #expect(TopProcessSnapshotParser.parseTopMemoryToken("300M") == UInt64(300) * 1_048_576)
    #expect(TopProcessSnapshotParser.parseTopMemoryToken("99999999999T") == UInt64.max)
    #expect(TopProcessSnapshotParser.parseTopMemoryToken("+") == nil)
    #expect(TopProcessSnapshotParser.parseTopMemoryToken("-5M") == nil)

    let snapshots = TopProcessSnapshotParser.parse(
      topOutput: """
        10 son 12G+ /Applications/Xcode.app
        11 son 512K- /usr/bin/vim
        """,
      limit: nil
    )
    #expect(snapshots.map(\.pid) == [10, 11])
  }

  @Test func topCommandUsesFastMemorySnapshotAndPositiveLimit() {
    let arguments = ProcessSnapshotService.topCommandArguments(processLimit: 0)

    #expect(
      arguments == [
        "-l", "1",
        "-F",
        "-o", "mem",
        "-stats", "pid,user,mem,command",
        "-n", "1",
      ])
    #expect(ProcessSnapshotService.primaryTopProcessLimit == 500)
    #expect(
      ProcessSnapshotService.fallbackTopProcessLimit < ProcessSnapshotService.primaryTopProcessLimit
    )
  }

  @Test func processSnapshotUsesPrimaryCommandWhenItSucceeds() throws {
    let runner = TopCommandRunnerSpy { _ in
      "100 son 1M /usr/bin/test"
    }
    let service = ProcessSnapshotService(topCommandRunner: runner.run)

    let snapshots = try service.fetchProcesses()

    #expect(snapshots.count == 1)
    #expect(runner.limits == [500])
  }

  @Test func processSnapshotRetriesWithSmallerLimitAfterTimeout() throws {
    let runner = TopCommandRunnerSpy { call in
      if call == 1 {
        throw ProcessSnapshotServiceError.commandTimedOut
      }
      return "100 son 1M /usr/bin/test"
    }
    let service = ProcessSnapshotService(topCommandRunner: runner.run)

    let snapshots = try service.fetchProcesses()

    #expect(snapshots.count == 1)
    #expect(runner.limits == [500, 150])
  }

  @Test func processSnapshotReportsFallbackFailure() {
    let runner = TopCommandRunnerSpy { call in
      if call == 1 {
        throw ProcessSnapshotServiceError.commandTimedOut
      }
      throw ProcessSnapshotServiceError.commandFailed(1, "busy")
    }
    let service = ProcessSnapshotService(topCommandRunner: runner.run)

    #expect(throws: ProcessSnapshotServiceError.commandFailed(1, "busy")) {
      try service.fetchProcesses()
    }
    #expect(runner.limits == [500, 150])
  }

  @MainActor @Test func appStateCoalescesRefreshesWhileSampling() async {
    let processProvider = GatedProcessProvider()
    let appState = MemStatsAppState(
      startSampling: false,
      memoryService: StubMemoryStatsProvider(),
      processService: processProvider
    )

    appState.sampleImmediately()
    #expect(appState.isSampling)
    // Repeated clicks while `top` runs collapse into a single follow-up sample.
    appState.sampleImmediately()
    appState.sampleImmediately()
    appState.sampleImmediately()
    processProvider.releaseFirstFetch()

    var waits = 0
    while (appState.isSampling || processProvider.fetchCount < 2) && waits < 200 {
      try? await Task.sleep(for: .milliseconds(10))
      waits += 1
    }
    // Give a stray third sample a chance to show up before checking the count.
    try? await Task.sleep(for: .milliseconds(50))

    #expect(processProvider.fetchCount == 2)
    #expect(appState.isSampling == false)
    #expect(appState.processVM.allProcesses.count == 1)
  }

  @MainActor @Test func appStateKeepsLoadingUntilProcessSampleLandsOrFails() async {
    // A memory error alone keeps the process lists loading.
    let processProvider = GatedProcessProvider()
    let gated = MemStatsAppState(
      startSampling: false,
      memoryService: FailingMemoryStatsProvider(),
      processService: processProvider
    )
    #expect(gated.isWaitingForFirstProcessSample)
    gated.sampleImmediately()
    var waits = 0
    while gated.lastSamplingError == nil && waits < 200 {
      try? await Task.sleep(for: .milliseconds(10))
      waits += 1
    }
    #expect(gated.lastSamplingError != nil)
    #expect(gated.isWaitingForFirstProcessSample)
    processProvider.releaseFirstFetch()

    // A failed process sample ends loading.
    let failing = MemStatsAppState(
      startSampling: false,
      memoryService: StubMemoryStatsProvider(),
      processService: FailingProcessProvider()
    )
    failing.sampleImmediately()
    waits = 0
    while failing.isSampling && waits < 200 {
      try? await Task.sleep(for: .milliseconds(10))
      waits += 1
    }
    #expect(!failing.isWaitingForFirstProcessSample)
    #expect(!failing.processVM.hasSampled)
  }

  @MainActor @Test func appStatePersistsShowSystemUsersOption() {
    let suiteName = "MemStatsTests.ShowSystemUsers"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let appState = MemStatsAppState(startSampling: false, defaults: defaults)
    #expect(appState.showsSystemUsers == true)

    appState.setShowsSystemUsers(false)
    #expect(appState.showsSystemUsers == false)
    #expect(defaults.bool(forKey: MemStatsAppState.showsSystemUsersKey) == false)

    let restored = MemStatsAppState(startSampling: false, defaults: defaults)
    #expect(restored.showsSystemUsers == false)
  }

  @MainActor @Test func appStateCachesDonutSlicesPerSample() {
    let appState = MemStatsAppState(startSampling: false)
    #expect(appState.donutSlices.isEmpty)

    let stats = MemoryStats(
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
    let processes = [
      ProcessSnapshot(user: "alice", pid: 1, rssBytes: 500, command: "/a")
    ]

    appState.applySample(stats: stats, processes: processes)
    #expect(appState.donutSlices.map(\.id) == ["user:alice", "unattributed", "free"])

    // A failed process sample keeps the previous processes for the donut.
    appState.applySample(stats: stats, processes: nil)
    #expect(appState.donutSlices.map(\.id) == ["user:alice", "unattributed", "free"])
  }

  @Test func loginItemServiceSyncsAndPersistsState() {
    let defaults = UserDefaults(suiteName: "MemStatsTests.LoginItem.Sync")!
    defaults.removePersistentDomain(forName: "MemStatsTests.LoginItem.Sync")

    let registrant = MockLoginItemRegistrant(status: .enabled)
    let service = LoginItemService(defaults: defaults, registrant: registrant)

    service.syncWithSystem()

    #expect(service.isEnabled == true)
    #expect(defaults.bool(forKey: "openAtLogin") == true)
  }

  @Test func loginItemServiceToggleCallsRegisterAndUnregister() throws {
    let defaults = UserDefaults(suiteName: "MemStatsTests.LoginItem.Toggle")!
    defaults.removePersistentDomain(forName: "MemStatsTests.LoginItem.Toggle")

    let registrant = MockLoginItemRegistrant(status: .notRegistered)
    let service = LoginItemService(defaults: defaults, registrant: registrant)

    let enabled = try service.toggle()
    #expect(enabled == true)
    #expect(registrant.didRegister == true)
    #expect(defaults.bool(forKey: "openAtLogin") == true)

    let disabled = try service.toggle()
    #expect(disabled == false)
    #expect(registrant.didUnregister == true)
    #expect(defaults.bool(forKey: "openAtLogin") == false)
  }

  @Test func loginItemServiceStaysDisabledWhenApprovalIsRequired() throws {
    let suiteName = "MemStatsTests.LoginItem.Approval"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let registrant = MockLoginItemRegistrant(
      status: .notRegistered,
      statusAfterRegister: .requiresApproval
    )
    let service = LoginItemService(defaults: defaults, registrant: registrant)

    let enabled = try service.toggle()

    #expect(registrant.didRegister == true)
    #expect(enabled == false)
    #expect(service.isEnabled == false)
    #expect(service.requiresApproval == true)
    #expect(service.isRequested == true)
    #expect(defaults.bool(forKey: "openAtLogin") == false)
  }

  @Test func loginItemServiceCancelsPendingApprovalOnToggle() throws {
    let suiteName = "MemStatsTests.LoginItem.CancelApproval"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    // Registered earlier and still waiting for approval when the app starts.
    let registrant = MockLoginItemRegistrant(status: .requiresApproval)
    let service = LoginItemService(defaults: defaults, registrant: registrant)
    service.syncWithSystem()
    #expect(service.requiresApproval == true)
    #expect(service.isEnabled == false)

    // The next click cancels instead of registering again.
    let enabled = try service.toggle()
    #expect(enabled == false)
    #expect(registrant.didUnregister == true)
    #expect(registrant.didRegister == false)
    #expect(service.requiresApproval == false)
    #expect(service.isRequested == false)
  }

  @Test func loginItemServiceTogglesFromFreshSystemState() throws {
    let suiteName = "MemStatsTests.LoginItem.Fresh"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let registrant = MockLoginItemRegistrant(status: .requiresApproval)
    let service = LoginItemService(defaults: defaults, registrant: registrant)
    service.syncWithSystem()

    // Approved in System Settings while the app ran: the next click turns it off, as expected
    // for an enabled item, without a stale "pending" state in between.
    registrant.status = .enabled
    let enabled = try service.toggle()
    #expect(enabled == false)
    #expect(registrant.didUnregister == true)

    // Removed in System Settings (`.notFound`): the next click registers.
    registrant.status = .notFound
    let reenabled = try service.toggle()
    #expect(reenabled == true)
    #expect(registrant.didRegister == true)
  }

  @Test func latestReleaseURLPointsToGitHubReleases() {
    #expect(
      AppLinks.latestReleaseURL.absoluteString
        == "https://github.com/sown-oss/MemStats/releases/latest")
  }

  @Test func sponsorURLPointsToGitHubSponsors() {
    #expect(AppLinks.sponsorURL.absoluteString == "https://github.com/sown-oss/MemStats/")
  }

  @Test func bugReportURLPrefillsTitleLabelAndEnvironment() throws {
    let url = AppLinks.bugReportURL(
      appVersion: "1.2+beta",
      appBuild: "7",
      osVersion: "Version 15.1 (Build 24B83)",
      model: "Mac15,6",
      architecture: "arm64"
    )
    #expect(url.absoluteString.hasPrefix("https://github.com/sown-oss/MemStats/issues/new?"))

    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    #expect(values["title"] == "[Bug] ")
    #expect(values["labels"] == "bug")
    let body = try #require(values["body"])
    #expect(body.contains("- MemStats: 1.2+beta (7)"))
    #expect(url.absoluteString.contains("1.2%2Bbeta"))
    #expect(body.contains("- macOS: Version 15.1 (Build 24B83)"))
    #expect(body.contains("- Mac: Mac15,6 (arm64)"))
  }

  /// Hosts SettingsView the way AppDelegate does. Some Form rows (LabeledContent) made AppKit
  /// loop on Update Constraints and crash the app as soon as the window was shown.
  @MainActor @Test func settingsWindowLaysOutWithoutCrashing() async throws {
    let suiteName = "settings-window-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let appState = MemStatsAppState(startSampling: false, defaults: defaults)
    let controller = NSHostingController(
      rootView: SettingsView(
        appState: appState,
        loginItemService: LoginItemService(),
        onToggleOpenAtLogin: {}
      )
    )
    let window = NSWindow(contentViewController: controller)
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.setContentSize(NSSize(width: 440, height: 702))
    window.orderFront(nil)
    defer { window.close() }

    try await Task.sleep(for: .milliseconds(500))
    #expect(window.frame.width > 0)
    #expect(window.frame.height > 0)
  }

  @Test func commandQAndWAreWindowDismissShortcuts() throws {
    let commandQ = try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "q",
        charactersIgnoringModifiers: "q",
        isARepeat: false,
        keyCode: 12
      )
    )
    let commandW = try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "w",
        charactersIgnoringModifiers: "w",
        isARepeat: false,
        keyCode: 13
      )
    )
    let commandComma = try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: ",",
        charactersIgnoringModifiers: ",",
        isARepeat: false,
        keyCode: 43
      )
    )
    let commandShiftQ = try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command, .shift],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "Q",
        charactersIgnoringModifiers: "q",
        isARepeat: false,
        keyCode: 12
      )
    )

    #expect(WindowDismissShortcut.matches(commandQ))
    #expect(WindowDismissShortcut.matches(commandW))
    #expect(!WindowDismissShortcut.matches(commandQ, menuIsTracking: true))
    #expect(WindowDismissShortcut.matchesSettings(commandComma))
    #expect(!WindowDismissShortcut.matches(commandShiftQ))
  }
}
