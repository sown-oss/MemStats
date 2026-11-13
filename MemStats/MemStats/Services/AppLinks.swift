import Foundation

/// GitHub links for the project: releases (updates) and issues (bug reports).
nonisolated enum AppLinks {
  static let owner = "sown-oss"
  static let repository = "MemStats"

  static let repositoryURL = URL(string: "https://github.com/\(owner)/\(repository)")!
  static let releasesURL = repositoryURL.appendingPathComponent("releases")
  /// GitHub redirects this to the newest published release.
  static let latestReleaseURL = releasesURL.appendingPathComponent("latest")
  static let sponsorURL = repositoryURL.appendingPathComponent("")

  /// The app's own version, e.g. "1.0.0", and build number, e.g. "1".
  static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }

  static var appBuild: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
  }

  /// The issue form in `.github/ISSUE_TEMPLATE`, and the id of its Environment field.
  static let bugReportTemplate = "bug_report.yml"
  static let bugReportEnvironmentField = "environment"

  /// The bug report form with Environment filled in, so the reporter only describes the problem.
  /// `language` is the app language setting, and `settings` a short summary of the settings
  /// that change sampling or the popover.
  static func bugReportURL(
    appVersion: String = appVersion,
    appBuild: String = appBuild,
    osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
    model: String = hardwareModel(),
    architecture: String = architecture,
    language: String = "System",
    preferredLanguages: [String] = Locale.preferredLanguages,
    settings: String? = nil
  ) -> URL {
    let systemLanguages =
      preferredLanguages.isEmpty ? "unknown" : preferredLanguages.prefix(3).joined(separator: ", ")
    var environment = [
      "- MemStats: \(appVersion) (\(appBuild))",
      "- macOS: \(osVersion)",
      "- Mac: \(model) (\(architecture))",
      "- Language: \(language) (macOS: \(systemLanguages))",
    ]
    if let settings {
      environment.append("- Settings: \(settings)")
    }

    var components = URLComponents(
      url: repositoryURL.appendingPathComponent("issues/new"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "template", value: bugReportTemplate),
      URLQueryItem(name: "title", value: "[Bug] "),
      URLQueryItem(name: "labels", value: "bug"),
      URLQueryItem(name: bugReportEnvironmentField, value: environment.joined(separator: "\n")),
    ]
    // URLComponents leaves "+" as is, and GitHub would read it as a space.
    components.percentEncodedQuery = components.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    return components.url!
  }

  static var architecture: String {
    #if arch(arm64)
      return "arm64"
    #else
      return "x86_64"
    #endif
  }

  /// Model identifier such as "Mac15,6", or "Unknown".
  static func hardwareModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Unknown" }
    return String(cString: buffer)
  }
}
