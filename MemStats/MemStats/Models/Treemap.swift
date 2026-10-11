import CoreGraphics
import Foundation

/// One line of text under a tile's name. Lower `priority` survives longer when the tile is small.
nonisolated struct TreemapDetail: Equatable, Sendable {
  let text: String
  let priority: Int
}

/// One treemap tile: size is the memory, color is the change since the previous sample.
nonisolated struct TreemapItem: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let bytes: UInt64
  /// Extra lines in display order (PID, memory, user, ...).
  let details: [TreemapDetail]
  /// Fractional change since the previous sample (0.05 = +5%). `nil` when there is no earlier
  /// sample for this item, for example a process that just started.
  let change: Double?

  /// Changes smaller than this read as "no change", since RSS wobbles a little every sample.
  static let neutralThreshold = 0.005
  static let maximumTone = 3

  /// -3...3. Negative is lower memory, positive is higher, 0 is unchanged or unknown.
  var tone: Int {
    guard let change, change.isFinite, abs(change) >= Self.neutralThreshold else { return 0 }
    let magnitude: Int
    switch abs(change) {
    case ..<0.02: magnitude = 1
    case ..<0.05: magnitude = 2
    default: magnitude = 3
    }
    return change < 0 ? -magnitude : magnitude
  }

  /// Details that fit in `lineCount` lines, dropping the lowest priority first and keeping
  /// the display order.
  func visibleDetails(lineCount: Int) -> [TreemapDetail] {
    guard lineCount > 0 else { return [] }
    let kept = details.enumerated()
      .sorted { $0.element.priority < $1.element.priority }
      .prefix(lineCount)
      .sorted { $0.offset < $1.offset }
    return kept.map(\.element)
  }
}

/// Squarified treemap layout (Bruls, Huizing, van Wijk): keeps tiles close to square.
nonisolated enum TreemapLayout {
  /// One rect per value, in the same order. A value of 0 or less gets an empty rect.
  static func layout(values: [Double], in rect: CGRect) -> [CGRect] {
    // Largest first gives the best shapes, and keeps zeros last whatever the input order.
    let order = values.indices.sorted { values[$0] > values[$1] }
    let sortedRects = squarify(values: order.map { values[$0] }, in: rect)
    var result = [CGRect](repeating: .zero, count: values.count)
    for (position, index) in order.enumerated() {
      result[index] = sortedRects[position]
    }
    return result
  }

  /// `values` must be sorted largest first.
  private static func squarify(values: [Double], in rect: CGRect) -> [CGRect] {
    var result = [CGRect](repeating: .zero, count: values.count)
    let total = values.reduce(0) { $0 + max($1, 0) }
    guard total > 0, rect.width > 0, rect.height > 0 else { return result }

    let area = Double(rect.width) * Double(rect.height)
    let areas = values.map { max($0, 0) / total * area }
    var remaining = rect
    var start = 0

    while start < areas.count, areas[start] > 0 {
      let side = Double(min(remaining.width, remaining.height))
      guard side > 0 else { break }

      var end = start + 1
      var rowSum = areas[start]
      var best = worstRatio(areas[start..<end], sum: rowSum, side: side)
      while end < areas.count, areas[end] > 0 {
        let nextSum = rowSum + areas[end]
        let candidate = worstRatio(areas[start...end], sum: nextSum, side: side)
        if candidate > best { break }
        best = candidate
        rowSum = nextSum
        end += 1
      }

      if remaining.width >= remaining.height {
        // Column on the left, items stacked top to bottom.
        let thickness = CGFloat(rowSum) / remaining.height
        var y = remaining.minY
        for index in start..<end {
          let height = CGFloat(areas[index]) / thickness
          result[index] = CGRect(x: remaining.minX, y: y, width: thickness, height: height)
          y += height
        }
        remaining = CGRect(
          x: remaining.minX + thickness, y: remaining.minY,
          width: max(remaining.width - thickness, 0), height: remaining.height)
      } else {
        // Row on top, items side by side.
        let thickness = CGFloat(rowSum) / remaining.width
        var x = remaining.minX
        for index in start..<end {
          let width = CGFloat(areas[index]) / thickness
          result[index] = CGRect(x: x, y: remaining.minY, width: width, height: thickness)
          x += width
        }
        remaining = CGRect(
          x: remaining.minX, y: remaining.minY + thickness,
          width: remaining.width, height: max(remaining.height - thickness, 0))
      }
      start = end
    }
    return result
  }

  /// Worst aspect ratio in a row laid along a side of length `side`.
  private static func worstRatio(_ row: ArraySlice<Double>, sum: Double, side: Double) -> Double {
    guard let low = row.min(), let high = row.max(), low > 0 else { return .infinity }
    let squared = side * side
    return max(squared * high / (sum * sum), (sum * sum) / (squared * low))
  }
}
