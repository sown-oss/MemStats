import Foundation

/// A section of the popover below the header. Users can hide and reorder them in Settings.
enum PopoverSection: String, CaseIterable, Equatable, Identifiable {
  case topUsers
  case history
  case topApps
  case topProcesses

  static let defaultOrder: [PopoverSection] = allCases

  var id: Self { self }

  var displayName: String {
    switch self {
    case .topUsers:
      return "Top Users"
    case .history:
      return "History"
    case .topApps:
      return "Top Apps"
    case .topProcesses:
      return "Top Processes"
    }
  }

  /// Drops unknown and repeated values, then appends missing sections in default order, so a
  /// stored order from an older or newer version still lists every section once.
  static func normalizedOrder(_ rawValues: [String]) -> [PopoverSection] {
    var order: [PopoverSection] = []
    for rawValue in rawValues {
      if let section = PopoverSection(rawValue: rawValue), !order.contains(section) {
        order.append(section)
      }
    }
    order.append(contentsOf: defaultOrder.filter { !order.contains($0) })
    return order
  }

  /// Drops unknown values. Hiding every section would leave an empty popover, so that shows all.
  static func normalizedHidden(_ rawValues: [String]) -> Set<PopoverSection> {
    let hidden = Set(rawValues.compactMap(PopoverSection.init(rawValue:)))
    return hidden.count == allCases.count ? [] : hidden
  }
}
