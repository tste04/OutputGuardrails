// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Gewicht eines Befunds. Aufsteigend: was hoeher steht, wiegt schwerer.
///
/// String-basiert, weil Schweregrade in der Policy-Datei stehen und dort
/// `"violation"` lesbar ist, `2` aber nicht. Die Ordnung haengt deshalb an
/// `rank`, nicht am Rohwert.
public enum Severity: String, Codable, Sendable, Comparable, CaseIterable {
    /// Beobachtung ohne Handlungsbedarf (z. B. Anzahl der Belege).
    case info
    /// Auffaellig, aber nicht zwingend falsch (z. B. unbelegte Zahl).
    case warning
    /// Regelbruch (z. B. PII im Ausgang, Schema verletzt, kein Beleg).
    case violation

    private var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .violation: return 2
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

/// Ein einzelner Befund einer Pruefstufe.
///
/// Traegt nur die Regel-ID und die Fundstelle — Schweregrad und Gewicht kommen
/// aus dem `RuleCatalog`, damit eine Stufe nicht nebenbei Politik macht.
///
/// `evidence` ist bewusst die *Fundstelle im Ausgang* und nicht der ganze Text:
/// Befunde wandern in Logs und Audit — sie duerfen den geprueften Inhalt nicht
/// erneut ausbreiten. Bei PII und Zugangsdaten steht dort nur die maskierte Form.
public struct Finding: Sendable, Equatable, Codable {
    /// Name der Pruefstufe, die den Befund erzeugt hat (`GuardrailCheck.name`).
    public let check: String
    /// Stabile Regel-ID. Suppressions und Audit binden hieran.
    public let rule: RuleID
    /// Menschlich lesbare Erklaerung zum konkreten Fund.
    public let message: String
    /// Fundstelle — niemals der volle gepruefte Text.
    public let evidence: String?

    public init(check: String, rule: RuleID, message: String, evidence: String? = nil) {
        self.check = check
        self.rule = rule
        self.message = message
        self.evidence = evidence
    }

    /// Katalogeintrag der Regel (fail-closed bei unbekannter ID).
    public var catalogEntry: Rule { RuleCatalog.resolve(rule) }
    public var severity: Severity { catalogEntry.severity }
    public var category: GuardrailCategory { catalogEntry.category }
    public var weight: Double { catalogEntry.weight }
}
