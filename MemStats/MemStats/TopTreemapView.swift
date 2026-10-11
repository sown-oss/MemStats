import SwiftUI

/// Treemap for Top Apps and Top Processes: tile size is memory, color is the change since the
/// previous sample (red higher, green lower, gray unchanged or new).
struct TopTreemapView: View {
  static let height: CGFloat = 200
  static let tileGap: CGFloat = 1
  static let cornerRadius: CGFloat = 3

  let items: [TreemapItem]
  let language: AppLanguage

  static func fillColor(tone: Int) -> Color {
    let strength = Double(min(abs(tone), TreemapItem.maximumTone)) / Double(TreemapItem.maximumTone)
    if tone > 0 {
      return Color.red.opacity(0.35 + 0.65 * strength)
    }
    if tone < 0 {
      return Color.green.opacity(0.35 + 0.65 * strength)
    }
    return Color.gray.opacity(0.3)
  }

  /// Dark text on green and light tints, white only on the strongest red.
  static func textColor(tone: Int) -> Color {
    tone == TreemapItem.maximumTone ? .white : .primary
  }

  var body: some View {
    GeometryReader { proxy in
      TreemapTiles(items: items, size: proxy.size, language: language)
    }
    .frame(height: Self.height)
  }
}

/// Separate view so colors resolve on the main actor, outside the GeometryReader closure.
private struct TreemapTiles: View {
  let items: [TreemapItem]
  let size: CGSize
  let language: AppLanguage

  var body: some View {
    let rects = TreemapLayout.layout(
      values: items.map { Double($0.bytes) },
      in: CGRect(origin: .zero, size: size)
    )
    // A real layout, not `.offset`: tooltips and hit testing follow the layout frame, so each
    // tile only reacts inside its own rect.
    TreemapFrameLayout(
      rects: rects.map {
        $0.insetBy(dx: TopTreemapView.tileGap, dy: TopTreemapView.tileGap)
      }
    ) {
      ForEach(items) { item in
        tile(item)
      }
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
  }

  private func tile(_ item: TreemapItem) -> some View {
    GeometryReader { proxy in
      TreemapTile(item: item, size: proxy.size)
    }
  }
}

private struct TreemapTile: View {
  let item: TreemapItem
  let size: CGSize

  var body: some View {
    let tone = item.tone
    let summary = ([item.name] + item.details.map(\.text)).joined(separator: ", ")
    // Whole lines only, so small tiles drop the least important ones instead of clipping.
    let lineCount = Int((size.height - 6) / Self.lineHeight)
    let details = item.visibleDetails(lineCount: lineCount - 1)
    ZStack {
      RoundedRectangle(cornerRadius: TopTreemapView.cornerRadius)
        .fill(TopTreemapView.fillColor(tone: tone))
      if size.width >= 36, lineCount >= 1 {
        VStack(spacing: 1) {
          HStack(spacing: 3) {
            if size.width >= 60 {
              AppIconView(path: item.iconPath, size: 13)
            }
            Text(item.name)
              .font(.caption.weight(.semibold))
              .lineLimit(1)
              .truncationMode(.middle)
          }
          ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
            Text(verbatim: detail.text)
              .font(.caption2.monospacedDigit())
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        .foregroundStyle(TopTreemapView.textColor(tone: tone))
        .padding(.horizontal, 3)
      } else if min(size.width, size.height) >= 20 {
        // Too small for text: the icon still says which app it is.
        AppIconView(path: item.iconPath, size: min(16, min(size.width, size.height) - 4))
      }
    }
    .frame(width: size.width, height: size.height)
    .contentShape(Rectangle())
    .help(summary)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(summary)
  }

  private static let lineHeight: CGFloat = 13
}

/// Places subview `i` at `rects[i]`, so every tile has its own frame.
private struct TreemapFrameLayout: Layout {
  let rects: [CGRect]

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for (index, subview) in subviews.enumerated() {
      let rect = index < rects.count ? rects[index] : .zero
      subview.place(
        at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: max(rect.width, 0), height: max(rect.height, 0))
      )
    }
  }
}

/// "Lower ... Higher" key under the treemap.
struct TreemapScale: View {
  let lowerLabel: String
  let higherLabel: String
  let captionLabel: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 3) {
        Text(lowerLabel)
          .foregroundStyle(.secondary)
          .padding(.trailing, 1)
        ForEach(-TreemapItem.maximumTone...TreemapItem.maximumTone, id: \.self) { tone in
          RoundedRectangle(cornerRadius: 2.5)
            .fill(TopTreemapView.fillColor(tone: tone))
            .frame(width: 10, height: 10)
        }
        Text(higherLabel)
          .foregroundStyle(.secondary)
          .padding(.leading, 1)
      }
      Text(captionLabel)
        .foregroundStyle(.tertiary)
    }
    .font(.caption)
    .accessibilityHidden(true)
  }
}
