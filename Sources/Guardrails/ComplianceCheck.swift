// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import GuardrailCore

// MARK: - Compliance (Zielbild: Compliance)
//
// Die einzige Stufe ohne eingebaute Meinung. Was compliant ist, entscheidet die
// Organisation, nicht dieses Paket: eine Kanzlei braucht andere Pflichthinweise
// als eine Bank, und was in einem Haus eine untersagte Zusage ist („garantiert",
// „risikofrei"), ist im anderen der normale Sprachgebrauch.
//
// Deshalb ist hier alles Konfiguration und der Default leer: ohne Regeln meldet
// die Stufe nichts. Das ist Absicht — eine mitgelieferte Beispielliste wuerde
// als „das reicht dann wohl" missverstanden.

/// Richtlinien der Organisation fuer den Ausgang.
public struct CompliancePolicy: Sendable, Equatable, Codable {

    /// Ein Hinweis, der in bestimmten Faellen im Ausgang stehen muss.
    public struct RequiredDisclaimer: Sendable, Equatable, Codable {
        /// Kennung fuer Bericht und Suppression, z. B. `anlageberatung`.
        public let id: String
        /// Loest die Pflicht aus, wenn eines dieser Muster im Ausgang vorkommt.
        /// Leer = immer erforderlich.
        public let triggerPatterns: [String]
        /// Erfuellt die Pflicht, wenn eines dieser Muster im Ausgang vorkommt.
        public let satisfiedByPatterns: [String]
        /// Was dem Nutzer gemeldet wird, wenn der Hinweis fehlt.
        public let message: String

        public init(id: String, triggerPatterns: [String] = [],
                    satisfiedByPatterns: [String], message: String) {
            self.id = id
            self.triggerPatterns = triggerPatterns
            self.satisfiedByPatterns = satisfiedByPatterns
            self.message = message
        }

        /// `triggerPatterns` darf in der Datei fehlen — dann gilt der Hinweis immer.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            triggerPatterns = try c.decodeIfPresent([String].self, forKey: .triggerPatterns) ?? []
            satisfiedByPatterns = try c.decode([String].self, forKey: .satisfiedByPatterns)
            message = try c.decode(String.self, forKey: .message)
        }
    }

    /// Formulierungen, die nicht ausgeliefert werden duerfen.
    public var forbiddenPatterns: [String]
    /// Pflichthinweise.
    public var requiredDisclaimers: [RequiredDisclaimer]
    /// Obergrenze fuer die Ausgangslaenge in Zeichen. `nil` = keine.
    public var maxOutputCharacters: Int?
    /// Muster case-insensitiv pruefen. Default `true` — Richtlinien meinen den
    /// Begriff, nicht die Schreibweise.
    public var caseInsensitive: Bool

    public init(forbiddenPatterns: [String] = [],
                requiredDisclaimers: [RequiredDisclaimer] = [],
                maxOutputCharacters: Int? = nil,
                caseInsensitive: Bool = true) {
        self.forbiddenPatterns = forbiddenPatterns
        self.requiredDisclaimers = requiredDisclaimers
        self.maxOutputCharacters = maxOutputCharacters
        self.caseInsensitive = caseInsensitive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        forbiddenPatterns = try c.decodeIfPresent([String].self, forKey: .forbiddenPatterns) ?? []
        requiredDisclaimers = try c.decodeIfPresent([RequiredDisclaimer].self,
                                                    forKey: .requiredDisclaimers) ?? []
        maxOutputCharacters = try c.decodeIfPresent(Int.self, forKey: .maxOutputCharacters)
        caseInsensitive = try c.decodeIfPresent(Bool.self, forKey: .caseInsensitive) ?? true
    }

    /// Leer — ohne Konfiguration meldet die Stufe nichts.
    public static let empty = CompliancePolicy()

    public var isEmpty: Bool {
        forbiddenPatterns.isEmpty && requiredDisclaimers.isEmpty && maxOutputCharacters == nil
    }
}

/// Prueft den Ausgang gegen die Richtlinien der Organisation.
public struct ComplianceCheck: GuardrailCheck {
    public let name = "compliance"
    public let policy: CompliancePolicy

    public init(policy: CompliancePolicy = .empty) {
        self.policy = policy
    }

    private var options: NSRegularExpression.Options {
        policy.caseInsensitive ? [.caseInsensitive] : []
    }

    public func inspect(_ context: OutputContext) -> [Finding] {
        guard !policy.isEmpty else { return [] }
        var findings: [Finding] = []

        for pattern in policy.forbiddenPatterns {
            for hit in Regex.matches(pattern, in: context.output, options: options) {
                findings.append(Finding(
                    check: name, rule: RuleCatalog.forbiddenTerm,
                    message: "Untersagte Formulierung im Ausgang.",
                    evidence: hit.count <= 40 ? hit : String(hit.prefix(40)) + "…"))
            }
        }

        for disclaimer in policy.requiredDisclaimers {
            let triggered = disclaimer.triggerPatterns.isEmpty
                || disclaimer.triggerPatterns.contains {
                    Regex.hasMatch($0, in: context.output, options: options)
                }
            guard triggered else { continue }
            let satisfied = disclaimer.satisfiedByPatterns.contains {
                Regex.hasMatch($0, in: context.output, options: options)
            }
            guard !satisfied else { continue }
            findings.append(Finding(
                check: name, rule: RuleCatalog.missingDisclaimer,
                message: disclaimer.message,
                evidence: disclaimer.id))
        }

        if let limit = policy.maxOutputCharacters, context.output.count > limit {
            findings.append(Finding(
                check: name, rule: RuleCatalog.outputTooLong,
                message: "Ausgang ueberschreitet die zulaessige Laenge.",
                evidence: "\(context.output.count)/\(limit)"))
        }
        return findings
    }
}
