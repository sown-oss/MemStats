import Combine
import Foundation

@MainActor
final class MemStatsAppState: ObservableObject {
  enum SamplingMode: Equatable {
    case active
    case idle
  }

  enum SamplingKind: Equatable {
    case memory
    case process

    /// While the popover is closed, the timer runs no faster than this. Processes run `top`,
    /// the expensive part, and only feed the popover, per-user history and growth hints, so
    /// they slow down further than memory, which also drives the menu bar.
    nonisolated var idleMinimumInterval: Int {
      switch self {
      case .memory:
        return 15
      case .process:
        return 60
      }
    }
  }

  /// A Quit or Force Quit waiting for the user to confirm it in its section.
  struct QuitRequest: Equatable {
    let name: String
    /// Shown for a single process, `nil` for an app.
    let pid: Int32?
    let mode: ProcessQuitMode
    let section: PopoverSection
    let targets: [ProcessTarget]
    /// The app also has processes of other users, which keep running.
    let skipsOtherUsers: Bool
  }

  struct QuitFailure: Equatable {
    let section: PopoverSection
    let error: ProcessTerminationError
  }

  /// History keeps about this many seconds of samples, whatever the interval.
  nonisolated static let historyWindowSeconds = 600
  nonisolated static let maxHistorySamples = 600

  @Published private(set) var samplingMode: SamplingMode = .idle
  /// Intervals the timers currently run at, for the History status row.
  @Published private(set) var memorySamplingInterval: TimeInterval
  @Published private(set) var processSamplingInterval: TimeInterval
  @Published private(set) var lastSamplingError: String?
  @Published private(set) var donutSlices: [DonutSlice] = []
  @Published private(set) var growthHints: [MemoryGrowthHint] = []
  /// Whether `root` and `_*` system users are included in the sampled processes.
  @Published private(set) var showsSystemUsers: Bool
  @Published private(set) var pendingQuit: QuitRequest?
  @Published private(set) var quitFailure: QuitFailure?

  let memoryVM: MemoryViewModel
  let processVM: ProcessViewModel
  let settings: SettingsStore

  static let showsSystemUsersKey = "showSystemUsers"

  private let memoryService: any MemoryStatsProviding
  private let processService: any ProcessSnapshotProviding
  private let processTerminator: any ProcessTerminating
  private let defaults: UserDefaults
  private let timerQueue = DispatchQueue(label: "com.chungxon.memstats.timers", qos: .utility)
  /// Separate queues, so a slow `top` run never delays a memory sample.
  private let memoryQueue = DispatchQueue(label: "com.chungxon.memstats.memory", qos: .utility)
  private let processQueue = DispatchQueue(label: "com.chungxon.memstats.process", qos: .utility)

  private lazy var memorySampler = PeriodicSampler(timerQueue: timerQueue) {
    [weak self] completion in
    self?.runMemorySample(completion: completion)
  }
  private lazy var processSampler = PeriodicSampler(timerQueue: timerQueue) {
    [weak self] completion in
    self?.runProcessSample(completion: completion)
  }
  private var memoryError: String?
  private var processError: String?

  /// True until a process sample succeeds or fails. A memory error alone does not end it, since
  /// the process lists are still waiting for `top`. Changes publish through `lastSamplingError`
  /// and `processVM`.
  var isWaitingForFirstProcessSample: Bool {
    !processVM.hasSampled && processError == nil
  }
  private var cancellables: Set<AnyCancellable> = []

  init(
    startSampling: Bool = true,
    defaults: UserDefaults = .standard,
    settings: SettingsStore? = nil,
    memoryService: (any MemoryStatsProviding)? = nil,
    processService: (any ProcessSnapshotProviding)? = nil,
    processTerminator: (any ProcessTerminating)? = nil,
    currentUser: String = NSUserName()
  ) {
    let settings = settings ?? SettingsStore(defaults: defaults)
    self.settings = settings
    memoryVM = MemoryViewModel(
      maxSamples: Self.historyCapacity(interval: settings.memoryInterval))
    processVM = ProcessViewModel(
      maxSamples: Self.historyCapacity(interval: settings.processInterval),
      topAppsLimit: settings.topAppsCount,
      topProcessesLimit: settings.topProcessesCount,
      currentUser: currentUser
    )
    self.memoryService = memoryService ?? MemoryStatsService()
    self.processService = processService ?? ProcessSnapshotService()
    self.processTerminator = processTerminator ?? ProcessTerminator()
    self.defaults = defaults
    // Shown by default to match Activity Monitor's all-users view.
    showsSystemUsers = defaults.object(forKey: Self.showsSystemUsersKey) as? Bool ?? true
    memorySamplingInterval = Self.effectiveInterval(
      setting: settings.memoryInterval, mode: .idle, kind: .memory)
    processSamplingInterval = Self.effectiveInterval(
      setting: settings.processInterval, mode: .idle, kind: .process)

    // `@Published` emits before the property changes, so use the emitted values.
    Publishers.CombineLatest4(
      settings.$memoryInterval,
      settings.$processInterval,
      settings.$topAppsCount,
      settings.$topProcessesCount
    )
    .dropFirst()
    .removeDuplicates { $0 == $1 }
    .sink { [weak self] memoryInterval, processInterval, topApps, topProcesses in
      self?.applySettings(
        memoryInterval: memoryInterval,
        processInterval: processInterval,
        topApps: topApps,
        topProcesses: topProcesses
      )
    }
    .store(in: &cancellables)

    settings.$language
      .dropFirst()
      .sink { [weak self] _ in
        self?.publishSamplingError()
      }
      .store(in: &cancellables)

    // The user filter can only be cleared from Top Users, so hiding that section clears it.
    settings.$hiddenSections
      .filter { $0.contains(.topUsers) }
      .sink { [weak self] _ in
        self?.processVM.selectedUser = nil
      }
      .store(in: &cancellables)

    if startSampling {
      restartTimers()
    }
  }

  var isSampling: Bool {
    memorySampler.isSampling || processSampler.isSampling
  }

  func setShowsSystemUsers(_ shows: Bool) {
    guard shows != showsSystemUsers else { return }

    showsSystemUsers = shows
    defaults.set(shows, forKey: Self.showsSystemUsersKey)
    // Resample right away so every section reflects the new filter.
    if processSampler.isScheduled {
      processSampler.sampleNow()
    }
  }

  func setPopoverPresented(_ isPresented: Bool) {
    let nextMode: SamplingMode = isPresented ? .active : .idle
    guard nextMode != samplingMode else { return }

    samplingMode = nextMode
    if !isPresented {
      pendingQuit = nil
      quitFailure = nil
    }
    // Opening samples right away (unless one ran moments ago). Closing only switches to the
    // idle interval, counted from the last sample.
    restartTimers(waitsFullInterval: !isPresented)
  }

  /// Samples memory and processes now. A kind that is already running gets exactly one
  /// follow-up run instead.
  func sampleImmediately() {
    memorySampler.sampleNow()
    processSampler.sampleNow()
  }

  /// Asks to confirm quitting one process from Top Processes.
  func requestQuit(process: ProcessSnapshot, mode: ProcessQuitMode) {
    guard processVM.quitAvailability(for: process) == .available else { return }
    requestQuit(
      name: processVM.displayName(for: process),
      pid: process.pid,
      pids: [process.pid],
      mode: mode,
      section: .topProcesses,
      skipsOtherUsers: false
    )
  }

  /// Asks to confirm quitting the current user's processes of an app from Top Apps.
  func requestQuit(app: AppMemoryUsage, mode: ProcessQuitMode) {
    let pids = processVM.quitPIDs(for: app)
    guard !pids.isEmpty else { return }
    requestQuit(
      name: app.name,
      pid: nil,
      pids: pids,
      mode: mode,
      section: .topApps,
      skipsOtherUsers: processVM.hasOtherUsersProcesses(app)
    )
  }

  func cancelQuit() {
    pendingQuit = nil
  }

  func dismissQuitFailure() {
    quitFailure = nil
  }

  /// Signals the confirmed request, then samples again so the lists drop what quit.
  func confirmQuit() {
    guard let request = pendingQuit else { return }
    pendingQuit = nil
    do {
      try processTerminator.terminate(request.targets, mode: request.mode)
    } catch {
      quitFailure = QuitFailure(section: request.section, error: error)
    }
    // Apps quit asynchronously, so give them a moment before sampling.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.processSampler.sampleNow()
    }
  }

  /// Captures each process as it is now. A process that started after the snapshot that showed
  /// it is not the one the user picked, so it is left out.
  private func requestQuit(
    name: String,
    pid: Int32?,
    pids: [Int32],
    mode: ProcessQuitMode,
    section: PopoverSection,
    skipsOtherUsers: Bool
  ) {
    quitFailure = nil
    let snapshotTime = processVM.snapshotTakenAt ?? .distantPast
    var targets: [ProcessTarget] = []
    var firstError: ProcessTerminationError?
    for pid in pids {
      guard let target = processTerminator.target(pid: pid) else {
        firstError = firstError ?? .notRunning
        continue
      }
      guard target.startDate <= snapshotTime else {
        firstError = firstError ?? .processChanged
        continue
      }
      targets.append(target)
    }

    guard !targets.isEmpty else {
      pendingQuit = nil
      quitFailure = QuitFailure(section: section, error: firstError ?? .notRunning)
      return
    }
    pendingQuit = QuitRequest(
      name: name,
      pid: pid,
      mode: mode,
      section: section,
      targets: targets,
      skipsOtherUsers: skipsOtherUsers
    )
  }

  /// Interval for a timer: the setting while the popover is open, at least the kind's
  /// `idleMinimumInterval` while it is closed. Never below 1s, since `SettingsStore` briefly
  /// publishes an invalid value before falling back to the default.
  nonisolated static func effectiveInterval(
    setting: Int,
    mode: SamplingMode,
    kind: SamplingKind
  ) -> TimeInterval {
    switch mode {
    case .active:
      return TimeInterval(max(setting, 1))
    case .idle:
      return TimeInterval(max(setting, kind.idleMinimumInterval))
    }
  }

  /// Samples kept for about `historyWindowSeconds` at the given interval, capped at
  /// `maxHistorySamples`.
  nonisolated static func historyCapacity(interval: Int) -> Int {
    let samples = (Double(historyWindowSeconds) / Double(max(interval, 1))).rounded(.up)
    return min(maxHistorySamples, Int(samples))
  }

  private func restartTimers(waitsFullInterval: Bool = false) {
    memorySamplingInterval = Self.effectiveInterval(
      setting: settings.memoryInterval, mode: samplingMode, kind: .memory)
    processSamplingInterval = Self.effectiveInterval(
      setting: settings.processInterval, mode: samplingMode, kind: .process)
    memorySampler.start(interval: memorySamplingInterval, waitsFullInterval: waitsFullInterval)
    processSampler.start(interval: processSamplingInterval, waitsFullInterval: waitsFullInterval)
  }

  private func applySettings(
    memoryInterval: Int,
    processInterval: Int,
    topApps: Int,
    topProcesses: Int
  ) {
    memoryVM.setMaxSamples(Self.historyCapacity(interval: memoryInterval))
    processVM.setMaxSamples(Self.historyCapacity(interval: processInterval))
    processVM.setLimits(topApps: topApps, topProcesses: topProcesses)

    // A new interval takes effect from the last sample, so a change never forces a sample.
    let nextMemoryInterval = Self.effectiveInterval(
      setting: memoryInterval, mode: samplingMode, kind: .memory)
    if memorySampler.isScheduled, nextMemoryInterval != memorySamplingInterval {
      memorySamplingInterval = nextMemoryInterval
      memorySampler.start(interval: nextMemoryInterval, waitsFullInterval: true)
    }
    let nextProcessInterval = Self.effectiveInterval(
      setting: processInterval, mode: samplingMode, kind: .process)
    if processSampler.isScheduled, nextProcessInterval != processSamplingInterval {
      processSamplingInterval = nextProcessInterval
      processSampler.start(interval: nextProcessInterval, waitsFullInterval: true)
    }
  }

  private func runMemorySample(completion: @escaping @MainActor () -> Void) {
    let memoryService = memoryService
    memoryQueue.async { [weak self] in
      let sampledAt = Date()
      let result = Result { try memoryService.fetchMemoryStats() }
      Task { @MainActor [weak self] in
        defer { completion() }
        guard let self else { return }
        switch result {
        case .success(let stats):
          self.memoryError = nil
          self.applySample(stats: stats, processes: nil, sampledAt: sampledAt)
        case .failure(let error):
          self.memoryError = error.localizedDescription
        }
        self.publishSamplingError()
      }
    }
  }

  private func runProcessSample(completion: @escaping @MainActor () -> Void) {
    let processService = processService
    let includesSystemUsers = showsSystemUsers
    processQueue.async { [weak self] in
      let sampledAt = Date()
      let result = Result {
        let processes = try processService.fetchProcesses(
          includeRootUser: includesSystemUsers,
          includeSystemUsers: includesSystemUsers
        )
        return (processes, AppIdentityResolver.resolve(pids: processes.map(\.pid)))
      }
      Task { @MainActor [weak self] in
        defer { completion() }
        guard let self else { return }
        switch result {
        case .success(let (processes, identities)):
          self.processError = nil
          self.applySample(
            stats: nil,
            processes: processes,
            appIdentities: identities,
            sampledAt: sampledAt
          )
        case .failure(let error):
          self.processError = error.localizedDescription
        }
        self.publishSamplingError()
      }
    }
  }

  private func publishSamplingError() {
    let language = settings.language
    var messages: [String] = []
    if let memoryError {
      messages.append(
        AppLocalization.formatted("Memory: %@", language: language, memoryError)
      )
    }
    if let processError {
      messages.append(
        AppLocalization.formatted("Process: %@", language: language, processError)
      )
    }
    let nextError = messages.isEmpty ? nil : messages.joined(separator: " | ")
    if nextError != lastSamplingError {
      lastSamplingError = nextError
    }
  }

  /// Applies one sampling result. A `nil` value means that part was not sampled this time
  /// (it failed, or only the other kind ran), so the previous data is kept.
  func applySample(
    stats: MemoryStats?,
    processes: [ProcessSnapshot]?,
    appIdentities: [Int32: AppIdentity] = [:],
    sampledAt: Date = Date()
  ) {
    if let stats {
      memoryVM.apply(stats: stats, sampledAt: sampledAt)
    }
    if let processes {
      let targetUsedBytes = memoryVM.currentStats.map {
        $0.totalBytes - min($0.freeBytes, $0.totalBytes)
      }
      processVM.apply(
        snapshots: processes,
        appIdentities: appIdentities,
        targetUsedBytes: targetUsedBytes,
        sampledAt: sampledAt
      )
      dropPendingQuitIfGone()
      refreshGrowthHints()
    }
    refreshDonutSlices()
  }

  /// A confirmation for processes that already exited would only signal nothing, so it goes.
  private func dropPendingQuitIfGone() {
    guard let pendingQuit else { return }
    let pids = Set(pendingQuit.targets.map(\.pid))
    if !processVM.allProcesses.contains(where: { pids.contains($0.pid) }) {
      self.pendingQuit = nil
    }
  }

  /// Only users in the current snapshot are checked, so a user that disappeared does not
  /// keep a stale hint.
  private func refreshGrowthHints() {
    guard let totalBytes = memoryVM.currentStats?.totalBytes else {
      if !growthHints.isEmpty {
        growthHints = []
      }
      return
    }

    let currentUsers = Set(processVM.allProcesses.map(\.user))
    let nextHints =
      currentUsers
      .compactMap { user in
        MemoryGrowthDetector.hint(
          user: user,
          history: processVM.history(for: user).map(\.rssBytes),
          totalBytes: totalBytes
        )
      }
      .sorted { lhs, rhs in
        if lhs.growthBytes == rhs.growthBytes {
          return lhs.user < rhs.user
        }
        return lhs.growthBytes > rhs.growthBytes
      }

    if nextHints != growthHints {
      growthHints = nextHints
    }
  }

  /// Donut grouping walks the whole process snapshot, so it runs once per sample here
  /// instead of on every view update (hover fires many updates per second).
  private func refreshDonutSlices() {
    guard let stats = memoryVM.currentStats else {
      if !donutSlices.isEmpty {
        donutSlices = []
      }
      return
    }

    let nextSlices = DonutDataBuilder.buildSlices(
      totalBytes: stats.totalBytes,
      freeBytes: stats.freeBytes,
      snapshots: processVM.allProcesses,
      tinyThreshold: 0.02
    )
    if nextSlices != donutSlices {
      donutSlices = nextSlices
    }
  }
}
