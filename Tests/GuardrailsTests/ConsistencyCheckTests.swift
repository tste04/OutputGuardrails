import XCTest
@testable import Guardrails
import GuardrailCore

private struct StubLLM: GuardrailLLM {
    let ready: Bool
    let response: String
    let failure: Error?

    init(ready: Bool = true, response: String = "", failure: Error? = nil) {
        self.ready = ready
        self.response = response
        self.failure = failure
    }

    func isReady() async -> Bool { ready }

    func send(system: String, user: String, maxTokens: Int?) async throws -> String {
        if let failure { throw failure }
        return response
    }
}

private struct StubError: Error, LocalizedError {
    var errorDescription: String? { "Modell nicht erreichbar" }
}

final class ConsistencyCheckTests: XCTestCase {

    private let known = [
        FactTriple(id: "k1", subject: "Max", predicate: "arbeitet_bei", object: "Firma A"),
        FactTriple(id: "k2", subject: "Max", predicate: "wohnt_in", object: "Berlin"),
    ]

    func testSameSubjectAndPredicateDifferentObjectCollides() {
        let asserted = [FactTriple(id: "a1", subject: "Max", predicate: "arbeitet_bei", object: "Firma B")]
        let candidates = ConsistencyCheck().candidates(asserted: asserted, known: known)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.knownId, "k1")
    }

    func testDifferentPredicateDoesNotCollide() {
        let asserted = [FactTriple(id: "a1", subject: "Max", predicate: "wohnt_in", object: "Berlin")]
        XCTAssertTrue(ConsistencyCheck().candidates(asserted: asserted, known: known).isEmpty)
    }

    func testSubjectMatchIsCaseInsensitive() {
        let asserted = [FactTriple(id: "a1", subject: "max", predicate: "arbeitet_bei", object: "Firma B")]
        XCTAssertEqual(ConsistencyCheck().candidates(asserted: asserted, known: known).count, 1)
    }

    func testInactiveFactsAreIgnored() {
        let inactive = [FactTriple(id: "k1", subject: "Max", predicate: "arbeitet_bei",
                                   object: "Firma A", isActive: false)]
        let asserted = [FactTriple(id: "a1", subject: "Max", predicate: "arbeitet_bei", object: "Firma B")]
        XCTAssertTrue(ConsistencyCheck().candidates(asserted: asserted, known: inactive).isEmpty)
    }

    func testEachPairIsReportedOnce() {
        let asserted = [
            FactTriple(id: "a1", subject: "Max", predicate: "arbeitet_bei", object: "Firma B"),
            FactTriple(id: "a1", subject: "Max", predicate: "arbeitet_bei", object: "Firma B"),
        ]
        XCTAssertEqual(ConsistencyCheck().candidates(asserted: asserted, known: known).count, 1)
    }

    /// Deterministisch erkannt heisst noch nicht bestaetigt: zwei Objekte koennen
    /// auch nur anders formuliert sein.
    func testDeterministicCandidateIsWarningNotViolation() {
        let context = OutputContext(
            output: "Max arbeitet bei Firma B.",
            knownFacts: known,
            assertedFacts: [FactTriple(id: "a1", subject: "Max", predicate: "arbeitet_bei", object: "Firma B")])
        let findings = ConsistencyCheck().inspect(context)
        XCTAssertEqual(findings.map(\.severity), [.warning])
    }

    // MARK: - LLM-Stufe

    private var collidingContext: OutputContext {
        OutputContext(
            output: "Max arbeitet bei Firma B.",
            knownFacts: known,
            assertedFacts: [FactTriple(id: "a1", subject: "Max", predicate: "arbeitet_bei", object: "Firma B")])
    }

    func testConfirmedContradictionIsAViolation() async {
        let llm = StubLLM(response: #"{"contradiction": true, "confidence": 0.9, "explanation": "Zwei Arbeitgeber"}"#)
        let findings = await LLMConsistencyCheck().inspect(collidingContext, llm: llm)
        XCTAssertEqual(findings.map(\.code), ["contradiction_confirmed"])
        XCTAssertEqual(findings.first?.severity, .violation)
    }

    func testModelSayingNoContradictionClearsTheCandidate() async {
        let llm = StubLLM(response: #"{"contradiction": false, "confidence": 0.9, "explanation": ""}"#)
        let findings = await LLMConsistencyCheck().inspect(collidingContext, llm: llm)
        XCTAssertTrue(findings.isEmpty)
    }

    func testLowConfidenceDoesNotConfirm() async {
        let llm = StubLLM(response: #"{"contradiction": true, "confidence": 0.2, "explanation": ""}"#)
        let findings = await LLMConsistencyCheck(minConfidence: 0.6).inspect(collidingContext, llm: llm)
        XCTAssertTrue(findings.isEmpty)
    }

    /// Ein Modellfehler ist kein „unauffaellig" — der Kandidat bleibt offen.
    func testModelFailureLeavesCandidateOpen() async {
        let llm = StubLLM(failure: StubError())
        let findings = await LLMConsistencyCheck().inspect(collidingContext, llm: llm)
        XCTAssertEqual(findings.map(\.code), ["verification_failed"])
        XCTAssertEqual(findings.first?.severity, .warning)
    }

    func testUnparsableAnswerLeavesCandidateOpen() async {
        let llm = StubLLM(response: "Kann ich nicht sagen.")
        let findings = await LLMConsistencyCheck().inspect(collidingContext, llm: llm)
        XCTAssertEqual(findings.map(\.code), ["unverifiable"])
    }

    func testNoCandidatesMeansNoModelCall() async {
        let context = OutputContext(output: "Alles klar.", knownFacts: known, assertedFacts: [])
        let llm = StubLLM(failure: StubError())
        let findings = await LLMConsistencyCheck().inspect(context, llm: llm)
        XCTAssertTrue(findings.isEmpty)
    }
}
