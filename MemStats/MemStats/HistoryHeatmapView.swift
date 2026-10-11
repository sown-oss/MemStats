import SwiftUI

/// GitHub-style grid of memory samples. Green intensity shows how much RAM was used compared
/// with the rest of the window; warning and critical samples keep their pressure color.
struct HistoryHeatmapView: View {
  static let cellSize: CGFloat = 11
  static let cellSpacing: CGFloat = 3
  static let cornerRadius: CGFloat = 2.5

  static var gridHeight: CGFloat {
    CGFloat(HistoryHeatmap.rows) * cellSize + CGFloat(HistoryHeatmap.rows - 1) * cellSpacing
  }

  let samples: [MemoryHistorySample]

  static func columnCount(for width: CGFloat) -> Int {
    guard width > 0 else { return 0 }
    return max(Int((width + cellSpacing) / (cellSize + cellSpacing)), 0)
  }

  /// Level 1 is the lightest. Pressure colors replace green only above normal.
  static func color(for cell: HistoryHeatmapCell) -> Color {
    switch cell.pressureLevel {
    case .warning, .critical:
      return PopoverStyle.pressureColor(cell.pressureLevel)
    default:
      return levelColor(cell.level)
    }
  }

  static func levelColor(_ level: Int) -> Color {
    let step = Double(min(max(level, 1), HistoryHeatmap.levelCount))
    return Color.green.opacity(0.2 + 0.8 * step / Double(HistoryHeatmap.levelCount))
  }

  static let emptyColor = Color.primary.opacity(0.08)

  var body: some View {
    GeometryReader { proxy in
      HistoryHeatmapGrid(samples: samples, width: proxy.size.width)
    }
    .frame(height: Self.gridHeight)
  }
}

/// Separate view so colors resolve on the main actor, outside the GeometryReader closure.
private struct HistoryHeatmapGrid: View {
  let samples: [MemoryHistorySample]
  let width: CGFloat

  /// Resolved before drawing because the Canvas closure is not main actor isolated.
  private func slotColors(columns: Int) -> [Color] {
    var colors: [Color] = []
    for cell in HistoryHeatmap.cells(from: samples, columns: columns) {
      colors.append(cell.map { HistoryHeatmapView.color(for: $0) } ?? HistoryHeatmapView.emptyColor)
    }
    return colors
  }

  var body: some View {
    let columns = HistoryHeatmapView.columnCount(for: width)
    let colors = slotColors(columns: columns)
    Canvas { context, size in
      let cell = HistoryHeatmapView.cellSize
      let step = cell + HistoryHeatmapView.cellSpacing
      // Right aligned like the grid it is modeled on, so new samples enter from the right.
      let usedWidth = CGFloat(columns) * step - HistoryHeatmapView.cellSpacing
      let originX = max(size.width - usedWidth, 0)
      for (index, color) in colors.enumerated() {
        let rect = CGRect(
          x: originX + CGFloat(index / HistoryHeatmap.rows) * step,
          y: CGFloat(index % HistoryHeatmap.rows) * step,
          width: cell,
          height: cell
        )
        context.fill(
          Path(roundedRect: rect, cornerRadius: HistoryHeatmapView.cornerRadius),
          with: .color(color)
        )
      }
    }
  }
}

/// "Less ... More" key under the grid.
struct HistoryHeatmapScale: View {
  let lessLabel: String
  let moreLabel: String

  var body: some View {
    HStack(spacing: 3) {
      Text(lessLabel)
        .foregroundStyle(.secondary)
        .padding(.trailing, 1)
      // Warning and critical samples sit at the top of the scale, after the green levels.
      ForEach(Array(scaleColors.enumerated()), id: \.offset) { _, color in
        RoundedRectangle(cornerRadius: HistoryHeatmapView.cornerRadius)
          .fill(color)
          .frame(width: 10, height: 10)
      }
      Text(moreLabel)
        .foregroundStyle(.secondary)
        .padding(.leading, 1)
    }
    .accessibilityHidden(true)
  }

  private var scaleColors: [Color] {
    (1...HistoryHeatmap.levelCount).map { HistoryHeatmapView.levelColor($0) }
      + [PopoverStyle.pressureColor(.warning), PopoverStyle.pressureColor(.critical)]
  }
}
