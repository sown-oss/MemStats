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
          DonutSectionView(
            slices: appState.donutSlices,
            stats: memoryVM.currentStats,
            selectedUser: processVM.selectedUser,
            language: settings.language,
            glassBackgroundEnabled: useGlassBackground,
            glassOpacity: settings.glassOpacity,
            onSelectUser: { processVM.selectedUser = $0 }
          )
          historySection
          appSection
          processSection
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .frame(width: Self.popoverSize.width, height: Self.popoverSize.height)
    .preferredColorScheme(settings.theme.swiftUIColorScheme)
    .environment(\.locale, settings.language.locale)
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

      Text("MemStats")
        .font(.title3.weight(.semibold))

      Spacer()

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
        if processVM.visibleApps.isEmpty {
          Text(listPlaceholder(empty: "No app data available"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          if settings.topAppsStyle == .treemap {
            TopTreemapView(
              items: processVM.visibleApps.map { appTreemapItem($0) },
              language: settings.language
            )
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
        if processVM.visibleProcesses.isEmpty {
          Text(listPlaceholder(empty: "No process data available"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          if settings.topProcessesStyle == .treemap {
            TopTreemapView(
              items: processVM.visibleProcesses.map { processTreemapItem($0) },
              language: settings.language
            )
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
            }
          }
        }

        if let lastError = appState.lastSamplingError {
          Text(lastError)
            .font(.footnote)
            .foregroundStyle(.red)
            .lineLimit(2)
        }

        Button("Refresh Now") {
          appState.sampleImmediately()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
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
