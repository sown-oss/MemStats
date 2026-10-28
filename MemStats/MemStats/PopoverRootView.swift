import AppKit
import Charts
import Foundation
import SwiftUI

struct PopoverRootView: View {
  /// Content area below the popup window's arrow.
  static let popoverSize = CGSize(width: 380, height: 540)

  @ObservedObject private var appState: MemStatsAppState
  @ObservedObject private var settings: SettingsStore
  @ObservedObject private var memoryVM: MemoryViewModel
  @ObservedObject private var processVM: ProcessViewModel
  @StateObject private var accessibilityDisplaySettings: AccessibilityDisplaySettings
  /// Leading edge of the visible history window.
  @State private var historyScrollPosition = Date()
  /// Whether the history window moves along with new samples.
  @State private var historyFollowsLatest = true

  private let onOpenActivityMonitor: () -> Void
  private let onOpenOptionsMenu: () -> Void
  private let onOptionsMenuAnchorAvailable: (NSView) -> Void

  init(
    appState: MemStatsAppState,
    onOpenActivityMonitor: @escaping () -> Void = {},
    onOpenOptionsMenu: @escaping () -> Void = {},
    onOptionsMenuAnchorAvailable: @escaping (NSView) -> Void = { _ in }
  ) {
    self._appState = ObservedObject(wrappedValue: appState)
    self._settings = ObservedObject(wrappedValue: appState.settings)
    self._memoryVM = ObservedObject(wrappedValue: appState.memoryVM)
    self._processVM = ObservedObject(wrappedValue: appState.processVM)
    self._accessibilityDisplaySettings = StateObject(
      wrappedValue: AccessibilityDisplaySettings()
    )
    self.onOpenActivityMonitor = onOpenActivityMonitor
    self.onOpenOptionsMenu = onOpenOptionsMenu
    self.onOptionsMenuAnchorAvailable = onOptionsMenuAnchorAvailable
  }

  private var useGlassBackground: Bool {
    GlassBackgroundResolver.shouldUseGlass(
      preferenceEnabled: settings.glassBackground,
      reduceTransparency: accessibilityDisplaySettings.shouldReduceTransparency
    )
  }

  private var modeLabel: String {
    let modeKey = appState.samplingMode == .active ? "Active" : "Idle"
    let mode = AppLocalization.string(modeKey, language: settings.language)
    let memorySeconds = Int(appState.memorySamplingInterval)
    let processSeconds = Int(appState.processSamplingInterval)
    if memorySeconds == processSeconds {
      return AppLocalization.formatted(
        "%@ (%llds)", language: settings.language, mode, Int64(memorySeconds)
      )
    }
    return AppLocalization.formatted(
      "%@ (%llds, %@ %llds)",
      language: settings.language,
      mode,
      Int64(memorySeconds),
      AppLocalization.string("processes", language: settings.language),
      Int64(processSeconds)
    )
  }

  private var historyAccessibilityValue: String {
    guard let latest = memoryVM.history.last else {
      return AppLocalization.string("No samples", language: settings.language)
    }
    var parts = [
      AppLocalization.formatted(
        "Used %@", language: settings.language, MemoryFormat.size(latest.usedBytes)
      ),
      AppLocalization.formatted(
        "pressure %@",
        language: settings.language,
        AppLocalization.string(latest.pressureLevel.displayName, language: settings.language)
      ),
      AppLocalization.formatted(
        "swap %@", language: settings.language, MemoryFormat.size(latest.swapUsedBytes)
      ),
    ]
    if let total = memoryVM.currentStats?.totalBytes {
      parts[0] = AppLocalization.formatted(
        "Used %@ of %@",
        language: settings.language,
        MemoryFormat.size(latest.usedBytes),
        MemoryFormat.size(total)
      )
    }
    if let selectedUser = processVM.selectedUser,
      let selected = processVM.selectedUserHistory.last
    {
      parts.append(
        AppLocalization.formatted(
          "%@ %@",
          language: settings.language,
          selectedUser,
          MemoryFormat.size(selected.displayBytes)
        )
      )
    }
    parts.append(
      AppLocalization.formatted(
        "%lld samples", language: settings.language, Int64(memoryVM.history.count)
      )
    )
    return parts.joined(separator: ", ")
  }

  /// "Loading…" until the first process sample lands or fails (the error shows below).
  private func listPlaceholder(empty: String) -> String {
    let key = appState.isWaitingForFirstProcessSample ? "Loading…" : empty
    return AppLocalization.string(key, language: settings.language)
  }

  /// Seconds of history visible at once; older samples are reached by scrolling.
  private static let historyVisibleSeconds: TimeInterval = 120

  /// Always at least one visible window wide, so short history grows in from the right.
  private var historyXDomain: ClosedRange<Date> {
    guard let first = memoryVM.history.first?.timestamp,
      let lastMemory = memoryVM.history.last?.timestamp
    else {
      let now = Date()
      return now.addingTimeInterval(-Self.historyVisibleSeconds)...now
    }
    // The selected user's samples come from the process timer and can be newer.
    var last = lastMemory
    if processVM.selectedUser != nil,
      let lastUser = processVM.selectedUserHistory.last?.timestamp
    {
      last = max(last, lastUser)
    }
    return min(first, last.addingTimeInterval(-Self.historyVisibleSeconds))...last
  }

  /// Leading edge of the window that shows the newest sample.
  private var historyLatestScrollPosition: Date {
    historyXDomain.upperBound.addingTimeInterval(-Self.historyVisibleSeconds)
  }

  private func followLatestHistory() {
    historyFollowsLatest = true
    historyScrollPosition = historyLatestScrollPosition
  }

  private var historyScaleUpperBound: Double {
    if let totalBytes = memoryVM.currentStats?.totalBytes, totalBytes > 0 {
      return Double(totalBytes)
    }

    let maxUsed = memoryVM.history.map(\.usedBytes).max() ?? 1
    return Double(maxUsed)
  }

  var body: some View {
    // The header stays outside the scroll view so its buttons are always reachable.
    VStack(spacing: 0) {
      headerSection
        .padding(.horizontal, 16)
        .padding(.vertical, 10)

      Divider()

      ScrollView(.vertical, showsIndicators: true) {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(settings.visibleSections) { section in
            popoverSection(section)
          }
          // The sampling error lives in Top Processes, so it moves here when that section is hidden.
          if !settings.isSectionVisible(.topProcesses) {
            samplingError
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .frame(width: Self.popoverSize.width, height: Self.popoverSize.height)
    .preferredColorScheme(settings.theme.swiftUIColorScheme)
    .environment(\.locale, settings.language.locale)
  }

  @ViewBuilder
  private func popoverSection(_ section: PopoverSection) -> some View {
    switch section {
    case .topUsers:
      DonutSectionView(
        slices: appState.donutSlices,
        stats: memoryVM.currentStats,
        selectedUser: processVM.selectedUser,
        language: settings.language,
        glassBackgroundEnabled: useGlassBackground,
        glassOpacity: settings.glassOpacity,
        onSelectUser: { processVM.selectedUser = $0 }
      )
    case .history:
      historySection
    case .topApps:
      appSection
    case .topProcesses:
      processSection
    }
  }

  private var headerSection: some View {
    HStack {
      Button {
        onOpenActivityMonitor()
      } label: {
        Image(systemName: "waveform.path.ecg")
          .imageScale(.medium)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open Activity Monitor")
      .accessibilityLabel("Open Activity Monitor")

      Spacer()

      Button {
        appState.sampleImmediately()
      } label: {
        Image(systemName: "arrow.clockwise")
          .imageScale(.medium)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Refresh Now")
      .accessibilityLabel("Refresh Now")

      Button {
        onOpenOptionsMenu()
      } label: {
        Image(systemName: "gearshape")
          .imageScale(.medium)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open Options")
      .accessibilityLabel("Open Options")
      .background(
        MenuAnchorView(onResolve: onOptionsMenuAnchorAvailable)
          .allowsHitTesting(false)
      )
    }
    // An overlay keeps the title centered while the sides hold different numbers of buttons.
    .overlay {
      Text("MemStats")
        .font(.title3.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
    }
  }

  private var historySection: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Sampling")
          Spacer()
          Text(modeLabel)
        }
        .font(.footnote)

        if memoryVM.history.isEmpty {
          Text("Loading history data…")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        } else {
          if settings.historyChartStyle == .heatmap {
            historyHeatmap
          } else {
            Chart {
              ForEach(memoryVM.historySegments) { point in
                AreaMark(
                  x: .value("Time", point.timestamp),
                  yStart: .value("Baseline", 0),
                  yEnd: .value("Used RAM", Double(point.usedBytes)),
                  series: .value("Segment", point.segmentID)
                )
                .foregroundStyle(PopoverStyle.pressureColor(point.pressureLevel).opacity(0.18))
                .interpolationMethod(.linear)
              }

              ForEach(memoryVM.historySegments) { point in
                LineMark(
                  x: .value("Time", point.timestamp),
                  y: .value("Used RAM", Double(point.usedBytes)),
                  series: .value("Segment", point.segmentID)
                )
                .foregroundStyle(PopoverStyle.pressureColor(point.pressureLevel))
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.linear)
              }

              // A single sample has no segment yet, so show it as a point.
              if memoryVM.history.count == 1, let sample = memoryVM.history.first {
                PointMark(
                  x: .value("Time", sample.timestamp),
                  y: .value("Used RAM", Double(sample.usedBytes))
                )
                .foregroundStyle(PopoverStyle.pressureColor(sample.pressureLevel))
              }

              if let selectedUser = processVM.selectedUser {
                // Timestamps are unique and monotonic, so they stay stable as old samples drop.
                ForEach(processVM.selectedUserHistory, id: \.timestamp) { sample in
                  LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Selected User", Double(sample.displayBytes)),
                    series: .value("Segment", "selected-user")
                  )
                  .foregroundStyle(PopoverStyle.userColor(selectedUser))
                  .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                  .interpolationMethod(.linear)
                }
              }
            }
            .chartLegend(.hidden)
            .chartYScale(domain: 0...historyScaleUpperBound)
            .chartXScale(domain: historyXDomain)
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: Self.historyVisibleSeconds)
            .chartScrollPosition(x: $historyScrollPosition)
            .chartXAxis {
              AxisMarks(values: .stride(by: .second, count: 30)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute().second())
              }
            }
            .chartYAxis {
              AxisMarks(
                position: .leading,
                values: MemoryFormat.axisTickValues(upperBound: historyScaleUpperBound)
              ) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                  if let bytes = value.as(Double.self) {
                    Text(MemoryFormat.axisTick(bytes))
                  }
                }
              }
            }
            .frame(height: 145)
            // Hundreds of marks are noise for VoiceOver, so read the chart as one summary.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Memory history")
            .accessibilityValue(historyAccessibilityValue)
            .onAppear(perform: followLatestHistory)
            // The popup window is reused, so reopening it switches to active sampling
            // instead of firing onAppear again.
            .onChange(of: appState.samplingMode) {
              if appState.samplingMode == .active {
                followLatestHistory()
              }
            }
            .onChange(of: historyXDomain.upperBound) {
              if historyFollowsLatest {
                historyScrollPosition = historyLatestScrollPosition
              }
            }
            .onChange(of: historyScrollPosition) {
              // Scrolling back pauses following; scrolling to the newest sample resumes it.
              // Capped so slow idle intervals don't turn most of the window into a dead zone.
              let tolerance = min(max(appState.memorySamplingInterval, 2), 5)
              historyFollowsLatest =
                historyScrollPosition >= historyLatestScrollPosition.addingTimeInterval(-tolerance)
            }
          }

          // Items wrap one by one, so adding "Selected" only moves that item to the next row.
          LegendFlowLayout(horizontalSpacing: 10, verticalSpacing: 4) {
            legendItems
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .font(.caption.monospacedDigit())
        }

        // Orange is reserved for the warning pressure level, so hints use the user's color.
        ForEach(appState.growthHints.prefix(2)) { hint in
          HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
              .fill(PopoverStyle.userColor(hint.user))
              .frame(width: 10, height: 10)
            Text(growthHintText(hint))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .font(.caption)
          .help("Possible memory leak hint, based on recent samples")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      // Overlay keeps the button out of the label's layout, like Clear Filter in Top Users.
      Text("\(Text("History")) (\(memoryVM.history.count))")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
          Button(
            AppLocalization.string(
              settings.historyChartStyle == .line ? "Heatmap" : "Line", language: settings.language)
          ) {
            settings.historyChartStyle = settings.historyChartStyle.toggled
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help(AppLocalization.string("Change chart style", language: settings.language))
        }
    }
    .background(
      GlassSurfaceStyle.sectionColor(
        glassEnabled: useGlassBackground,
        opacity: settings.glassOpacity
      )
    )
  }

  private func appTreemapItem(_ app: AppMemoryUsage) -> TreemapItem {
    let processes = AppLocalization.string(
      app.processCount == 1 ? "process" : "processes", language: settings.language)
    return TreemapItem(
      id: app.id,
      name: app.name,
      bytes: app.bytes,
      details: [
        TreemapDetail(text: MemoryFormat.size(app.bytes), priority: 0),
        TreemapDetail(text: "\(app.processCount) \(processes)", priority: 1),
      ],
      change: processVM.change(for: app),
      iconPath: app.path
    )
  }

  /// The user line only shows when the rows come from more than one user.
  private func processTreemapItem(_ process: ProcessSnapshot) -> TreemapItem {
    var details = [
      TreemapDetail(text: "PID \(process.pid)", priority: 1),
      TreemapDetail(text: MemoryFormat.size(process.rssBytes), priority: 0),
    ]
    if Set(processVM.visibleProcesses.map(\.user)).count > 1 {
      details.append(TreemapDetail(text: process.user, priority: 2))
    }
    return TreemapItem(
      id: String(process.pid),
      name: processVM.displayName(for: process),
      bytes: process.rssBytes,
      details: details,
      change: processVM.change(for: process),
      iconPath: processVM.iconPath(for: process)
    )
  }

  private var treemapScale: some View {
    TreemapScale(
      lowerLabel: AppLocalization.string("Lower", language: settings.language),
      higherLabel: AppLocalization.string("Higher", language: settings.language),
      captionLabel: AppLocalization.string("Change since last sample", language: settings.language)
    )
  }

  private var historyHeatmap: some View {
    HistoryHeatmapView(samples: memoryVM.history)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Memory history")
      .accessibilityValue(historyAccessibilityValue)
  }

  private var appSection: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        quitBanner(for: .topApps)

        if processVM.visibleApps.isEmpty {
          Text(listPlaceholder(empty: "No app data available"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          if settings.topAppsStyle == .treemap {
            TopTreemapView(
              items: processVM.visibleApps.map { appTreemapItem($0) },
              language: settings.language,
              tileMenu: { item in
                AnyView(processVM.visibleApps.first { $0.id == item.id }.map { appMenu($0) })
              }
            )
            .overlay(alignment: .bottom) { treemapQuitOverlay(for: .topApps) }
            treemapScale
          } else {
            HStack(spacing: 8) {
              Text("APP")
                .padding(.leading, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
              Text("PROCS")
                .frame(width: 50, alignment: .trailing)
              Text("MEM")
                .frame(width: 64, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ForEach(processVM.visibleApps) { app in
              quitRow(section: .topApps, rowID: MemStatsAppState.quitRowID(for: app)) {
                HStack(spacing: 8) {
                  HStack(spacing: 6) {
                    AppIconView(path: app.path)
                    Text(app.name)
                      .font(.footnote)
                      .lineLimit(1)
                      .truncationMode(.middle)
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .help(app.path ?? app.name)

                  Text(verbatim: String(app.processCount))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)

                  Text(MemoryFormat.size(app.bytes))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                }
                // One VoiceOver element per row, with the column names spoken.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                  AppLocalization.formatted(
                    "%@, %lld %@, %@",
                    language: settings.language,
                    app.name,
                    Int64(app.processCount),
                    AppLocalization.string(
                      app.processCount == 1 ? "process" : "processes",
                      language: settings.language
                    ),
                    MemoryFormat.size(app.bytes)
                  )
                )
                .contextMenu { appMenu(app) }
                .modifier(
                  QuitAccessibilityActions(
                    isAvailable: processVM.quitAvailability(for: app) == .available,
                    language: settings.language
                  ) { appState.requestQuit(app: app, mode: $0) })
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      sectionLabel(
        title: "Top Apps", count: processVM.visibleApps.count, style: $settings.topAppsStyle)
    }
    .background(
      GlassSurfaceStyle.sectionColor(
        glassEnabled: useGlassBackground,
        opacity: settings.glassOpacity
      )
    )
  }

  private var processSection: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        quitBanner(for: .topProcesses)

        if processVM.visibleProcesses.isEmpty {
          Text(listPlaceholder(empty: "No process data available"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          if settings.topProcessesStyle == .treemap {
            TopTreemapView(
              items: processVM.visibleProcesses.map { processTreemapItem($0) },
              language: settings.language,
              tileMenu: { item in
                AnyView(
                  processVM.visibleProcesses.first { String($0.pid) == item.id }
                    .map { processMenu($0) })
              }
            )
            .overlay(alignment: .bottom) { treemapQuitOverlay(for: .topProcesses) }
            treemapScale
          } else {
            HStack(spacing: 8) {
              Text("USER")
                .frame(width: 58, alignment: .leading)
              Text("PID")
                .frame(width: 50, alignment: .leading)
              Text("PROCESS")
                .padding(.leading, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
              Text("MEM")
                .frame(width: 64, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ForEach(processVM.visibleProcesses, id: \.pid) { process in
              quitRow(section: .topProcesses, rowID: MemStatsAppState.quitRowID(for: process)) {
                HStack(spacing: 8) {
                  Text(process.user)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 58, alignment: .leading)
                    .help(process.user)

                  Text(verbatim: String(process.pid))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)

                  HStack(spacing: 6) {
                    AppIconView(path: processVM.iconPath(for: process))
                    Text(processVM.displayName(for: process))
                      .font(.footnote)
                      .lineLimit(1)
                      .truncationMode(.middle)
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .help(process.command)

                  Text(MemoryFormat.size(process.rssBytes))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                  AppLocalization.formatted(
                    "%@, user %@, PID %lld, %@",
                    language: settings.language,
                    processVM.displayName(for: process),
                    process.user,
                    Int64(process.pid),
                    MemoryFormat.size(process.rssBytes)
                  )
                )
                .contextMenu { processMenu(process) }
                .modifier(
                  QuitAccessibilityActions(
                    isAvailable: processVM.quitAvailability(for: process) == .available,
                    language: settings.language
                  ) { appState.requestQuit(process: process, mode: $0) })
              }
            }
          }
        }

        samplingError
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      sectionLabel(
        title: "Top Processes", count: processVM.visibleProcesses.count,
        style: $settings.topProcessesStyle)
    }
    .background(
      GlassSurfaceStyle.sectionColor(
        glassEnabled: useGlassBackground,
        opacity: settings.glassOpacity
      )
    )
  }

  private func appMenu(_ app: AppMemoryUsage) -> some View {
    quitMenu(availability: processVM.quitAvailability(for: app), pid: nil) { mode in
      appState.requestQuit(app: app, mode: mode)
    }
  }

  private func processMenu(_ process: ProcessSnapshot) -> some View {
    quitMenu(availability: processVM.quitAvailability(for: process), pid: process.pid) { mode in
      appState.requestQuit(process: process, mode: mode)
    }
  }

  /// Right-click menu for the list rows and treemap tiles. Quit only opens the confirmation.
  @ViewBuilder
  private func quitMenu(
    availability: ProcessViewModel.QuitAvailability,
    pid: Int32?,
    onQuit: @escaping (ProcessQuitMode) -> Void
  ) -> some View {
    Button(AppLocalization.string("Quit", language: settings.language)) {
      onQuit(.quit)
    }
    .disabled(availability != .available)
    Button(AppLocalization.string("Force Quit", language: settings.language)) {
      onQuit(.forceQuit)
    }
    .disabled(availability != .available)
    // A menu shows text as a disabled item, which explains why Quit is off.
    switch availability {
    case .available:
      EmptyView()
    case .otherUser:
      Text(AppLocalization.string("Belongs to another user", language: settings.language))
    case .protected:
      Text(AppLocalization.string("Protected system process", language: settings.language))
    }
    if let pid {
      Divider()
      Button(AppLocalization.string("Copy PID", language: settings.language)) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(pid), forType: .string)
      }
    }
  }

  /// A list row, or what replaces it while a quit is pending: the confirmation in its place,
  /// a dimmed row while it quits, and a failure below it.
  @ViewBuilder
  private func quitRow<Row: View>(
    section: PopoverSection,
    rowID: String,
    @ViewBuilder row: () -> Row
  ) -> some View {
    if let request = appState.pendingQuit, request.section == section, request.rowID == rowID {
      quitConfirmation(request)
    } else {
      let isQuitting = appState.isQuitting(section: section, rowID: rowID)
      row()
        .opacity(isQuitting ? 0.4 : 1)
        .overlay(alignment: .trailing) {
          if isQuitting {
            quittingLabel(nil)
          }
        }
      if let failure = appState.quitFailure, failure.section == section, failure.rowID == rowID {
        quitFailureView(failure)
      }
    }
  }

  /// Treemap tiles are too small for the confirmation, so it covers the bottom of the map.
  @ViewBuilder
  private func treemapQuitOverlay(for section: PopoverSection) -> some View {
    if let request = appState.pendingQuit, request.section == section {
      quitConfirmation(request)
        .padding(6)
    } else if let failure = appState.quitFailure, failure.section == section {
      quitFailureView(failure)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(6)
    } else if let progress = appState.quitsInProgress.last(where: { $0.section == section }) {
      quittingLabel(progress.name)
        .padding(6)
    }
  }

  /// At the top of the section, for a request or failure whose row is no longer listed, such
  /// as a process that left the top N.
  @ViewBuilder
  private func quitBanner(for section: PopoverSection) -> some View {
    if let request = appState.pendingQuit, request.section == section,
      !showsQuitAtRow(section: section, rowID: request.rowID)
    {
      quitConfirmation(request)
    } else if let failure = appState.quitFailure, failure.section == section,
      !showsQuitAtRow(section: section, rowID: failure.rowID)
    {
      quitFailureView(failure)
    }
  }

  private func showsQuitAtRow(section: PopoverSection, rowID: String) -> Bool {
    switch section {
    case .topApps:
      guard !processVM.visibleApps.isEmpty else { return false }
      return settings.topAppsStyle == .treemap
        || processVM.visibleApps.contains { MemStatsAppState.quitRowID(for: $0) == rowID }
    case .topProcesses:
      guard !processVM.visibleProcesses.isEmpty else { return false }
      return settings.topProcessesStyle == .treemap
        || processVM.visibleProcesses.contains { MemStatsAppState.quitRowID(for: $0) == rowID }
    case .topUsers, .history:
      return false
    }
  }

  /// Inline instead of an alert: the popup closes when a click lands in another window, so an
  /// alert would hide the result. Return confirms, and Esc cancels through the popup window.
  private func quitConfirmation(_ request: MemStatsAppState.QuitRequest) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(quitQuestion(request))
        .font(.footnote.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
      if request.mode == .forceQuit {
        Text(AppLocalization.string("Unsaved changes will be lost.", language: settings.language))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      if request.skipsOtherUsers {
        Text(
          AppLocalization.string(
            "Processes of other users keep running.", language: settings.language)
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button(AppLocalization.string("Cancel", language: settings.language)) {
          appState.cancelQuit()
        }
        Button(
          AppLocalization.string(
            request.mode == .quit ? "Quit" : "Force Quit", language: settings.language),
          role: .destructive
        ) {
          appState.confirmQuit()
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .keyboardShortcut(.defaultAction)
      }
      .controlSize(.small)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    // Opaque enough to read over treemap tiles.
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.1)))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.red.opacity(0.5)))
  }

  private func quitFailureView(_ failure: MemStatsAppState.QuitFailure) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(quitFailureText(failure))
        .font(.footnote)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button {
        appState.dismissQuitFailure()
      } label: {
        Image(systemName: "xmark")
          .imageScale(.small)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(AppLocalization.string("Dismiss", language: settings.language))
      .accessibilityLabel(AppLocalization.string("Dismiss", language: settings.language))
    }
  }

  /// "Quitting…" on a list row, or with the name over a treemap.
  private func quittingLabel(_ name: String?) -> some View {
    HStack(spacing: 4) {
      ProgressView()
        .controlSize(.mini)
      Text(
        name.map {
          AppLocalization.formatted("Quitting “%@”…", language: settings.language, $0)
        } ?? AppLocalization.string("Quitting…", language: settings.language)
      )
      .font(.caption)
      .lineLimit(1)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(.regularMaterial, in: Capsule())
  }

  private func quitQuestion(_ request: MemStatsAppState.QuitRequest) -> String {
    let language = settings.language
    switch (request.mode, request.pid) {
    case (.quit, .some(let pid)):
      return AppLocalization.formatted(
        "Quit “%@” (PID %lld)?", language: language, request.name, Int64(pid))
    case (.forceQuit, .some(let pid)):
      return AppLocalization.formatted(
        "Force Quit “%@” (PID %lld)?", language: language, request.name, Int64(pid))
    case (.quit, nil):
      return AppLocalization.formatted("Quit “%@”?", language: language, request.name)
    case (.forceQuit, nil):
      return AppLocalization.formatted("Force Quit “%@”?", language: language, request.name)
    }
  }

  private func quitFailureText(_ failure: MemStatsAppState.QuitFailure) -> String {
    let language = settings.language
    let error: ProcessTerminationError
    switch failure.reason {
    case .stillRunning:
      return AppLocalization.formatted(
        "“%@” is still running. It may be asking you to save, or use Force Quit.",
        language: language, failure.name)
    case .failed(let reason):
      error = reason
    }
    switch error {
    case .notRunning:
      return AppLocalization.string("The process is no longer running.", language: language)
    case .processChanged:
      return AppLocalization.string(
        "The process changed since the last sample. Nothing was quit.", language: language)
    case .notOwned:
      return AppLocalization.string("You can only quit your own processes.", language: language)
    case .protected:
      return AppLocalization.string(
        "This process is protected and cannot be quit.", language: language)
    case .signalFailed(let code):
      return AppLocalization.formatted(
        "Could not quit the process: %@", language: language, String(cString: strerror(code)))
    }
  }

  @ViewBuilder
  private var samplingError: some View {
    if let lastError = appState.lastSamplingError {
      Text(lastError)
        .font(.footnote)
        .foregroundStyle(.red)
        .lineLimit(2)
    }
  }

  private func growthHintText(_ hint: MemoryGrowthHint) -> String {
    let growth = MemoryFormat.size(hint.growthBytes)
    switch hint.kind {
    case .suddenJump:
      return AppLocalization.formatted(
        "%@ jumped by %@ since the last sample",
        language: settings.language,
        hint.user,
        growth
      )
    case .continuousGrowth(let samples):
      return AppLocalization.formatted(
        "%@ grew by %@ over the last %lld samples",
        language: settings.language,
        hint.user,
        growth,
        Int64(samples)
      )
    }
  }

  /// Single section title that also reflects the active user filter.
  private func sectionLabel(title: String, count: Int, style: Binding<TopListStyle>)
    -> some View
  {
    HStack(spacing: 4) {
      Text("\(Text(LocalizedStringKey(title))) (\(count))")
        .font(.headline)
      if let selectedUser = processVM.selectedUser {
        Text("· \(selectedUser)")
          .font(.headline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
    }
    // Room for the style button, which sits on top so the header height stays the same.
    .padding(.trailing, 76)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .trailing) {
      Button(
        AppLocalization.string(
          style.wrappedValue == .list ? "Treemap" : "List", language: settings.language)
      ) {
        style.wrappedValue = style.wrappedValue.toggled
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .help(AppLocalization.string("Change chart style", language: settings.language))
    }
  }

  @ViewBuilder
  private var legendItems: some View {
    if let latestSample = memoryVM.history.last {
      legendItem(
        color: PopoverStyle.pressureColor(latestSample.pressureLevel),
        label: AppLocalization.formatted(
          "Used %@", language: settings.language, MemoryFormat.size(latestSample.usedBytes)
        )
      )
      legendItem(
        color: Color(nsColor: .systemGray),
        label: AppLocalization.formatted(
          "Swap %@", language: settings.language, MemoryFormat.size(latestSample.swapUsedBytes)
        )
      )
      pressureBadge(level: latestSample.pressureLevel)
    }
    if settings.historyChartStyle == .heatmap {
      HistoryHeatmapScale(
        lessLabel: AppLocalization.string("Less", language: settings.language),
        moreLabel: AppLocalization.string("More", language: settings.language)
      )
    }
    if settings.historyChartStyle == .line, let selectedUser = processVM.selectedUser {
      // Same color as the user's donut slice, so the dashed line is easy to match.
      legendItem(
        color: PopoverStyle.userColor(selectedUser),
        label: AppLocalization.string("Selected", language: settings.language)
      )
    }
  }

  private func legendItem(color: Color, label: String) -> some View {
    HStack(spacing: 4) {
      RoundedRectangle(cornerRadius: 2)
        .fill(color)
        .frame(width: 10, height: 10)
      Text(label)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }
  }

  @ViewBuilder
  private func pressureBadge(level: MemoryPressureLevel) -> some View {
    HStack(spacing: 4) {
      RoundedRectangle(cornerRadius: 2)
        .fill(PopoverStyle.pressureColor(level))
        .frame(width: 10, height: 10)
      Text(
        AppLocalization.formatted(
          "Pressure %@",
          language: settings.language,
          AppLocalization.string(level.displayName, language: settings.language)
        )
      )
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .fixedSize()
    }
  }
}

/// VoiceOver cannot reach the context menu of a row read as one element, so Quit and Force
/// Quit are offered as its actions too.
private struct QuitAccessibilityActions: ViewModifier {
  let isAvailable: Bool
  let language: AppLanguage
  let onQuit: (ProcessQuitMode) -> Void

  func body(content: Content) -> some View {
    if isAvailable {
      content
        .accessibilityAction(named: AppLocalization.string("Quit", language: language)) {
          onQuit(.quit)
        }
        .accessibilityAction(named: AppLocalization.string("Force Quit", language: language)) {
          onQuit(.forceQuit)
        }
    } else {
      content
    }
  }
}

private struct MenuAnchorView: NSViewRepresentable {
  let onResolve: (NSView) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.alphaValue = 0
    DispatchQueue.main.async {
      onResolve(view)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    onResolve(nsView)
  }
}

/// Lays out subviews left to right and starts a new row when the next one does not fit.
private struct LegendFlowLayout: Layout {
  var horizontalSpacing: CGFloat
  var verticalSpacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrangeRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
    let height =
      rows.map(\.height).reduce(0, +)
      + verticalSpacing * CGFloat(max(rows.count - 1, 0))
    // Report the proposed width when there is one, so placeSubviews wraps against the same width.
    if let proposedWidth = proposal.width, proposedWidth.isFinite {
      return CGSize(width: proposedWidth, height: height)
    }
    return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let rows = arrangeRows(maxWidth: bounds.width, subviews: subviews)
    var y = bounds.minY
    for row in rows {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(
          at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
          proposal: ProposedViewSize(size)
        )
        x += size.width + horizontalSpacing
      }
      y += row.height + verticalSpacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrangeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      if !current.indices.isEmpty, current.width + horizontalSpacing + size.width > maxWidth {
        rows.append(current)
        current = Row()
      }
      current.width += (current.indices.isEmpty ? 0 : horizontalSpacing) + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty {
      rows.append(current)
    }
    return rows
  }
}
