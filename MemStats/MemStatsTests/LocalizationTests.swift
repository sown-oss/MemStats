import Foundation
import Testing

@testable import MemStats

struct LocalizationTests {
  private static let formatPattern =
    #"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA%])"#

  /// Each argument's conversion keyed by its position in the argument list, so a translation
  /// that moves an argument without `%n$` no longer matches its key. `%%` is skipped.
  private static func formatArguments(_ format: String) throws -> [Int: String] {
    let regex = try NSRegularExpression(pattern: formatPattern)
    let text = format as NSString
    var arguments: [Int: String] = [:]
    var nextPosition = 1
    for match in regex.matches(in: format, range: NSRange(location: 0, length: text.length)) {
      let conversion = text.substring(with: match.range(at: 3))
      guard conversion != "%" else { continue }
      let lengthRange = match.range(at: 2)
      let length = lengthRange.location == NSNotFound ? "" : text.substring(with: lengthRange)
      let positionRange = match.range(at: 1)
      let position: Int
      if positionRange.location == NSNotFound {
        position = nextPosition
        nextPosition += 1
      } else {
        position = Int(text.substring(with: positionRange)) ?? 0
      }
      arguments[position] = length + conversion
    }
    return arguments
  }

  /// `String(format:)` crashes when a translation hands an integer to `%@`.
  @Test func translationsKeepEachArgumentInPlace() throws {
    for language in AppLanguage.allCases where language != .system {
      let path = try #require(
        Bundle.main.path(forResource: language.locale.identifier, ofType: "lproj"),
        "\(language.locale.identifier).lproj is missing"
      )
      let bundle = try #require(Bundle(path: path))
      let tablePath = try #require(bundle.path(forResource: "Localizable", ofType: "strings"))
      let strings = try #require(NSDictionary(contentsOfFile: tablePath) as? [String: String])
      #expect(!strings.isEmpty)
      for (key, value) in strings where key.contains("%") {
        #expect(
          try Self.formatArguments(value) == Self.formatArguments(key),
          "\(language.locale.identifier): \(key) -> \(value)"
        )
      }
    }
  }

  @Test func reorderedTranslationNeedsArgumentPositions() throws {
    let key = "%@ grew by %@ over the last %lld samples"
    let expected = try Self.formatArguments(key)
    #expect(try Self.formatArguments("在最近 %lld 个样本中 %@ 增加了 %@") != expected)
    #expect(try Self.formatArguments("在最近 %3$lld 个样本中 %1$@ 增加了 %2$@") == expected)
    #expect(try Self.formatArguments("Memory %lld%%, pressure %@") == [1: "lld", 2: "@"])
  }

  /// System is skipped: its locale can format the count with non-Latin digits.
  @Test func growthHintFormatsInEveryLanguage() {
    for language in AppLanguage.allCases where language != .system {
      let text = AppLocalization.formatted(
        "%@ grew by %@ over the last %lld samples",
        language: language,
        "email",
        "1.20 GB",
        Int64(7)
      )
      #expect(text.contains("email"), "\(language.rawValue): \(text)")
      #expect(text.contains("1.20 GB"), "\(language.rawValue): \(text)")
      #expect(text.contains("7"), "\(language.rawValue): \(text)")
    }
  }
}
