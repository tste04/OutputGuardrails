// Copyright (c) 2026 Tommy Stellmacher
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE.md).

import Foundation

/// Duenne Huelle um `NSRegularExpression`.
///
/// Swift-5.7-Ziel: keine Regex-Literale, keine `Regex<Output>`-API. Foundation
/// ist auf macOS und Linux identisch verfuegbar — deshalb hier und nicht per
/// Plattform-Gate.
enum Regex {

    /// Alle Volltreffer eines Musters.
    static func matches(_ pattern: String, in text: String,
                        options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// Ob das Muster mindestens einmal trifft.
    static func hasMatch(_ pattern: String, in text: String,
                         options: NSRegularExpression.Options = []) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
