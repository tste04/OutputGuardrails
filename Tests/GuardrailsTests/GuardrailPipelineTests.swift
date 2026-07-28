import XCTest
@testable import Guardrails
import GuardrailCore

private struct CountingLLM: GuardrailLLM {
    let ready: Bool
    let counter: Counter

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return value }
        func increment() { lock.lock(); value += 1; lock.unlock() }
    }

    func isReady() async -> Bool { ready }

    func send(system: String, user: String, maxTokens: Int?) async throws -> String {
        counter.increment()
        return #"{"contradiction": true, "confidence": 0.9, "explanation": "x"}"#
    }
}

final class GuardrailPipelineTests: XCTestCase {

    private func groundedContext(output: String) -> OutputContext {
        OutputContext(
            output: output, query: "Frage",
            sources: [GroundingSource(id: "e1", sourceType: "note", title: "Notiz",
                                      content: "Der Start ist im Mai.")])
    }

    func testCleanOutputIsAllowed() {
        let pipeline = GuardrailPipeline(checks: [GroundingCheck(), PIICheck()])
        let report = pipeline.inspect(groundedContext(output: "Der Start ist im Mai."))
        XCTAssertEqual(report.verdict, .allow)
        XCTAssertEqual(report.citations.map(\.id), ["e1"])
    }

    func testWarningFlagsButDoesNotBlock() {
        let pipeline = GuardrailPipeline(checks: [GroundingCheck()])
        let report = pipeline.inspect(groundedContext(output: "Der Start ist im Mai, Budget 4200."))
        XCTAssertEqual(report.verdict, .flag)
        XCTAssertFalse(report.isBlocked)
    }

    func testViolationBlocks() {
        let pipeline = GuardrailPipeline(checks: [PIICheck()])
        let report = pipeline.inspect(OutputContext(output: "IBAN DE89370400440532013000"))
        XCTAssertEqual(report.verdict, .block)
    }

    /// Fuer Ausgaenge, die ohne Mensch weitergehen, blockt schon eine Warnung.
    func testStrictPolicyBlocksOnWarning() {
        let pipeline = GuardrailPipeline(checks: [GroundingCheck()], policy: .strict)
        let report = pipeline.inspect(groundedContext(output: "Der Start ist im Mai, Budget 4200."))
        XCTAssertEqual(report.verdict, .block)
    }

    /// Eine uebersprungene Pruefung ist kein bestandener Test.
    func testSkippedAsyncCheckIsReported() {
        let pipeline = GuardrailPipeline(checks: [GroundingCheck()],
                                         asyncChecks: [LLMConsistencyCheck()])
        let report = pipeline.inspect(groundedContext(output: "Der Start ist im Mai."))
        XCTAssertEqual(report.skippedChecks, ["consistency_llm"])
        XCTAssertTrue(report.findings.contains { $0.code == "skipped" })
        XCTAssertEqual(report.verdict, .allow)
    }

    func testUnreadyModelSkipsInsteadOfPassing() async {
        let pipeline = GuardrailPipeline(checks: [], asyncChecks: [LLMConsistencyCheck()])
        let llm = CountingLLM(ready: false, counter: .init())
        let report = await pipeline.inspect(groundedContext(output: "Text"), llm: llm)
        XCTAssertEqual(report.skippedChecks, ["consistency_llm"])
        XCTAssertEqual(llm.counter.calls, 0)
    }

    /// Kein Modell befragen, wenn deterministisch schon geblockt wurde — das
    /// spart Geld und schickt den Ausgang nicht ein zweites Mal an ein Modell.
    func testBlockedOutputDoesNotReachTheModel() async {
        let context = OutputContext(
            output: "IBAN DE89370400440532013000",
            knownFacts: [FactTriple(id: "k1", subject: "Max", predicate: "p", object: "A")],
            assertedFacts: [FactTriple(id: "a1", subject: "Max", predicate: "p", object: "B")])
        let pipeline = GuardrailPipeline(checks: [PIICheck()], asyncChecks: [LLMConsistencyCheck()])
        let llm = CountingLLM(ready: true, counter: .init())

        let report = await pipeline.inspect(context, llm: llm)
        XCTAssertEqual(report.verdict, .block)
        XCTAssertEqual(llm.counter.calls, 0, "Blockierter Ausgang darf kein Modell mehr kosten")
        XCTAssertEqual(report.skippedChecks, ["consistency_llm"])
    }

    func testAsyncChecksRunWhenModelIsReady() async {
        let context = OutputContext(
            output: "Max arbeitet bei Firma B.",
            knownFacts: [FactTriple(id: "k1", subject: "Max", predicate: "arbeitet_bei", object: "Firma A")],
            assertedFacts: [FactTriple(id: "a1", subject: "Max", predicate: "arbeitet_bei", object: "Firma B")])
        let pipeline = GuardrailPipeline(checks: [], asyncChecks: [LLMConsistencyCheck()])
        let llm = CountingLLM(ready: true, counter: .init())

        let report = await pipeline.inspect(context, llm: llm)
        XCTAssertEqual(llm.counter.calls, 1)
        XCTAssertEqual(report.verdict, .block)
        XCTAssertTrue(report.skippedChecks.isEmpty)
    }

    func testLightweightSetSkipsGrounding() {
        let report = GuardrailPipeline.lightweight().inspect(OutputContext(output: "Kurzer Zwischenschritt"))
        XCTAssertEqual(report.verdict, .allow)
        XCTAssertTrue(report.findings(from: "grounding").isEmpty)
    }

    func testStandardSetEnforcesGrounding() {
        let report = GuardrailPipeline.standard().inspect(OutputContext(output: "Behauptung ohne Beleg"))
        XCTAssertEqual(report.verdict, .block)
        XCTAssertEqual(report.findings(from: "grounding").first?.code, "no_grounding")
    }

    /// Die Audit-Zeile darf den geprueften Inhalt nicht erneut ausbreiten.
    func testAuditLineCarriesNoOutputText() {
        let report = GuardrailPipeline(checks: [PIICheck()])
            .inspect(OutputContext(output: "Mail an max.mustermann@example.com"))
        XCTAssertTrue(report.auditLine.contains("verdict=block"))
        XCTAssertTrue(report.auditLine.contains("pii/pii_mail"))
        XCTAssertFalse(report.auditLine.contains("max.mustermann"))
    }
}
