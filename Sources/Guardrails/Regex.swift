// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Duenne Huelle um `NSRegularExpression`.
///
/// Swift-5.7-Ziel: keine Regex-Literale, keine `Regex<Output>`-API. Foundation
/// ist auf macOS und Linux identisch verfuegbar — deshalb hier und nicht per
/// Plattform-Gate.
enum Regex {

    /// Ob ein Muster ueberhaupt uebersetzbar ist.
    ///
    /// Gibt es, damit betreiber-gelieferte Muster **beim Laden der Policy**
    /// geprueft werden koennen statt erst beim ersten Ausgang. Ein unuebersetz-
    /// bares Muster trifft nie — bei einer verbotenen Formulierung heisst das:
    /// sie ist nicht verboten, und niemand erfaehrt davon.
    public static func isValid(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }

    /// Alle Volltreffer eines Musters.
    static func matches(_ pattern: String, in text: String,
                        options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = compile(pattern, options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// Ob das Muster mindestens einmal trifft.
    static func hasMatch(_ pattern: String, in text: String,
                         options: NSRegularExpression.Options = []) -> Bool {
        guard let regex = compile(pattern, options) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    /// Uebersetzte Muster, damit nicht bei jedem Ausgang alles neu gebaut wird.
    ///
    /// Die Stufen pruefen mit rund fuenfzig festen Mustern pro Anfrage; ohne
    /// diesen Zwischenspeicher wurde jedes einzelne davon jedes Mal neu
    /// uebersetzt. `NSRegularExpression` ist nach dem Bauen unveraenderlich und
    /// darf geteilt werden — der Deckel liegt nur um den Aufbau.
    ///
    /// Ein Sperre statt eines Actors, weil die Stufen bewusst synchron sind:
    /// „kein Netz, kein Zustand, keine I/O" heisst auch, dass `inspect` nicht
    /// `await` verlangen darf.
    private static let cacheLock = NSLock()
    private static var cache: [String: NSRegularExpression] = [:]

    /// Uebersetzt und meldet Fehlschlaege laut, statt sie zu verschlucken.
    ///
    /// Zwei Herkuenfte, zwei Umgangsweisen:
    ///
    /// - **Muster im Code** sind Programmierfehler. `assertionFailure` macht sie
    ///   im Test und im Debug-Build sofort sichtbar; im Release faellt die Stufe
    ///   auf „kein Treffer" zurueck, weil ein Absturz der Pruefschicht schlimmer
    ///   waere als eine fehlende Regel. `RegexCatalogTests` uebersetzt jedes
    ///   eingebaute Muster, damit es dazu gar nicht erst kommt.
    /// - **Muster aus der Policy-Datei** gehoeren hier nicht mehr hin: sie
    ///   werden in `CompliancePolicy.validate()` beim Laden geprueft, und eine
    ///   kaputte Datei fuehrt zum Abbruch statt zu einer stillen Luecke.
    private static func compile(_ pattern: String,
                                _ options: NSRegularExpression.Options) -> NSRegularExpression? {
        // Die Optionen gehoeren in den Schluessel: dasselbe Muster einmal mit
        // und einmal ohne `.caseInsensitive` sind zwei verschiedene Ausdruecke.
        let key = "\(options.rawValue)\u{0}\(pattern)"

        cacheLock.lock()
        let cached = cache[key]
        cacheLock.unlock()
        if let cached { return cached }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            assertionFailure("Nicht uebersetzbares Regex-Muster: \(pattern)")
            return nil
        }

        cacheLock.lock()
        cache[key] = regex
        cacheLock.unlock()
        return regex
    }
}
