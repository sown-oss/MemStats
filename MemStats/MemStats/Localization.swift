import Foundation

enum AppLocalization {
  static func string(_ key: String, language: AppLanguage) -> String {
    guard let bundle = bundle(for: language) else { return key }
    return bundle.localizedString(forKey: key, value: key, table: nil)
  }

  static func formatted(
    _ key: String,
    language: AppLanguage,
    _ arguments: CVarArg...
  ) -> String {
    String(
      format: string(key, language: language),
      locale: language.locale,
      arguments: arguments
    )
  }

  /// `String(localized:locale:)` only formats with the locale and still looks strings up in the
  /// system language, so a chosen language reads from its own `.lproj` folder instead.
  private static let languageBundles: [AppLanguage: Bundle] = Dictionary(
    uniqueKeysWithValues: AppLanguage.allCases.compactMap { language in
      guard language != .system,
        let path = Bundle.main.path(forResource: language.locale.identifier, ofType: "lproj"),
        let bundle = Bundle(path: path)
      else { return nil }
      return (language, bundle)
    })

  /// `nil` means the keys are shown as they are: English is the source language, so it has no
  /// `.lproj` folder.
  private static func bundle(for language: AppLanguage) -> Bundle? {
    language == .system ? .main : languageBundles[language]
  }
}
