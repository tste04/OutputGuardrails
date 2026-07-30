// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import GuardrailCore

// MARK: - PII im Ausgang
//
// Die Ausgangsseite der PII-Pruefung. Die Eingangsseite (Maskierung mit
// Round-Trip vor dem Modell) liegt im AIGateway; hier geht es nur darum, dass
// nichts Personenbezogenes den Weg nach draussen findet — auch dann nicht, wenn
// das Modell es aus dem Kontext wieder ausgepackt hat.
//
// Die Erkennungs-Semantik ist an die Konformanz-Vektoren des Zielbild-Repos
// gebunden (`conformance/pii-vectors.txt`), damit Gateway und Guardrails nicht
// auseinanderdriften. Vektoren liegen als Testressource im Repo.

public enum PIICategory: String, Codable, Sendable, CaseIterable {
    case mail
    case phone
    case iban
    case address
    case person

    /// Die Katalogregel dieser Kategorie. Gewicht und Schweregrad stehen im
    /// `RuleCatalog`, nicht hier — die Stufe erkennt, die Policy entscheidet.
    public var rule: RuleID {
        switch self {
        case .mail: return RuleCatalog.piiMail
        case .phone: return RuleCatalog.piiPhone
        case .iban: return RuleCatalog.piiIBAN
        case .address: return RuleCatalog.piiAddress
        case .person: return RuleCatalog.piiPerson
        }
    }
}

/// Ein Fund im Ausgang. `value` bleibt im Prozess — in Befunde wandert nur die
/// maskierte Form.
public struct PIIMatch: Sendable, Equatable {
    public let category: PIICategory
    public let value: String

    /// `ma***@example.com` statt Klarwert: genug zum Wiederfinden, zu wenig zum
    /// Weitertragen.
    public var masked: String {
        switch category {
        case .mail:
            guard let at = value.firstIndex(of: "@") else { return PIIMatch.stars(value) }
            let local = String(value[value.startIndex..<at])
            return PIIMatch.stars(local) + String(value[at...])
        default:
            return PIIMatch.stars(value)
        }
    }

    static func stars(_ text: String) -> String {
        guard text.count > 2 else { return "***" }
        return text.prefix(2) + String(repeating: "*", count: max(3, text.count - 2))
    }
}

/// Findet Personenbezug im Modell-Ausgang.
public struct PIICheck: GuardrailCheck {
    public let name = "pii"

    /// Wie streng eine grossgeschriebene Wortkette als Person gilt.
    public enum PersonDetection: String, Codable, Sendable, CaseIterable {
        /// Eine Kette gilt nur mit Anker (Anrede, Titel, Label, bekannter
        /// Vorname). Voreinstellung — im Deutschen die einzige brauchbare
        /// Variante, weil Substantive grossgeschrieben werden.
        case anchored
        /// Jede Kette aus zwei grossgeschriebenen Woertern gilt als Person.
        /// Maximale Trefferquote, sehr viele Fehlalarme in deutschem Text —
        /// nur fuer englischsprachige Ausgaenge oder Hoechstschutz-Betrieb.
        case anyCapitalizedChain
    }

    /// Welche Kategorien geprueft werden.
    public let categories: Set<PIICategory>
    /// Zusaetzliche Begriffe, die als Personenbezug gelten (Betreiber-Denylist).
    public let denylist: [String]
    /// Strenge der Namensketten-Erkennung.
    public let personDetection: PersonDetection
    /// Vornamen des Betreibers (z. B. aus dem Mitarbeiterverzeichnis), die als
    /// Anker zaehlen. Gross-/Kleinschreibung egal.
    public let additionalFirstNames: Set<String>

    public init(categories: Set<PIICategory> = Set(PIICategory.allCases),
                denylist: [String] = [],
                personDetection: PersonDetection = .anchored,
                additionalFirstNames: [String] = []) {
        self.categories = categories
        self.denylist = denylist
        self.personDetection = personDetection
        self.additionalFirstNames = Set(additionalFirstNames.map { $0.lowercased() })
    }

    // MARK: - Muster
    //
    // Bewusst eng gefasst: ein Fehlalarm blockiert eine korrekte Antwort, deshalb
    // brauchen Telefon und Adresse strukturelle Anker (Vorwahl-Praefix, Strassen-
    // Suffix + Hausnummer) statt „viele Ziffern".

    private static let patterns: [(PIICategory, String)] = [
        (.mail, "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"),
        // IBAN: Laenderkennung + Pruefziffern + 11–30 alphanumerische Zeichen.
        (.iban, "\\b[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\\b"),
        // Telefon: braucht '+' oder eine fuehrende 0 — sonst treffen IP-Adressen,
        // Belegnummern und Betraege mit.
        (.phone, "(?:\\+|\\b0)[0-9][0-9 ()/-]{6,}[0-9]"),
        // Strasse + Hausnummer.
        (.address, "\\b\\p{Lu}[\\p{L}.-]{2,}(?:stra(?:ß|ss)e|str\\.|weg|platz|allee|gasse|ring|damm)\\s+\\d{1,4}[a-zA-Z]?\\b"),
        // PLZ + Ort.
        (.address, "\\b\\d{5}\\s+\\p{Lu}\\p{L}+"),
    ]

    /// Namensketten: jedes Wort ein Grossbuchstabe gefolgt von Kleinbuchstaben.
    /// Das schliesst Abkuerzungen und Codes aus („Beleg ORD" ist kein Mensch).
    /// Ueber den Anker in `GermanText.anchoredPersonName` wird daraus ein
    /// Personen-Fund — die Kette allein ist im Deutschen kein Namenssignal.
    private static let nameChainPattern = "\\p{Lu}\\p{Ll}+(?: \\p{Lu}\\p{Ll}+)+"

    /// Anrede, Titel oder Label mit nur EINEM folgenden Wort („Herr Schmidt",
    /// „Ansprechpartner: Weber"). Die Kette oben verlangt zwei Woerter und
    /// wuerde den Fall verfehlen; der Anker traegt ihn allein.
    /// Der Anker-Teil wiederholt sich, damit „Frau Dr. Meier" nicht nach dem
    /// ersten Titel abbricht und den Namen verliert.
    private static let titledNamePattern =
        "\\b(?:(?:Herrn?|Frau|Hr\\.|Fr\\.|Dr\\.|Prof\\.|Mr\\.|Mrs\\.|Ms\\."
        + "|Name|Vorname|Nachname|Kontakt|Absender|Empf(?:ae|ä)nger|Ansprechpartner"
        + "|Sachbearbeiter|Betreuer|Verfasser|Autor|gez\\.)"
        + ":?\\s+)+\\p{Lu}\\p{Ll}+"

    // MARK: - Erkennung

    public func detect(in text: String) -> [PIIMatch] {
        var found: [PIIMatch] = []
        var seen = Set<String>()

        for (category, pattern) in Self.patterns where categories.contains(category) {
            for value in Regex.matches(pattern, in: text) {
                let key = "\(category.rawValue)|\(value)"
                guard seen.insert(key).inserted else { continue }
                found.append(PIIMatch(category: category, value: value))
            }
        }

        if categories.contains(.person) {
            for value in Regex.matches(Self.titledNamePattern, in: text) {
                guard let chain = GermanText.anchoredPersonName(
                    value, extraFirstNames: additionalFirstNames) else { continue }
                let key = "person|\(chain)"
                guard seen.insert(key).inserted else { continue }
                found.append(PIIMatch(category: .person, value: chain))
            }
            for value in Regex.matches(Self.nameChainPattern, in: text) {
                let chain: String?
                switch personDetection {
                case .anchored:
                    chain = GermanText.anchoredPersonName(
                        value, extraFirstNames: additionalFirstNames)
                case .anyCapitalizedChain:
                    chain = GermanText.strippedNameChain(value)
                }
                guard let chain = chain else { continue }
                let key = "person|\(chain)"
                guard seen.insert(key).inserted else { continue }
                found.append(PIIMatch(category: .person, value: chain))
            }
        }

        for term in denylist where !term.isEmpty {
            guard text.range(of: term, options: .caseInsensitive) != nil else { continue }
            let key = "person|\(term)"
            guard seen.insert(key).inserted else { continue }
            found.append(PIIMatch(category: .person, value: term))
        }
        return found
    }

    /// Ersetzt gefundene Werte durch `[Kategorie-n]`-Platzhalter. Ohne Rueckweg —
    /// der Round-Trip gehoert auf die Eingangsseite (AIGateway), hier wird nur
    /// entschaerft.
    public func redact(_ text: String) -> String {
        var result = text
        var counters: [PIICategory: Int] = [:]
        // Laengste zuerst, sonst zerschneidet eine Teilmaskierung den laengeren Fund.
        for match in detect(in: text).sorted(by: { $0.value.count > $1.value.count }) {
            let index = (counters[match.category] ?? 0) + 1
            counters[match.category] = index
            result = result.replacingOccurrences(
                of: match.value, with: "[\(match.category.rawValue.capitalized)-\(index)]")
        }
        return result
    }

    // MARK: - Pruefung

    public func inspect(_ context: OutputContext) -> [Finding] {
        detect(in: context.output).map { match in
            Finding(check: name, rule: match.category.rule,
                    message: "Personenbezug im Ausgang (\(match.category.rawValue)) — nicht ungeschuetzt ausliefern.",
                    evidence: match.masked)
        }
    }
}
