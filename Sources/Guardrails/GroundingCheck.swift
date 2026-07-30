// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import GuardrailCore

// MARK: - Grounding & Citation Check
//
// Herkunft: Engram `EngramCore/Governance/Grounding.swift` (Welle 4 der
// Zielbild-Zerlegung). Uebernommen wurde der PRUEF-Anteil — Abstain-Schwelle,
// Belegpflicht, deterministische Nachpruefung unbelegter Angaben. Der
// Synthese-Anteil (`GroundedSynthesizer.synthesize`) bleibt bewusst in Engram:
// Antworten erzeugen ist Sache des Orchestrators, Antworten pruefen ist Sache
// der Guardrails.
//
// Leitprinzip unveraendert: „grounded-or-abstain" — jede Aussage steht auf
// abrufbaren Belegen, oder es gibt ehrlich keine Antwort.

/// Konfigurierbare Grounding-Regeln.
public struct GroundingPolicy: Codable, Sendable, Equatable {
    /// Score-Schwelle: liegt der beste Treffer darunter, traegt der Ausgang keine
    /// belastbaren Belege.
    public var minScore: Double
    /// Belegpflicht: ein Ausgang ohne tragfaehige Quelle ist ein Regelbruch.
    public var requireCitations: Bool
    /// Unbelegte Zahlen/Namen im Ausgang melden.
    public var checkUnbackedClaims: Bool

    public init(minScore: Double = 0.001, requireCitations: Bool = true,
                checkUnbackedClaims: Bool = true) {
        self.minScore = minScore
        self.requireCitations = requireCitations
        self.checkUnbackedClaims = checkUnbackedClaims
    }

    /// Wie bei `GuardrailPolicy`: nicht genannte Felder behalten die
    /// Voreinstellung, damit eine Policy-Datei nur das Abweichende nennen muss.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = GroundingPolicy()
        minScore = try c.decodeIfPresent(Double.self, forKey: .minScore) ?? fallback.minScore
        requireCitations = try c.decodeIfPresent(Bool.self, forKey: .requireCitations)
            ?? fallback.requireCitations
        checkUnbackedClaims = try c.decodeIfPresent(Bool.self, forKey: .checkUnbackedClaims)
            ?? fallback.checkUnbackedClaims
    }

    /// Konservativer Default. EHRLICH: RRF-Scores sind RANG-basiert (1/(k+rank)) —
    /// ein legitimer Einzel-Index-Treffer alter Eintraege kann bei ~0.002 liegen.
    /// Der Default 0.001 schneidet deshalb praktisch nur den leeren Fall ab;
    /// schaerfere Schwellen sind bewusst Betreiber-Tuning, nachdem die eigene
    /// Score-Verteilung bekannt ist.
    public static let standard = GroundingPolicy()
}

/// Prueft, ob ein Ausgang auf den mitgelieferten Belegen steht.
public struct GroundingCheck: GuardrailCheck {
    public let name = "grounding"
    public let policy: GroundingPolicy

    public init(policy: GroundingPolicy = .standard) {
        self.policy = policy
    }

    // MARK: - Belege

    /// Die Treffer, die die Schwelle tragen.
    public func groundedSources(in context: OutputContext) -> [GroundingSource] {
        context.sources.filter { $0.score >= policy.minScore }
    }

    /// Belege aus den tragfaehigen Treffern formen.
    public func citations(for context: OutputContext) -> [Citation] {
        groundedSources(in: context).map(Citation.init(source:))
    }

    // MARK: - Pruefung

    public func inspect(_ context: OutputContext) -> [Finding] {
        var findings: [Finding] = []
        let grounded = groundedSources(in: context)

        if policy.requireCitations && grounded.isEmpty {
            let reason = context.sources.isEmpty
                ? "Keine Belege uebergeben — der Ausgang steht auf nichts."
                : "Nur schwache Treffer (bester Score unter minScore=\(policy.minScore)) — nicht belegbar."
            findings.append(Finding(
                check: name, rule: RuleCatalog.noGrounding,
                message: reason,
                evidence: "sources=\(context.sources.count) grounded=0"))
            // Ohne Belege ist die Nachpruefung gegen den Kontext sinnlos:
            // ALLES waere unbelegt. Ein Befund statt hundert.
            return findings
        }

        // Die Bestaetigung nur, wenn es wirklich etwas zu bestaetigen gibt.
        // "Ausgang steht auf 0 Belegen" als Erfolgsmeldung ist eine Aussage,
        // die niemand so meinen kann.
        if !grounded.isEmpty {
            findings.append(Finding(
                check: name, rule: RuleCatalog.grounded,
                message: "Ausgang steht auf \(grounded.count) Beleg(en).",
                evidence: grounded.map(\.id).joined(separator: ",")))
        }

        // Ohne verwertbaren Kontext ist die Nachpruefung sinnlos: es gaebe
        // keinen Text, gegen den sich irgendetwas belegen liesse, also waere
        // JEDE Zahl und JEDER Name unbelegt. Bei requireCitations == true faengt
        // das der frueher Ausstieg oben ab; ohne die Belegpflicht lief die Stufe
        // weiter und meldete den ganzen Ausgang Fundstelle fuer Fundstelle.
        guard policy.checkUnbackedClaims, !grounded.isEmpty else { return findings }

        let contextText = grounded.map { "\($0.title) \($0.content)" }.joined(separator: "\n")
        for claim in Self.unbackedClaims(in: context.output, context: contextText, query: context.query) {
            findings.append(Finding(
                check: name, rule: RuleCatalog.unbackedClaim,
                message: "Angabe kommt weder im Kontext noch in der Frage vor — als unsicher behandeln.",
                evidence: Self.maskedEvidence(claim)))
        }
        return findings
    }

    // MARK: - Deterministische Nachpruefung (kein LLM)

    /// Belege duerfen keinen Klartext tragen — und eine unbelegte Namenskette
    /// IST ein Personenname.
    ///
    /// Zahlen bleiben lesbar: eine Jahreszahl oder ein Betrag ist die eigentlich
    /// nuetzliche Auskunft fuer den, der den Befund liest, und kein
    /// Personenbezug. Sobald ein Buchstabe vorkommt, wird maskiert.
    static func maskedEvidence(_ claim: String) -> String {
        guard claim.contains(where: { $0.isLetter }) else { return claim }
        return PIIMatch.stars(claim)
    }

    /// Markiert Zahlen (≥ 2 Ziffern) und grossgeschriebene Mehrwort-Namen aus dem
    /// Ausgang, die weder im Kontext noch in der Frage vorkommen. Bewusst
    /// konservativ: einzelne grossgeschriebene Woerter werden NICHT geprueft
    /// (deutsche Substantive!), nur Zahlen und Namens-Ketten — die staerksten
    /// Halluzinations-Signale mit den wenigsten Fehlalarmen.
    public static func unbackedClaims(in answer: String, context: String, query: String) -> [String] {
        let haystack = (context + " " + query).lowercased()
        var flagged: [String] = []

        // Zahlen mit mindestens 2 Ziffern (Jahre, Betraege, Fristen …).
        for match in Regex.matches("[0-9][0-9.,:/-]*[0-9]", in: answer) {
            if !haystack.contains(match.lowercased()) && !flagged.contains(match) {
                flagged.append(match)
            }
        }
        // Namens-Ketten: zwei+ aufeinanderfolgende grossgeschriebene Woerter.
        // Zwei Filter, beide gegen Fehlalarme im Deutschen:
        //   1. Fuehrende Satzanfaenge fallen weg („Der Projektplan" → ein Wort
        //      uebrig → keine Kette). Ohne das meldet jeder Satzanfang mit
        //      Substantiv eine Halluzination.
        //   2. Eine Kette gilt nur als unbelegt, wenn KEINES ihrer Woerter im
        //      Kontext vorkommt — ein komplett unbekannter Name.
        for match in Regex.matches("\\p{Lu}\\p{L}+(?: \\p{Lu}\\p{L}+)+", in: answer) {
            guard let chain = GermanText.strippedNameChain(match) else { continue }
            let words = chain.lowercased().split(separator: " ").map(String.init)
            let anyKnown = words.contains { haystack.contains($0) }
            if !anyKnown && !flagged.contains(chain) {
                flagged.append(chain)
            }
        }
        return flagged
    }
}
