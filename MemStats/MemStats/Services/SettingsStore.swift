import Combine
import Foundation

/// User settings for sampling and list sizes, persisted in `UserDefaults`. Every change applies
/// right away, and a stored value outside the allowed options falls back to its default.
final class SettingsStore: ObservableObject {
  static let memoryIntervalOptions = [1, 2, 3, 5, 10, 15, 30, 60]
  /// `top` takes about 1.4s per run, so processes are never sampled faster than every 3s.
  static let processIntervalOptions = [3, 5, 10, 15, 30, 60]
  static let rowCountOptions = [5, 8, 10, 15, 20]

  static let defaultMemoryInterval = 5
  static let defaultProcessInterval = 5
  static let defaultRowCount = 8
  static let defaultTheme: AppTheme = .system
  static let defaultLanguage: AppLanguage = .system
  static let defaultHistoryChartStyle: HistoryChartStyle = .line
  static let defaultTopListStyle: TopListStyle = .list
  static let defaultGlassBackground = false
  static let defaultGlassOpacity = 0.52
  static let minimumGlassOpacity = 0.0
  static let maximumGlassOpacity = 1.0

  static let memoryIntervalKey = "memoryIntervalSeconds"
  static let processIntervalKey = "processIntervalSeconds"
  static let topAppsCountKey = "topAppsCount"
  static let topProcessesCountKey = "topProcessesCount"
  static let themeKey = "theme"
  static let languageKey = "language"
  static let historyChartStyleKey = "historyChartStyle"
  static let topAppsStyleKey = "topAppsStyle"
  static let topProcessesStyleKey = "topProcessesStyle"
  static let glassBackgroundKey = "glassBackground"
  static let glassOpacityKey = "glassOpacity"
  static let sectionOrderKey = "sectionOrder"
  static let hiddenSectionsKey = "hiddenSections"

  /// Seconds between memory samples (RAM, pressure, swap, menu bar, history).
  @Published var memoryInterval: Int {
    didSet {
      store(
        \.memoryInterval, key: Self.memoryIntervalKey, options: Self.memoryIntervalOptions,
        fallback: Self.defaultMemoryInterval)
    }
  }

  /// Seconds between process samples (`top`).
  @Published var processInterval: Int {
    didSet {
      store(
        \.processInterval, key: Self.processIntervalKey, options: Self.processIntervalOptions,
        fallback: Self.defaultProcessInterval)
    }
  }

  @Published var topAppsCount: Int {
    didSet {
      store(
        \.topAppsCount, key: Self.topAppsCountKey, options: Self.rowCountOptions,
        fallback: Self.defaultRowCount)
    }
  }

  @Published var topProcessesCount: Int {
    didSet {
      store(
        \.topProcessesCount, key: Self.topProcessesCountKey, options: Self.rowCountOptions,
        fallback: Self.defaultRowCount)
    }
  }

  @Published var theme: AppTheme {
    didSet {
      defaults.set(theme.rawValue, forKey: Self.themeKey)
    }
  }

  @Published var language: AppLanguage {
    didSet {
      defaults.set(language.rawValue, forKey: Self.languageKey)
    }
  }

  @Published var historyChartStyle: HistoryChartStyle {
    didSet {
      defaults.set(historyChartStyle.rawValue, forKey: Self.historyChartStyleKey)
    }
  }

  @Published var topAppsStyle: TopListStyle {
    didSet {
      defaults.set(topAppsStyle.rawValue, forKey: Self.topAppsStyleKey)
    }
  }

  @Published var topProcessesStyle: TopListStyle {
    didSet {
      defaults.set(topProcessesStyle.rawValue, forKey: Self.topProcessesStyleKey)
    }
  }

  @Published var glassBackground: Bool {
    didSet {
      defaults.set(glassBackground, forKey: Self.glassBackgroundKey)
    }
  }

  @Published var glassOpacity: Double {
    didSet {
      let clamped =
        glassOpacity.isFinite
        ? min(max(glassOpacity, Self.minimumGlassOpacity), Self.maximumGlassOpacity)
        : Self.defaultGlassOpacity
      guard glassOpacity == clamped else {
        glassOpacity = clamped
        return
      }
      defaults.set(clamped, forKey: Self.glassOpacityKey)
    }
  }

  /// Every section once, in popover order, including hidden ones.
  @Published private(set) var sectionOrder: [PopoverSection] {
    didSet {
      defaults.set(sectionOrder.map(\.rawValue), forKey: Self.sectionOrderKey)
    }
  }

  /// Never holds every section, so the popover always shows at least one.
  @Published private(set) var hiddenSections: Set<PopoverSection> {
    didSet {
      // Sorted by popover order so the stored array does not churn between launches.
      let rawValues = sectionOrder.filter(hiddenSections.contains).map(\.rawValue)
      defaults.set(rawValues, forKey: Self.hiddenSectionsKey)
    }
  }

  var visibleSections: [PopoverSection] {
    sectionOrder.filter { !hiddenSections.contains($0) }
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    memoryInterval = Self.read(
      Self.memoryIntervalKey, from: defaults, options: Self.memoryIntervalOptions,
      fallback: Self.defaultMemoryInterval)
    processInterval = Self.read(
      Self.processIntervalKey, from: defaults, options: Self.processIntervalOptions,
      fallback: Self.defaultProcessInterval)
    topAppsCount = Self.read(
      Self.topAppsCountKey, from: defaults, options: Self.rowCountOptions,
      fallback: Self.defaultRowCount)
    topProcessesCount = Self.read(
      Self.topProcessesCountKey, from: defaults, options: Self.rowCountOptions,
      fallback: Self.defaultRowCount)
    theme = Self.readTheme(from: defaults)
    language = Self.readLanguage(from: defaults)
    historyChartStyle = Self.readHistoryChartStyle(from: defaults)
    topAppsStyle = Self.readTopListStyle(Self.topAppsStyleKey, from: defaults)
    topProcessesStyle = Self.readTopListStyle(Self.topProcessesStyleKey, from: defaults)
    glassBackground = Self.readGlassBackground(from: defaults)
    glassOpacity = Self.readGlassOpacity(from: defaults)
    sectionOrder = PopoverSection.normalizedOrder(
      defaults.stringArray(forKey: Self.sectionOrderKey) ?? [])
    hiddenSections = PopoverSection.normalizedHidden(
      defaults.stringArray(forKey: Self.hiddenSectionsKey) ?? [])
  }

  func isSectionVisible(_ section: PopoverSection) -> Bool {
    !hiddenSections.contains(section)
  }

  /// Hiding the last visible section is ignored, so the popover never ends up empty.
  func setSection(_ section: PopoverSection, visible: Bool) {
    if visible {
      hiddenSections.remove(section)
    } else if visibleSections != [section] {
      hiddenSections.insert(section)
    }
  }

  func canMoveSection(_ section: PopoverSection, by offset: Int) -> Bool {
    guard let index = sectionOrder.firstIndex(of: section) else { return false }
    return sectionOrder.indices.contains(index + offset)
  }

  /// Swaps the section with its neighbor; `offset` is -1 for up and 1 for down.
  func moveSection(_ section: PopoverSection, by offset: Int) {
    guard canMoveSection(section, by: offset),
      let index = sectionOrder.firstIndex(of: section)
    else { return }
    sectionOrder.swapAt(index, index + offset)
  }

  var isDefaultSectionLayout: Bool {
    sectionOrder == PopoverSection.defaultOrder && hiddenSections.isEmpty
  }

  func resetSectionLayout() {
    sectionOrder = PopoverSection.defaultOrder
    hiddenSections = []
  }

  private static func readTheme(from defaults: UserDefaults) -> AppTheme {
    guard let rawValue = defaults.string(forKey: themeKey),
      let theme = AppTheme(rawValue: rawValue)
    else {
      return defaultTheme
    }
    return theme
  }

  private static func readLanguage(from defaults: UserDefaults) -> AppLanguage {
    guard let rawValue = defaults.string(forKey: languageKey),
      let language = AppLanguage(rawValue: rawValue)
    else {
      return defaultLanguage
    }
    return language
  }

  private static func readHistoryChartStyle(from defaults: UserDefaults) -> HistoryChartStyle {
    guard let rawValue = defaults.string(forKey: historyChartStyleKey),
      let style = HistoryChartStyle(rawValue: rawValue)
    else {
      return defaultHistoryChartStyle
    }
    return style
  }

  private static func readTopListStyle(_ key: String, from defaults: UserDefaults) -> TopListStyle {
    guard let rawValue = defaults.string(forKey: key),
      let style = TopListStyle(rawValue: rawValue)
    else {
      return defaultTopListStyle
    }
    return style
  }

  private static func readGlassBackground(from defaults: UserDefaults) -> Bool {
    (defaults.object(forKey: glassBackgroundKey) as? Bool) ?? defaultGlassBackground
  }

  private static func readGlassOpacity(from defaults: UserDefaults) -> Double {
    guard let number = defaults.object(forKey: glassOpacityKey) as? NSNumber else {
      return defaultGlassOpacity
    }
    let value = number.doubleValue
    guard value.isFinite, (minimumGlassOpacity...maximumGlassOpacity).contains(value) else {
      return defaultGlassOpacity
    }
    return value
  }

  private static func read(
    _ key: String,
    from defaults: UserDefaults,
    options: [Int],
    fallback: Int
  ) -> Int {
    guard let value = defaults.object(forKey: key) as? Int, options.contains(value) else {
      return fallback
    }
    return value
  }

  private func store(
    _ keyPath: ReferenceWritableKeyPath<SettingsStore, Int>,
    key: String,
    options: [Int],
    fallback: Int
  ) {
    let value = self[keyPath: keyPath]
    guard options.contains(value) else {
      // Setting the fallback runs `didSet` again, which then stores it.
      self[keyPath: keyPath] = fallback
      return
    }
    defaults.set(value, forKey: key)
  }
}
