// Copyright (c) 2026 Tommy Stellmacher
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE.md).

import Foundation

/// Herkunft eines Belegs.
public enum ProvenanceOrigin: String, Codable, Sendable {
    /// Aus dem lokalen, freigegebenen Gedaechtnis.
    case memory
    /// Aus einem externen Abruf.
    case web
    /// Kein Beleg vorhanden.
    case none
}

/// Eine Kontextzeile, auf die sich der Ausgang stuetzen darf.
///
/// Das ist die Naht zum Context Orchestrator: wer die Guardrails aufruft,
/// uebergibt genau die Treffer, die er dem Modell als Kontext gegeben hat.
/// Die Guardrails kennen weder Store noch Retrieval.
public struct GroundingSource: Sendable, Equatable, Codable {
    /// Stabile, nachschlagbare ID (Episode-/Fakt-ID).
    public let id: String
    public let sourceType: String
    public let origin: ProvenanceOrigin
    /// Wann die Erinnerung entstand.
    public let occurredAt: Date
    /// Retrieval-Score des Treffers.
    public let score: Double
    public let title: String
    public let content: String

    public init(id: String, sourceType: String, origin: ProvenanceOrigin = .memory,
                occurredAt: Date = Date(), score: Double = 1.0,
                title: String = "", content: String) {
        self.id = id
        self.sourceType = sourceType
        self.origin = origin
        self.occurredAt = occurredAt
        self.score = score
        self.title = title
        self.content = content
    }
}

/// Ein Beleg, den eine ausgelieferte Antwort traegt (Belegpflicht).
public struct Citation: Sendable, Equatable, Codable {
    public let id: String
    public let sourceType: String
    public let origin: ProvenanceOrigin
    public let occurredAt: Date
    public let score: Double

    public init(id: String, sourceType: String, origin: ProvenanceOrigin,
                occurredAt: Date, score: Double) {
        self.id = id
        self.sourceType = sourceType
        self.origin = origin
        self.occurredAt = occurredAt
        self.score = score
    }

    public init(source: GroundingSource) {
        self.init(id: source.id, sourceType: source.sourceType, origin: source.origin,
                  occurredAt: source.occurredAt, score: source.score)
    }
}

/// Ein Aussage-Tripel fuer die Konsistenzpruefung (Subjekt–Praedikat–Objekt).
public struct FactTriple: Sendable, Equatable, Codable {
    public let id: String
    public let subject: String
    public let predicate: String
    public let object: String
    public let isActive: Bool

    public init(id: String, subject: String, predicate: String,
                object: String, isActive: Bool = true) {
        self.id = id
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.isActive = isActive
    }

    public var tripleString: String { "\(subject) \(predicate) \(object)" }
}

/// Alles, was die Pruefstufen ueber einen Modell-Ausgang wissen duerfen.
///
/// Bewusst ein reiner Wert: die Guardrails fuehren keine I/O aus, oeffnen keine
/// Verbindungen und halten keinen Zustand. Was nicht hier drinsteht, wird nicht
/// geprueft — es gibt keinen versteckten Seitenkanal.
public struct OutputContext: Sendable {
    /// Der zu pruefende Modell-Ausgang.
    public let output: String
    /// Die Frage/Aufgabe, die zu diesem Ausgang gefuehrt hat.
    public let query: String
    /// Die Belege, die dem Modell als Kontext vorlagen.
    public let sources: [GroundingSource]
    /// Erwartetes JSON-Schema, falls der Ausgang strukturiert sein muss.
    public let expectedSchema: SchemaNode?
    /// Bekannte Fakten, gegen die auf Widerspruch geprueft wird.
    public let knownFacts: [FactTriple]
    /// Vom Aufrufer behauptete Fakten aus dem Ausgang (falls extrahiert).
    public let assertedFacts: [FactTriple]

    public init(output: String, query: String = "",
                sources: [GroundingSource] = [],
                expectedSchema: SchemaNode? = nil,
                knownFacts: [FactTriple] = [],
                assertedFacts: [FactTriple] = []) {
        self.output = output
        self.query = query
        self.sources = sources
        self.expectedSchema = expectedSchema
        self.knownFacts = knownFacts
        self.assertedFacts = assertedFacts
    }
}
