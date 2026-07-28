// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import GuardrailCore

// MARK: - Widerspruchspruefung
//
// Herkunft: Engram `EngramCore/Engines/ContradictionDetector.swift` (Welle 4).
// Dort prueft sie das Gedaechtnis gegen sich selbst (Fakten-Hygiene); hier prueft
// sie den Modell-Ausgang gegen bekannte Fakten. Die Erkennung ist dieselbe:
// gleiches Subjekt + Praedikat, anderes Objekt.
//
// Zweistufig wie im Original: deterministische Kandidaten (kein LLM, immer
// verfuegbar, keine Kosten) und optional die LLM-Bestaetigung fuer die Faelle,
// in denen zwei Objekte nur *anders formuliert* statt *widerspruechlich* sind.

/// Ein deterministisch erkanntes Kandidatenpaar.
public struct ContradictionCandidate: Sendable, Equatable {
    public let assertedId: String
    public let assertedTriple: String
    public let knownId: String
    public let knownTriple: String
}

/// Prueft behauptete Fakten gegen bekannte Fakten.
public struct ConsistencyCheck: GuardrailCheck {
    public let name = "consistency"

    public init() {}

    /// Findet Kollisionen zwischen `asserted` und `known`.
    ///
    /// Kollisionen setzen gleiches Subjekt (case-insensitiv) + Praedikat voraus →
    /// die bekannten Fakten einmal nach diesem Schluessel bucketen, statt jede
    /// Behauptung gegen alle Fakten zu vergleichen (O(n·m) → O(n+m)).
    public func candidates(asserted: [FactTriple], known: [FactTriple]) -> [ContradictionCandidate] {
        let activeKnown = known.filter(\.isActive)
        let probes = asserted.filter(\.isActive)
        guard !activeKnown.isEmpty, !probes.isEmpty else { return [] }

        var buckets: [String: [FactTriple]] = [:]
        for fact in activeKnown {
            buckets["\(fact.subject.lowercased())|\(fact.predicate.lowercased())", default: []].append(fact)
        }

        var result: [ContradictionCandidate] = []
        var seen = Set<String>()

        for probe in probes {
            guard let bucket = buckets["\(probe.subject.lowercased())|\(probe.predicate.lowercased())"] else { continue }
            let probeObject = probe.object.lowercased()
            for existing in bucket where existing.id != probe.id {
                guard existing.object.lowercased() != probeObject else { continue }
                let key = [probe.id, existing.id].sorted().joined(separator: "|")
                guard seen.insert(key).inserted else { continue }
                result.append(ContradictionCandidate(
                    assertedId: probe.id, assertedTriple: probe.tripleString,
                    knownId: existing.id, knownTriple: existing.tripleString))
            }
        }
        return result
    }

    public func inspect(_ context: OutputContext) -> [Finding] {
        candidates(asserted: context.assertedFacts, known: context.knownFacts).map {
            Finding(check: name, rule: RuleCatalog.contradictionCandidate,
                    message: "Behauptung widerspricht einem bekannten Fakt (deterministisch erkannt, nicht verifiziert).",
                    evidence: "\($0.assertedTriple) ⇄ \($0.knownTriple)")
        }
    }
}

/// LLM-Bestaetigung der deterministischen Kandidaten.
///
/// Getrennte Stufe, weil sie ein Modell braucht: ohne Modell bleibt es bei den
/// Kandidaten der deterministischen Stufe — die Pipeline vermerkt das als
/// uebersprungen, statt „keine Widersprueche" zu behaupten.
public struct LLMConsistencyCheck: AsyncGuardrailCheck {
    public let name = "consistency_llm"

    /// Ab welcher Modell-Konfidenz ein Widerspruch als bestaetigt gilt.
    public let minConfidence: Double
    private let detector = ConsistencyCheck()

    public init(minConfidence: Double = 0.6) {
        self.minConfidence = minConfidence
    }

    public func inspect(_ context: OutputContext, llm: GuardrailLLM) async -> [Finding] {
        let candidates = detector.candidates(asserted: context.assertedFacts, known: context.knownFacts)
        guard !candidates.isEmpty else { return [] }

        var findings: [Finding] = []
        for candidate in candidates {
            let system = "Du bist ein Fakten-Pruefer. Analysiere ob zwei Aussagen sich widersprechen."
            let user = """
            Aussage A: \(candidate.assertedTriple)
            Aussage B: \(candidate.knownTriple)

            Widersprechen sich diese Aussagen? Antworte mit JSON:
            {"contradiction": true/false, "confidence": 0.0-1.0, "explanation": "kurze Erklaerung"}
            """
            do {
                let response = try await llm.send(system: system, user: user, maxTokens: 256)
                guard let data = response.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let isContradiction = json["contradiction"] as? Bool,
                      let confidence = json["confidence"] as? Double else {
                    findings.append(Finding(
                        check: name, rule: RuleCatalog.unverifiable,
                        message: "Modell-Antwort nicht auswertbar — Kandidat bleibt offen.",
                        evidence: "\(candidate.assertedId)|\(candidate.knownId)"))
                    continue
                }
                guard isContradiction, confidence >= minConfidence else { continue }
                let explanation = json["explanation"] as? String ?? ""
                findings.append(Finding(
                    check: name, rule: RuleCatalog.contradictionConfirmed,
                    message: "Bestaetigter Widerspruch (Konfidenz \(String(format: "%.2f", confidence))): \(explanation)",
                    evidence: "\(candidate.assertedTriple) ⇄ \(candidate.knownTriple)"))
            } catch {
                // Ein Modellfehler ist kein „unauffaellig": der Kandidat bleibt offen.
                findings.append(Finding(
                    check: name, rule: RuleCatalog.verificationFailed,
                    message: "Verifikation fehlgeschlagen (\(error.localizedDescription)) — Kandidat bleibt offen.",
                    evidence: "\(candidate.assertedId)|\(candidate.knownId)"))
            }
        }
        return findings
    }
}
