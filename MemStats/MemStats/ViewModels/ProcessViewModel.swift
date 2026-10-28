import Combine
import Foundation

@MainActor
final class ProcessViewModel: ObservableObject {
  /// Whether Quit and Force Quit are offered for a row.
  enum QuitAvailability: Equatable {
    case available
    case otherUser
    case protected
  }

  struct UserMemoryHistorySample: Sendable, Equatable {
    let timestamp: Date
    let user: String
    /// Raw summed RSS, used for growth detection.
    let rssBytes: UInt64
    /// RSS scaled the same way as the donut, so it fits on the used RAM chart.
    let displayBytes: UInt64
  }

  @Published private(set) var allProcesses: [ProcessSnapshot] = []
  @Published private(set) var topProcesses: [ProcessSnapshot] = []
  /// Rows for the current filter, rebuilt only on a new sample, a filter change or new limits,
  /// so rendering never filters or aggregates.
  @Published private(set) var visibleApps: [AppMemoryUsage] = []
  @Published private(set) var visibleProcesses: [ProcessSnapshot] = []
  /// False until the first process sample lands, so the lists can show a loading state.
  @Published private(set) var hasSampled = false
  @Published var selectedUser: String? {
    didSet {
      guard selectedUser != oldValue else { return }
      refreshVisibleLists()
    }
  }

  private var userHistoryByUser: [String: [UserMemoryHistorySample]] = [:]
  /// The snapshot before the current one, for the treemap's change colors. The lookups below
  /// build lazily, so they cost nothing while the list style is shown.
  private var previousProcesses: [ProcessSnapshot] = []
  private var previousIdentities: [Int32: AppIdentity] = [:]
  private var previousRSSByPID: [Int32: UInt64]?
  private var previousAppBytes: [String: UInt64]?
  private(set) var maxSamples: Int
  private(set) var topAppsLimit: Int
  private(set) var topProcessesLimit: Int
  private var appIdentities: [Int32: AppIdentity] = [:]
  /// PROCESS column names for the visible rows, so a command is parsed once, not per render.
  private var displayNameByCommand: [String: String] = [:]
  /// When the current snapshot was requested, before `top` ran. Every process in it started
  /// before this.
  private(set) var snapshotTakenAt: Date?
  /// Built on the first Quit lookup after each sample.
  private var processByPID: [Int32: ProcessSnapshot]?
  private let currentUser: String

  init(
    maxSamples: Int = 120,
    topAppsLimit: Int = 8,
    topProcessesLimit: Int = 8,
    currentUser: String = NSUserName()
  ) {
    self.maxSamples = max(maxSamples, 1)
    self.topAppsLimit = max(topAppsLimit, 0)
    self.topProcessesLimit = max(topProcessesLimit, 0)
    self.currentUser = currentUser
  }

  /// Changes the row counts and re-slices the current snapshot, without a new sample.
  func setLimits(topApps: Int, topProcesses: Int) {
    let nextAppsLimit = max(topApps, 0)
    let nextProcessesLimit = max(topProcesses, 0)
    guard nextAppsLimit != topAppsLimit || nextProcessesLimit != topProcessesLimit else { return }

    topAppsLimit = nextAppsLimit
    topProcessesLimit = nextProcessesLimit
    self.topProcesses = Array(allProcesses.prefix(topProcessesLimit))
    refreshVisibleLists()
  }

  /// Changes how many samples each user's history keeps and drops the oldest extra ones.
  func setMaxSamples(_ maxSamples: Int) {
    self.maxSamples = max(maxSamples, 1)
    userHistoryByUser = userHistoryByUser.mapValues { Array($0.suffix(self.maxSamples)) }
  }

  func apply(
    snapshots: [ProcessSnapshot],
    appIdentities: [Int32: AppIdentity] = [:],
    targetUsedBytes: UInt64? = nil,
    sampledAt: Date = Date()
  ) {
    previousProcesses = allProcesses
    previousIdentities = self.appIdentities
    previousRSSByPID = nil
    previousAppBytes = nil
    self.appIdentities = appIdentities
    allProcesses = snapshots
    snapshotTakenAt = sampledAt
    processByPID = nil
    if !hasSampled {
      hasSampled = true
    }
    topProcesses = Array(snapshots.prefix(topProcessesLimit))
    let adjustedTimestamp: Date
    let latestTimestamp = userHistoryByUser.values.compactMap(\.last?.timestamp).max()
    if let latestTimestamp, sampledAt <= latestTimestamp {
      adjustedTimestamp = latestTimestamp.addingTimeInterval(0.001)
    } else {
      adjustedTimestamp = sampledAt
    }

    var rssByUser: [String: UInt64] = [:]
    for snapshot in snapshots {
      rssByUser[snapshot.user, default: 0] += snapshot.rssBytes
    }

    // Drop history for users missing from this snapshot, so a user that comes back starts a
    // fresh series instead of bridging the gap (which would look like a sudden jump).
    userHistoryByUser = userHistoryByUser.filter { rssByUser[$0.key] != nil }

    let displayByUser = targetUsedBytes.map {
      DonutDataBuilder.normalizePerUserBytes(rssByUser, targetUsedBytes: $0)
    }

    for (user, rssBytes) in rssByUser {
      var history = userHistoryByUser[user, default: []]
      history.append(
        UserMemoryHistorySample(
          timestamp: adjustedTimestamp,
          user: user,
          rssBytes: rssBytes,
          displayBytes: displayByUser.map { $0[user] ?? 0 } ?? rssBytes
        )
      )
      if history.count > maxSamples {
        history.removeFirst(history.count - maxSamples)
      }
      userHistoryByUser[user] = history
    }

    if let selectedUser, !allProcesses.contains(where: { $0.user == selectedUser }) {
      self.selectedUser = nil
    } else {
      refreshVisibleLists()
    }
  }

  /// Name for the PROCESS column, from the cache when the row is visible.
  func displayName(for process: ProcessSnapshot) -> String {
    displayNameByCommand[process.command]
      ?? ProcessCommandName.displayName(from: process.command)
  }

  /// Path to take a process's icon from: its app bundle (helpers share the app's icon), or its
  /// executable. `nil` when the path could not be resolved.
  func iconPath(for process: ProcessSnapshot) -> String? {
    appIdentities[process.pid]?.path
  }

  /// Fractional change in RSS since the previous sample, or `nil` for a new process.
  func change(for process: ProcessSnapshot) -> Double? {
    guard !previousProcesses.isEmpty else { return nil }
    if previousRSSByPID == nil {
      previousRSSByPID = Dictionary(
        previousProcesses.map { ($0.pid, $0.rssBytes) }, uniquingKeysWith: { first, _ in first })
    }
    guard let previous = previousRSSByPID?[process.pid] else { return nil }
    return Self.change(from: previous, to: process.rssBytes)
  }

  /// Same, for an app. Compared within the current user filter, so a filtered app is not
  /// measured against the app's total across all users.
  func change(for app: AppMemoryUsage) -> Double? {
    guard !previousProcesses.isEmpty else { return nil }
    if previousAppBytes == nil {
      let scoped =
        selectedUser.map { user in previousProcesses.filter { $0.user == user } }
        ?? previousProcesses
      let apps = AppMemoryAggregator.aggregate(processes: scoped, identities: previousIdentities)
      previousAppBytes = Dictionary(
        apps.map { ($0.id, $0.bytes) }, uniquingKeysWith: { first, _ in first })
    }
    guard let previous = previousAppBytes?[app.id] else { return nil }
    return Self.change(from: previous, to: app.bytes)
  }

  /// Only the current user's own processes can be signaled without privileges. The `top` user
  /// name is the full account name, and the uid is checked again before quitting.
  func quitAvailability(for process: ProcessSnapshot) -> QuitAvailability {
    guard process.user == currentUser else { return .otherUser }
    let name = displayName(for: process)
    return ProcessTerminator.isProtected(pid: process.pid, name: name) ? .protected : .available
  }

  func quitAvailability(for app: AppMemoryUsage) -> QuitAvailability {
    if !quitPIDs(for: app).isEmpty {
      return .available
    }
    let ownsAny = app.pids.contains { process(pid: $0)?.user == currentUser }
    return ownsAny ? .protected : .otherUser
  }

  /// The app's processes that Quit signals: the current user's, minus protected ones.
  func quitPIDs(for app: AppMemoryUsage) -> [Int32] {
    app.pids.filter { pid in
      guard let process = process(pid: pid) else { return false }
      return quitAvailability(for: process) == .available
    }
  }

  func hasOtherUsersProcesses(_ app: AppMemoryUsage) -> Bool {
    app.pids.contains { pid in
      process(pid: pid).map { $0.user != currentUser } ?? false
    }
  }

  private func process(pid: Int32) -> ProcessSnapshot? {
    if processByPID == nil {
      processByPID = Dictionary(
        allProcesses.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    }
    return processByPID?[pid]
  }

  private static func change(from previous: UInt64, to current: UInt64) -> Double? {
    guard previous > 0 else { return nil }
    return Double(current) / Double(previous) - 1
  }

  private func refreshVisibleLists() {
    // The previous-app lookup depends on the filter, so it is rebuilt on demand.
    previousAppBytes = nil
    let scopedProcesses: [ProcessSnapshot]
    if let selectedUser {
      scopedProcesses = allProcesses.filter { $0.user == selectedUser }
    } else {
      scopedProcesses = allProcesses
    }

    let nextProcesses = Array(scopedProcesses.prefix(topProcessesLimit))
    var nextNames: [String: String] = [:]
    for process in nextProcesses where nextNames[process.command] == nil {
      nextNames[process.command] =
        displayNameByCommand[process.command]
        ?? ProcessCommandName.displayName(from: process.command)
    }
    displayNameByCommand = nextNames
    if nextProcesses != visibleProcesses {
      visibleProcesses = nextProcesses
    }

    visibleApps = AppMemoryAggregator.aggregate(
      processes: scopedProcesses,
      identities: appIdentities,
      limit: topAppsLimit
    )
  }

  var selectedUserHistory: [UserMemoryHistorySample] {
    guard let selectedUser else { return [] }
    return userHistoryByUser[selectedUser] ?? []
  }

  func history(for user: String) -> [UserMemoryHistorySample] {
    userHistoryByUser[user] ?? []
  }
}
