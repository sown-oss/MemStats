import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// App icons for the Top Apps and Top Processes rows. Looked up by bundle or executable path and
/// cached, since the lists redraw on every sample.
@MainActor
enum AppIconProvider {
  private static let cache = NSCache<NSString, NSImage>()
  private static let genericKey = "generic-executable" as NSString

  /// The icon at `path`, or a generic executable icon when the path is unknown.
  static func icon(forPath path: String?) -> NSImage {
    let key = path.map { $0 as NSString } ?? genericKey
    if let cached = cache.object(forKey: key) {
      return cached
    }
    let image =
      path.map { NSWorkspace.shared.icon(forFile: $0) }
      ?? NSWorkspace.shared.icon(for: .unixExecutable)
    cache.setObject(image, forKey: key)
    return image
  }
}

/// Decorative icon: the row text already names the app, so VoiceOver skips it.
struct AppIconView: View {
  let path: String?
  var size: CGFloat = 16

  var body: some View {
    Image(nsImage: AppIconProvider.icon(forPath: path))
      .resizable()
      .interpolation(.high)
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}
