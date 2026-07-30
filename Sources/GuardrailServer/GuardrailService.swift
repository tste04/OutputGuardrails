// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import GuardrailCore
import Guardrails

// MARK: - Der transport-neutrale Dienst
//
// Genau eine Stelle uebersetzt zwischen JSON und den Kern-Typen. HTTP und CLI
// sind beides nur Huellen darum — deshalb kann keine Semantik-Drift zwischen
// „per Kommandozeile geprueft" und „per Dienst geprueft" entstehen.
//
// `JSONSerialization` statt Codable ist Absicht: das Schema-Feld kommt in
// JSON-Schema-Form herein und ist bewusst tolerant zu lesen.

/// Prueft Ausgaenge auf Basis einer Konfiguration.
public struct GuardrailService: Sendable {

    public let config: GuardrailConfig
    private let llm: GuardrailLLM?

    public init(config: GuardrailConfig = GuardrailConfig(), llm: GuardrailLLM? = nil) {
        self.config = config
        self.llm = llm
    }

    // MARK: - Pruefen

    public func inspect(_ context: OutputContext) async -> GuardrailReport {
        let pipeline = config.pipeline(withLLM: llm != nil)
        if llm == nil { return pipeline.inspect(context) }
        return await pipeline.inspect(context, llm: llm)
    }

    /// Nimmt eine Anfrage als JSON entgegen und liefert den Bericht als JSON.
    public func inspect(requestJSON data: Data) async -> (status: Int, body: Data) {
        let context: OutputContext
        do {
            context = try Self.decodeRequest(data)
        } catch {
            return (400, Self.encode(["error": String(describing: error)]))
        }
        let report = await inspect(context)
        return (200, Self.encode(Self.encodeReport(report)))
    }

    // MARK: - Anfrage lesen

    public enum RequestError: Error, CustomStringConvertible {
        case notAnObject
        case missingOutput
        case badTimestamp(String)

        public var description: String {
            switch self {
            case .notAnObject: return "Anfrage ist kein JSON-Objekt"
            case .missingOutput: return "Feld 'output' fehlt"
            case .badTimestamp(let raw):
                return "occurredAt ist kein ISO-8601-Zeitstempel: '\(raw)'"
            }
        }
    }

    public static func decodeRequest(_ data: Data) throws -> OutputContext {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RequestError.notAnObject
        }
        guard let output = root["output"] as? String else { throw RequestError.missingOutput }

        let query = root["query"] as? String ?? ""
        let sources = try (root["sources"] as? [[String: Any]] ?? []).map(decodeSource)
        let knownFacts = (root["knownFacts"] as? [[String: Any]] ?? []).map(decodeFact)
        let assertedFacts = (root["assertedFacts"] as? [[String: Any]] ?? []).map(decodeFact)
        let schema = (root["schema"] as? [String: Any]).flatMap(SchemaNode.fromJSONSchema)

        return OutputContext(output: output, query: query, sources: sources,
                             expectedSchema: schema, knownFacts: knownFacts,
                             assertedFacts: assertedFacts)
    }

    private static func decodeSource(_ dict: [String: Any]) throws -> GroundingSource {
        // Der Zeitstempel bestimmt Aktualitaet und damit die Bewertung eines
        // Belegs. Frueher fiel jeder unlesbare Wert still auf 'jetzt' zurueck —
        // ein alter Beleg wurde damit zum taufrischen. Betroffen war vor allem
        // die haeufigste Quelle ueberhaupt: JavaScripts toISOString() liefert
        // Sekundenbruchteile, die der Standard-Formatierer nicht annimmt.
        let occurred: Date
        if let raw = dict["occurredAt"] as? String {
            guard let parsed = iso8601.date(from: raw) ?? iso8601Fractional.date(from: raw) else {
                throw RequestError.badTimestamp(raw)
            }
            occurred = parsed
        } else {
            occurred = Date()
        }
        return GroundingSource(
            id: dict["id"] as? String ?? "",
            sourceType: dict["sourceType"] as? String ?? "unknown",
            origin: ProvenanceOrigin(rawValue: dict["origin"] as? String ?? "memory") ?? .memory,
            occurredAt: occurred,
            score: (dict["score"] as? NSNumber)?.doubleValue ?? 1.0,
            title: dict["title"] as? String ?? "",
            content: dict["content"] as? String ?? "")
    }

    private static func decodeFact(_ dict: [String: Any]) -> FactTriple {
        FactTriple(id: dict["id"] as? String ?? "",
                   subject: dict["subject"] as? String ?? "",
                   predicate: dict["predicate"] as? String ?? "",
                   object: dict["object"] as? String ?? "",
                   isActive: dict["isActive"] as? Bool ?? true)
    }

    // MARK: - Bericht schreiben

    /// Der Bericht ist die Schnittstelle zu den Nachbarbausteinen: `verdict` und
    /// `requiresApproval` liest die Risk-based-Approval-Stufe, `riskScore` und
    /// die Regel-IDs liest der Audit-Baustein. Kein Feld traegt Ausgangstext.
    public static func encodeReport(_ report: GuardrailReport) -> [String: Any] {
        [
            "verdict": report.verdict.rawValue,
            "riskScore": report.riskScore,
            "requiresApproval": report.requiresApproval,
            "findings": report.findings.map(encodeFinding),
            "suppressed": report.suppressed.map(encodeFinding),
            "citations": report.citations.map { citation in
                [
                    "id": citation.id,
                    "sourceType": citation.sourceType,
                    "origin": citation.origin.rawValue,
                    "occurredAt": iso8601.string(from: citation.occurredAt),
                    "score": citation.score,
                ] as [String: Any]
            },
            "skippedChecks": report.skippedChecks,
            "audit": report.auditLine,
        ]
    }

    private static func encodeFinding(_ finding: Finding) -> [String: Any] {
        var dict: [String: Any] = [
            "check": finding.check,
            "rule": finding.rule.rawValue,
            "category": finding.category.rawValue,
            "severity": finding.severity.rawValue,
            "weight": finding.weight,
            "message": finding.message,
        ]
        if let evidence = finding.evidence { dict["evidence"] = evidence }
        return dict
    }

    public static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]))
            ?? Data(#"{"error":"encoding failed"}"#.utf8)
    }

    /// Der Regelkatalog als JSON — die Selbstauskunft des Dienstes.
    public static func encodeCatalog() -> [String: Any] {
        ["rules": RuleCatalog.all.map { rule in
            [
                "id": rule.id.rawValue,
                "category": rule.category.rawValue,
                "severity": rule.severity.rawValue,
                "weight": rule.weight,
                "title": rule.title,
            ] as [String: Any]
        }]
    }

    static let iso8601 = ISO8601DateFormatter()
    /// Zweite Lesart mit Sekundenbruchteilen. `new Date().toISOString()` in
    /// JavaScript liefert genau diese Form ("2026-07-30T12:00:00.123Z") — der
    /// Standard-Formatierer weist sie zurueck, und damit waere die haeufigste
    /// Quelle ueberhaupt unlesbar.
    static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
