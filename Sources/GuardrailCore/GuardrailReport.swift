// Copyright (c) 2026 Tommy Stellmacher
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE.md).

import Foundation

/// Was mit dem geprueften Ausgang geschehen soll.
public enum Verdict: String, Codable, Sendable {
    /// Unauffaellig — Ausgang darf so raus.
    case allow
    /// Auffaellig, aber nicht blockierend — Ausgang raus, Befunde mitliefern.
    case flag
    /// Regelbruch — Ausgang darf so nicht raus.
    case block
}

/// Ab welchem Gewicht ein Befund blockt bzw. markiert.
public struct GuardrailPolicy: Sendable, Equatable, Codable {
    /// Befunde ab diesem Gewicht fuehren zu `.block`.
    public var blockAt: Severity
    /// Befunde ab diesem Gewicht fuehren zu `.flag`.
    public var flagAt: Severity
    /// Wenn eine LLM-Stufe nicht laufen konnte: als Befund vermerken (`true`)
    /// oder still uebergehen (`false`). Default `true` — eine uebersprungene
    /// Pruefung ist kein bestandener Test.
    public var reportSkippedChecks: Bool

    public init(blockAt: Severity = .violation, flagAt: Severity = .warning,
                reportSkippedChecks: Bool = true) {
        self.blockAt = blockAt
        self.flagAt = flagAt
        self.reportSkippedChecks = reportSkippedChecks
    }

    /// Blockt bei Regelbruch, markiert bei Warnung.
    public static let standard = GuardrailPolicy()

    /// Blockt schon bei Warnungen — fuer Ausgaenge, die ohne Mensch weitergehen
    /// (Auto-Execute im Zielbild).
    public static let strict = GuardrailPolicy(blockAt: .warning, flagAt: .info)

    /// Blockt nie, meldet nur. Fuer Beobachtungsbetrieb beim Einfuehren.
    public static let observeOnly = GuardrailPolicy(blockAt: .violation, flagAt: .info,
                                                    reportSkippedChecks: true)
}

/// Gesamtergebnis eines Guardrail-Durchlaufs.
public struct GuardrailReport: Sendable, Equatable {
    public let verdict: Verdict
    public let findings: [Finding]
    /// Belege, die der Ausgang mitfuehren muss (Belegpflicht).
    public let citations: [Citation]
    /// Namen der Stufen, die nicht laufen konnten (z. B. kein LLM bereit).
    public let skippedChecks: [String]

    public init(verdict: Verdict, findings: [Finding],
                citations: [Citation] = [], skippedChecks: [String] = []) {
        self.verdict = verdict
        self.findings = findings
        self.citations = citations
        self.skippedChecks = skippedChecks
    }

    /// Schwerster Befund im Bericht.
    public var highestSeverity: Severity? {
        findings.map(\.severity).max()
    }

    public var isBlocked: Bool { verdict == .block }

    /// Befunde einer bestimmten Stufe.
    public func findings(from check: String) -> [Finding] {
        findings.filter { $0.check == check }
    }

    /// Kurzfassung fuer Logs und Audit — enthaelt bewusst keinen Ausgangstext,
    /// nur Codes und Gewichte.
    public var auditLine: String {
        let codes = findings.map { "\($0.check)/\($0.code):\($0.severity)" }
        let skipped = skippedChecks.isEmpty ? "" : " skipped=[\(skippedChecks.joined(separator: ","))]"
        return "verdict=\(verdict.rawValue) citations=\(citations.count) findings=[\(codes.joined(separator: " "))]\(skipped)"
    }

    /// Leitet aus Befunden und Politik das Urteil ab.
    public static func verdict(for findings: [Finding], policy: GuardrailPolicy) -> Verdict {
        guard let worst = findings.map(\.severity).max() else { return .allow }
        if worst >= policy.blockAt { return .block }
        if worst >= policy.flagAt { return .flag }
        return .allow
    }
}
