// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import GuardrailCore

// MARK: - Zugangsdaten im Ausgang (Zielbild: Security)
//
// Der Eingang hat dieselbe Pruefung (AIGateway, SEC-Regeln) — und trotzdem
// braucht der Ausgang sie noch einmal. Drei Wege, auf denen ein Schluessel
// hinten herauskommt, obwohl vorne keiner hineinging:
//
//   1. Der Kontext bringt ihn mit (eine Konfigurationsdatei im RAG-Treffer).
//   2. Ein Werkzeug liefert ihn zurueck (Tool-Ausgabe im Agent Loop).
//   3. Das Modell halluziniert ein plausibles Schluesselformat und jemand
//      haelt es fuer echt.
//
// Die Regel-IDs sind bewusst deckungsgleich mit dem AIGateway: derselbe
// private Schluessel ist am Eingang wie am Ausgang `SEC-001`.

/// Findet erkennbare Zugangsdaten-Formate im Modell-Ausgang.
public struct SecretsCheck: GuardrailCheck {
    public let name = "secrets"

    public init() {}

    /// Muster fuer Formate, die sich eindeutig erkennen lassen.
    ///
    /// Bewusst nur Formate mit strukturellem Anker (Praefix, feste Laenge,
    /// Rahmen). Entropie-Heuristiken sind hier nicht gewuenscht: ein Base64-Block
    /// in einer legitimen Antwort ist kein Vorfall, und ein Fehlalarm blockiert
    /// eine korrekte Antwort.
    static let patterns: [(RuleID, String, NSRegularExpression.Options)] = [
        (RuleCatalog.secretPrivateKey, "-----BEGIN[ A-Z]*PRIVATE KEY-----", []),
        (RuleCatalog.secretAWSKey, "\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b", []),
        (RuleCatalog.secretGitHubToken, "\\bgh[pousr]_[A-Za-z0-9]{36,}\\b", []),
        (RuleCatalog.secretSlackToken, "\\bxox[abprs]-[A-Za-z0-9-]{10,}\\b", []),
        (RuleCatalog.secretJWT, "\\bey[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\b", []),
        // `sk-` mit Bindestrichen im Rumpf: die aktuellen Schluessel von
        // Anthropic (`sk-ant-api03-…`) und OpenAI (`sk-proj-…`) tragen
        // Bindestriche, die das alte `[A-Za-z0-9]{20,}` ausgeschlossen hat —
        // ausgerechnet die beiden Formate, die heute am haeufigsten in einem
        // Modell-Ausgang landen, blieben damit unerkannt.
        (RuleCatalog.secretAPIKey, "\\bsk-(?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){20,}", []),
        (RuleCatalog.secretGitHubToken, "\\bgithub_pat_[A-Za-z0-9_]{22,}\\b", []),
        (RuleCatalog.secretGitLabToken, "\\bglpat-[A-Za-z0-9_-]{20,}\\b", []),
        (RuleCatalog.secretGoogleAPIKey, "\\bAIza[A-Za-z0-9_-]{35}\\b", []),
        (RuleCatalog.secretStripeKey, "\\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}\\b", []),
    ]

    /// Ein Fund. Der Klarwert bleibt im Prozess; in Befunde wandert nur die
    /// maskierte Form.
    public struct SecretMatch: Sendable, Equatable {
        public let rule: RuleID
        public let value: String

        /// Anfang erkennbar lassen, Rest verdecken — genug zum Wiederfinden in
        /// der Quelle, zu wenig zum Benutzen.
        public var masked: String {
            let head = value.prefix(6)
            return head + String(repeating: "*", count: max(4, min(12, value.count - 6)))
        }
    }

    public func detect(in text: String) -> [SecretMatch] {
        var found: [SecretMatch] = []
        var seen = Set<String>()
        for (rule, pattern, options) in Self.patterns {
            for value in Regex.matches(pattern, in: text, options: options) {
                guard seen.insert("\(rule)|\(value)").inserted else { continue }
                found.append(SecretMatch(rule: rule, value: value))
            }
        }
        return found
    }

    public func inspect(_ context: OutputContext) -> [Finding] {
        detect(in: context.output).map { match in
            Finding(check: name, rule: match.rule,
                    message: "\(RuleCatalog.resolve(match.rule).title) — Ausgang nicht ausliefern, Zugangsdaten rotieren.",
                    evidence: match.masked)
        }
    }
}
