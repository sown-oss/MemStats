import Foundation

/// How the History section draws memory samples.
enum HistoryChartStyle: String, CaseIterable, Equatable, Identifiable {
  case line
  case heatmap

  var id: Self { self }

  var displayName: String {
    switch self {
    case .line:
      return "Line"
    case .heatmap:
      return "Heatmap"
    }
  }

  var toggled: HistoryChartStyle {
    self == .line ? .heatmap : .line
  }
}

/// One heatmap square: how full RAM was, and the pressure level at that sample.
nonisolated struct HistoryHeatmapCell: Equatable, Sendable {
  /// 1...levelCount, higher means more RAM used compared with the rest of the window.
  let level: Int
  let pressureLevel: MemoryPressureLevel
}

/// Lays samples out like a GitHub contribution graph: columns fill top to bottom, the newest
/// sample sits in the last column, and missing slots at the start stay empty.
nonisolated enum HistoryHeatmap {
  static let rows = 7
  static let levelCount = 4

  /// `columns * rows` slots, column-major. `nil` marks a slot without a sample.
  static func cells(
    from samples: [MemoryHistorySample],
    columns: Int
  ) -> [HistoryHeatmapCell?] {
    let capacity = max(columns, 0) * rows
    guard capacity > 0 else { return [] }

    let visible = Array(samples.suffix(capacity))
    let low = visible.map(\.usedBytes).min() ?? 0
    let high = visible.map(\.usedBytes).max() ?? 0
    let padding = capacity - visible.count

    // Few columns of real data would otherwise start at the first slot, so pad at the front:
    // the newest sample always ends the last column's data.
    var cells = [HistoryHeatmapCell?](repeating: nil, count: capacity)
    for (offset, sample) in visible.enumerated() {
      cells[padding + offset] = HistoryHeatmapCell(
        level: level(for: sample.usedBytes, low: low, high: high),
        pressureLevel: sample.pressureLevel
      )
    }
    return cells
  }

  /// Splits the window's own range into equal steps, so a flat window reads as one mid level
  /// instead of looking full or empty.
  static func level(for bytes: UInt64, low: UInt64, high: UInt64) -> Int {
    guard high > low else { return (levelCount + 1) / 2 }
    let fraction = Double(bytes - low) / Double(high - low)
    return min(levelCount, Int(fraction * Double(levelCount)) + 1)
  }
}
