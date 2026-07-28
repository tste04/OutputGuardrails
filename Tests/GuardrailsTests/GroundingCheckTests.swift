import XCTest
@testable import Guardrails
import GuardrailCore

final class GroundingCheckTests: XCTestCase {

    private func source(id: String, content: String, score: Double = 1.0) -> GroundingSource {
        GroundingSource(id: id, sourceType: "note", score: score, title: "Notiz", content: content)
    }

    /// „grounded-or-abstain": ohne Beleg gibt es keine Antwort, nicht bloss eine
    /// Warnung.
    func testNoSourcesIsAViolation() {
        let findings = GroundingCheck().inspect(
            OutputContext(output: "Das Projekt startet im Mai.", query: "Wann startet es?"))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.rule, RuleCatalog.noGrounding)
        XCTAssertEqual(findings.first?.severity, .violation)
    }

    func testWeakHitsBelowThresholdCountAsUngrounded() {
        let context = OutputContext(
            output: "Antwort", query: "Frage",
            sources: [source(id: "e1", content: "Text", score: 0.0001)])
        let findings = GroundingCheck().inspect(context)
        XCTAssertEqual(findings.first?.rule, RuleCatalog.noGrounding)
    }

    /// Ohne Belege waere jede Angabe unbelegt — ein Befund ist die ehrliche
    /// Aussage, hundert waeren Rauschen.
    func testUngroundedOutputYieldsExactlyOneFinding() {
        let context = OutputContext(output: "Anna Beispiel zahlte 4200 Euro am 12.03.2026.",
                                    query: "Frage")
        XCTAssertEqual(GroundingCheck().inspect(context).count, 1)
    }

    func testGroundedOutputReportsCitations() {
        let context = OutputContext(
            output: "Der Start ist im Mai.", query: "Wann?",
            sources: [source(id: "e1", content: "Der Start ist im Mai.")])
        let findings = GroundingCheck().inspect(context)
        XCTAssertEqual(findings.map(\.rule), [RuleCatalog.grounded])
        XCTAssertEqual(GroundingCheck().citations(for: context).map(\.id), ["e1"])
    }

    func testUnbackedNumberIsFlagged() {
        let context = OutputContext(
            output: "Das Budget liegt bei 4200 Euro.", query: "Wie hoch ist das Budget?",
            sources: [source(id: "e1", content: "Das Budget wurde besprochen.")])
        let findings = GroundingCheck().inspect(context)
        XCTAssertTrue(findings.contains { $0.rule == RuleCatalog.unbackedClaim && $0.evidence == "4200" })
        XCTAssertEqual(findings.first { $0.rule == RuleCatalog.unbackedClaim }?.severity, .warning)
    }

    func testNumberPresentInContextIsNotFlagged() {
        let context = OutputContext(
            output: "Das Budget liegt bei 4200 Euro.", query: "Wie hoch?",
            sources: [source(id: "e1", content: "Budget: 4200 Euro, beschlossen im Maerz.")])
        XCTAssertFalse(GroundingCheck().inspect(context).contains { $0.rule == RuleCatalog.unbackedClaim })
    }

    /// Bewusst konservativ: deutsche Substantive stehen gross, ein einzelnes
    /// grossgeschriebenes Wort ist deshalb kein Halluzinations-Signal.
    func testSingleCapitalizedWordIsNotFlagged() {
        let context = OutputContext(
            output: "Der Projektplan ist fertig.", query: "Status?",
            sources: [source(id: "e1", content: "Status besprochen.")])
        XCTAssertFalse(GroundingCheck().inspect(context).contains { $0.rule == RuleCatalog.unbackedClaim })
    }

    /// „Der Projektplan" ist eine grossgeschriebene Zweierkette und trotzdem kein
    /// Name — der fuehrende Artikel faellt weg, danach bleibt ein Wort uebrig.
    func testLeadingArticleDoesNotCreateANameChain() {
        let context = OutputContext(
            output: "Der Projektplan ist fertig. Das Ergebnis liegt vor.", query: "Status?",
            sources: [source(id: "e1", content: "Status besprochen.")])
        XCTAssertFalse(GroundingCheck().inspect(context).contains { $0.rule == RuleCatalog.unbackedClaim })
    }

    func testNameChainAfterArticleIsStillFlagged() {
        let context = OutputContext(
            output: "Der Anna Beispiel hat zugesagt.", query: "Wer hat zugesagt?",
            sources: [source(id: "e1", content: "Eine Zusage liegt vor.")])
        XCTAssertTrue(GroundingCheck().inspect(context).contains { $0.evidence == "Anna Beispiel" })
    }

    func testCompletelyUnknownNameChainIsFlagged() {
        let context = OutputContext(
            output: "Anna Beispiel hat zugesagt.", query: "Wer hat zugesagt?",
            sources: [source(id: "e1", content: "Eine Zusage liegt vor.")])
        let findings = GroundingCheck().inspect(context)
        XCTAssertTrue(findings.contains { $0.evidence == "Anna Beispiel" })
    }

    func testNameChainWithKnownWordIsNotFlagged() {
        let context = OutputContext(
            output: "Der Projektplan Nordlicht liegt vor.", query: "Was liegt vor?",
            sources: [source(id: "e1", content: "Projektplan Nordlicht wurde verteilt.")])
        XCTAssertFalse(GroundingCheck().inspect(context).contains { $0.rule == RuleCatalog.unbackedClaim })
    }

    func testCitationsCanBeDisabledForFreeformOutput() {
        let policy = GroundingPolicy(requireCitations: false, checkUnbackedClaims: false)
        let findings = GroundingCheck(policy: policy).inspect(OutputContext(output: "Hallo"))
        XCTAssertTrue(findings.filter { $0.severity > .info }.isEmpty)
    }
}
