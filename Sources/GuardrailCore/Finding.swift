// Copyright (c) 2026 Tommy Stellmacher
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE.md).

import Foundation

/// Gewicht eines Befunds. Aufsteigend: was hoeher steht, wiegt schwerer.
public enum Severity: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Beobachtung ohne Handlungsbedarf (z. B. Anzahl der Belege).
    case info = 0
    /// Auffaellig, aber nicht zwingend falsch (z. B. unbelegte Zahl).
    case warning = 1
    /// Regelbruch (z. B. PII im Ausgang, Schema verletzt, kein Beleg).
    case violation = 2

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Ein einzelner Befund einer Pruefstufe.
///
/// `evidence` ist bewusst die *Fundstelle im Ausgang* und nicht der ganze Text:
/// Befunde wandern in Logs und Audit — sie duerfen den geprueften Inhalt nicht
/// erneut ausbreiten. Bei PII steht dort die Kategorie, nie der Klarwert.
public struct Finding: Sendable, Equatable, Codable {
    /// Name der Pruefstufe, die den Befund erzeugt hat (`GuardrailCheck.name`).
    public let check: String
    public let severity: Severity
    /// Maschinenlesbarer Code, stabil ueber Formulierungsaenderungen hinweg.
    public let code: String
    /// Menschlich lesbare Erklaerung.
    public let message: String
    /// Fundstelle/Beleg — niemals der volle gepruefte Text, bei PII nur die Kategorie.
    public let evidence: String?

    public init(check: String, severity: Severity, code: String,
                message: String, evidence: String? = nil) {
        self.check = check
        self.severity = severity
        self.code = code
        self.message = message
        self.evidence = evidence
    }
}
