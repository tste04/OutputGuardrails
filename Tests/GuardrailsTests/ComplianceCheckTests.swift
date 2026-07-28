import XCTest
@testable import Guardrails
import GuardrailCore

final class ComplianceCheckTests: XCTestCase {

    private let disclaimer = CompliancePolicy.RequiredDisclaimer(
        id: "anlageberatung",
        triggerPatterns: ["Rendite", "Anlage"],
        satisfiedByPatterns: ["keine Anlageberatung"],
        message: "Hinweis 'keine Anlageberatung' fehlt.")

    private func rules(_ text: String, _ policy: CompliancePolicy) -> [RuleID] {
        ComplianceCheck(policy: policy).inspect(OutputContext(output: text)).map(\.rule)
    }

    /// Ohne Konfiguration meldet die Stufe nichts. Eine mitgelieferte
    /// Beispielliste wuerde als „das reicht dann wohl" missverstanden.
    func testEmptyPolicyReportsNothing() {
        XCTAssertTrue(rules("Garantiert risikofrei, versprochen.", .empty).isEmpty)
    }

    func testForbiddenTermIsFound() {
        let policy = CompliancePolicy(forbiddenPatterns: ["garantiert risikofrei"])
        XCTAssertEqual(rules("Das ist garantiert risikofrei.", policy), [RuleCatalog.forbiddenTerm])
    }

    func testForbiddenTermIsCaseInsensitiveByDefault() {
        let policy = CompliancePolicy(forbiddenPatterns: ["garantiert"])
        XCTAssertEqual(rules("GARANTIERT gut.", policy), [RuleCatalog.forbiddenTerm])
    }

    func testCaseSensitivityCanBeDemanded() {
        let policy = CompliancePolicy(forbiddenPatterns: ["Garantiert"], caseInsensitive: false)
        XCTAssertTrue(rules("garantiert gut.", policy).isEmpty)
        XCTAssertEqual(rules("Garantiert gut.", policy), [RuleCatalog.forbiddenTerm])
    }

    // MARK: - Pflichthinweise

    func testDisclaimerIsDemandedOnlyWhenTriggered() {
        let policy = CompliancePolicy(requiredDisclaimers: [disclaimer])
        XCTAssertTrue(rules("Das Wetter wird gut.", policy).isEmpty)
        XCTAssertEqual(rules("Die Rendite liegt bei 4 Prozent.", policy),
                       [RuleCatalog.missingDisclaimer])
    }

    func testSatisfiedDisclaimerIsNotReported() {
        let policy = CompliancePolicy(requiredDisclaimers: [disclaimer])
        XCTAssertTrue(rules("Die Rendite liegt bei 4 Prozent. Dies ist keine Anlageberatung.",
                            policy).isEmpty)
    }

    /// Ohne Trigger gilt der Hinweis immer.
    func testDisclaimerWithoutTriggerAlwaysApplies() {
        let always = CompliancePolicy.RequiredDisclaimer(
            id: "ki-hinweis", satisfiedByPatterns: ["KI-generiert"],
            message: "KI-Kennzeichnung fehlt.")
        let policy = CompliancePolicy(requiredDisclaimers: [always])
        XCTAssertEqual(rules("Beliebiger Text.", policy), [RuleCatalog.missingDisclaimer])
        XCTAssertTrue(rules("Beliebiger Text. (KI-generiert)", policy).isEmpty)
    }

    func testDisclaimerEvidenceIsItsIdentifier() {
        let policy = CompliancePolicy(requiredDisclaimers: [disclaimer])
        let finding = ComplianceCheck(policy: policy)
            .inspect(OutputContext(output: "Die Rendite steigt.")).first
        XCTAssertEqual(finding?.evidence, "anlageberatung")
        XCTAssertEqual(finding?.message, "Hinweis 'keine Anlageberatung' fehlt.")
    }

    // MARK: - Laenge

    func testLengthLimitIsEnforced() {
        let policy = CompliancePolicy(maxOutputCharacters: 10)
        let findings = ComplianceCheck(policy: policy)
            .inspect(OutputContext(output: String(repeating: "x", count: 11)))
        XCTAssertEqual(findings.map(\.rule), [RuleCatalog.outputTooLong])
        XCTAssertEqual(findings.first?.evidence, "11/10")
        XCTAssertEqual(findings.first?.severity, .warning)
    }

    func testLengthAtTheLimitPasses() {
        let policy = CompliancePolicy(maxOutputCharacters: 10)
        XCTAssertTrue(rules(String(repeating: "x", count: 10), policy).isEmpty)
    }

    // MARK: - Serialisierung

    /// Die Compliance-Regeln stehen in der Policy-Datei — sie muessen den Weg
    /// durch JSON unveraendert ueberstehen.
    func testPolicySurvivesJSONRoundTrip() throws {
        let policy = CompliancePolicy(forbiddenPatterns: ["garantiert"],
                                      requiredDisclaimers: [disclaimer],
                                      maxOutputCharacters: 500)
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(CompliancePolicy.self, from: data)
        XCTAssertEqual(decoded, policy)
    }
}
