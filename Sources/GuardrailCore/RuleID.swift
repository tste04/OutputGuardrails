// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

// MARK: - Stabile Regel-Identitaet
//
// Jeder Befund traegt eine ID, die sich NIE aendert. Prosa-Texte sind
// Anzeige-Material und duerfen umformuliert werden; Suppressions, Audit-Regeln,
// Dashboards und die Risk-based-Approval-Stufe binden ausschliesslich an die ID.
//
// Dieselbe Konvention wie im AIGateway — und fuer dieselben Muster bewusst
// dieselben IDs: ein privater Schluessel ist am Eingang wie am Ausgang
// `SEC-001`. Wer beide Bausteine in ein Audit zusammenfuehrt, soll dieselbe
// Regel wiedererkennen.

/// Stabiler Bezeichner einer Pruefregel, z. B. `GRO-001`.
///
/// Wird als blanker String serialisiert (`"GRO-001"`), nicht als Objekt.
public struct RuleID: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Fachliche Einordnung eines Befunds. Entspricht den Punkten der Zielbild-Box.
public enum GuardrailCategory: String, Sendable, Codable, CaseIterable {
    /// Belegpflicht und Nachpruefung — „Grounding & Citation Check".
    case grounding
    /// Personenbezogene Daten im Ausgang.
    case pii
    /// Zugangsdaten im Ausgang — Teil von „Security".
    case secret
    /// Abflusskanaele und Echo eingeschleuster Anweisungen — Teil von „Security".
    case exfiltration
    /// Richtlinien der Organisation — „Compliance".
    case compliance
    /// Strukturzusage verletzt — „Schema Validation".
    case schema
    /// Widerspruch zu bekannten Fakten.
    case consistency
    /// Betrieb der Pruefkette selbst (uebersprungene Stufe, Fehler).
    case operational
}

/// Ein Eintrag im Regelkatalog.
///
/// Traegt Gewicht und Schweregrad — beides ist Sache der Regel, nicht der Stufe,
/// die sie ausloest. Genau deshalb kann die Policy Schwellen aendern, ohne dass
/// eine Erkennungsstufe angefasst wird.
public struct Rule: Sendable, Equatable, Codable {
    public let id: RuleID
    public let category: GuardrailCategory
    public let severity: Severity
    /// Beitrag zum Risikowert (0…1). Info-Regeln tragen 0.
    public let weight: Double
    /// Anzeigetext. Darf umformuliert werden, ohne dass etwas bricht.
    public let title: String

    public init(id: RuleID, category: GuardrailCategory, severity: Severity,
                weight: Double, title: String) {
        self.id = id
        self.category = category
        self.severity = severity
        self.weight = weight
        self.title = title
    }
}
