// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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

/// Ab welchem Gewicht ein Befund blockt bzw. markiert — und was davon eine
/// menschliche Freigabe braucht.
///
/// Die Stufen erkennen, die Policy entscheidet. Schwellen muessen aenderbar
/// sein, ohne eine Erkennungsregel anzufassen; genau das macht den Feedback-Loop
/// des Zielbilds moeglich (Eval-Daten tunen die Guardrails, nicht den Code).
public struct GuardrailPolicy: Sendable, Equatable, Codable {
    /// Befunde ab diesem Gewicht fuehren zu `.block`.
    public var blockAt: Severity
    /// Befunde ab diesem Gewicht fuehren zu `.flag`.
    public var flagAt: Severity
    /// Wenn eine LLM-Stufe nicht laufen konnte: als Befund vermerken (`true`)
    /// oder still uebergehen (`false`). Default `true` — eine uebersprungene
    /// Pruefung ist kein bestandener Test.
    public var reportSkippedChecks: Bool
    /// Ab diesem Risikowert verlangt der Bericht eine menschliche Freigabe,
    /// auch wenn kein einzelner Befund blockt. Bedient „High Risk → Human
    /// Approval" im Zielbild.
    public var approvalThreshold: Double
    /// Regeln, die nicht ins Urteil eingehen. Sie bleiben im Bericht sichtbar
    /// (unter `suppressed`) — unterdrueckt heisst nicht unsichtbar.
    public var suppressedRules: Set<RuleID>
    /// Ob diese Politik ueberhaupt blocken darf. `false` deckelt das Urteil bei
    /// `.flag` — der Beobachtungsbetrieb braucht das, weil `Severity` keinen
    /// Wert oberhalb von `.violation` kennt und `blockAt` deshalb nie so hoch
    /// gesetzt werden kann, dass nichts mehr blockt.
    public var blocksOutput: Bool

    public init(blockAt: Severity = .violation, flagAt: Severity = .warning,
                reportSkippedChecks: Bool = true, approvalThreshold: Double = 0.30,
                suppressedRules: Set<RuleID> = [], blocksOutput: Bool = true) {
        self.blockAt = blockAt
        self.flagAt = flagAt
        self.reportSkippedChecks = reportSkippedChecks
        self.approvalThreshold = approvalThreshold
        self.suppressedRules = suppressedRules
        self.blocksOutput = blocksOutput
    }

    /// Jedes Feld ist optional: wer nur `approvalThreshold` aendern will, soll
    /// nicht die ganze Politik abschreiben muessen. Nicht genannte Felder
    /// behalten die Voreinstellung.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = GuardrailPolicy()
        blockAt = try c.decodeIfPresent(Severity.self, forKey: .blockAt) ?? fallback.blockAt
        flagAt = try c.decodeIfPresent(Severity.self, forKey: .flagAt) ?? fallback.flagAt
        reportSkippedChecks = try c.decodeIfPresent(Bool.self, forKey: .reportSkippedChecks)
            ?? fallback.reportSkippedChecks
        approvalThreshold = try c.decodeIfPresent(Double.self, forKey: .approvalThreshold)
            ?? fallback.approvalThreshold
        suppressedRules = try c.decodeIfPresent(Set<RuleID>.self, forKey: .suppressedRules)
            ?? fallback.suppressedRules
        blocksOutput = try c.decodeIfPresent(Bool.self, forKey: .blocksOutput)
            ?? fallback.blocksOutput
    }

    /// Blockt bei Regelbruch, markiert bei Warnung.
    public static let standard = GuardrailPolicy()

    /// Blockt schon bei Warnungen — fuer Ausgaenge, die ohne Mensch weitergehen
    /// (Auto-Execute im Zielbild).
    public static let strict = GuardrailPolicy(blockAt: .warning, flagAt: .info,
                                               approvalThreshold: 0.10)

    /// Blockt nie, meldet nur. Fuer Beobachtungsbetrieb beim Einfuehren.
    ///
    /// `blocksOutput: false` ist der Kern der Zusage — ohne das blockte diese
    /// Politik jeden Regelbruch wie `.standard`, und genau dafuer wird sie
    /// eingesetzt: um die Guardrails scharfzuschalten, ohne den Betrieb
    /// anzuhalten. `approvalThreshold: 1.01` haelt zusaetzlich das
    /// Freigabe-Flag unten, damit die Beobachtung nichts anhaelt.
    public static let observeOnly = GuardrailPolicy(blockAt: .violation, flagAt: .info,
                                                    approvalThreshold: 1.01,
                                                    blocksOutput: false)
}

/// Gesamtergebnis eines Guardrail-Durchlaufs.
public struct GuardrailReport: Sendable, Equatable {
    public let verdict: Verdict
    /// Befunde, die ins Urteil eingegangen sind.
    public let findings: [Finding]
    /// Befunde unterdrueckter Regeln — sichtbar, aber ohne Wirkung.
    public let suppressed: [Finding]
    /// Belege, die der Ausgang mitfuehren muss (Belegpflicht).
    public let citations: [Citation]
    /// Namen der Stufen, die nicht laufen konnten (z. B. kein LLM bereit).
    public let skippedChecks: [String]
    /// Aufsummiertes Regelgewicht, gedeckelt auf 1.0. Signal fuer die
    /// Risk-based-Approval-Stufe dahinter.
    public let riskScore: Double
    /// `true`, wenn der Ausgang eine menschliche Freigabe braucht.
    public let requiresApproval: Bool

    public init(verdict: Verdict, findings: [Finding], suppressed: [Finding] = [],
                citations: [Citation] = [], skippedChecks: [String] = [],
                riskScore: Double = 0, requiresApproval: Bool = false) {
        self.verdict = verdict
        self.findings = findings
        self.suppressed = suppressed
        self.citations = citations
        self.skippedChecks = skippedChecks
        self.riskScore = riskScore
        self.requiresApproval = requiresApproval
    }

    /// Baut den Bericht aus Befunden und Politik — der einzige vorgesehene Weg,
    /// damit Urteil, Risiko und Freigabe-Flag nie auseinanderlaufen.
    public static func make(findings: [Finding], policy: GuardrailPolicy,
                            citations: [Citation] = [], skippedChecks: [String] = []) -> GuardrailReport {
        let suppressed = findings.filter { policy.suppressedRules.contains($0.rule) }
        let effective = findings.filter { !policy.suppressedRules.contains($0.rule) }
        let verdict = self.verdict(for: effective, policy: policy)
        let risk = riskScore(for: effective)
        // Ein geblockter Ausgang geht gar nicht erst weiter — Freigabe ist die
        // Frage fuer alles, was durchkommt.
        let needsApproval = verdict != .block && (verdict == .flag || risk >= policy.approvalThreshold)
        return GuardrailReport(verdict: verdict, findings: effective, suppressed: suppressed,
                               citations: citations, skippedChecks: skippedChecks,
                               riskScore: risk, requiresApproval: needsApproval)
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

    /// Befunde einer Kategorie.
    public func findings(in category: GuardrailCategory) -> [Finding] {
        findings.filter { $0.category == category }
    }

    /// Kurzfassung fuer Logs und Audit — enthaelt bewusst keinen Ausgangstext,
    /// nur Regel-IDs, Risiko und Urteil.
    public var auditLine: String {
        let rules = findings.map(\.rule.rawValue).joined(separator: " ")
        let skipped = skippedChecks.isEmpty ? "" : " skipped=[\(skippedChecks.joined(separator: ","))]"
        let suppressedPart = suppressed.isEmpty
            ? "" : " suppressed=[\(suppressed.map(\.rule.rawValue).joined(separator: " "))]"
        return "verdict=\(verdict.rawValue) risk=\(String(format: "%.2f", riskScore))"
            + " approval=\(requiresApproval) citations=\(citations.count)"
            + " rules=[\(rules)]\(suppressedPart)\(skipped)"
    }

    /// Leitet aus Befunden und Politik das Urteil ab.
    public static func verdict(for findings: [Finding], policy: GuardrailPolicy) -> Verdict {
        guard let worst = findings.map(\.severity).max() else { return .allow }
        if worst >= policy.blockAt { return policy.blocksOutput ? .block : .flag }
        if worst >= policy.flagAt { return .flag }
        return .allow
    }

    /// Summe der Regelgewichte, gedeckelt auf 1.0. Bewusst additiv: drei
    /// mittelschwere Befunde sollen schwerer wiegen als einer.
    public static func riskScore(for findings: [Finding]) -> Double {
        min(1.0, findings.reduce(0) { $0 + $1.weight })
    }
}
