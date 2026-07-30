import XCTest
@testable import GuardrailCore

private func finding(_ rule: RuleID) -> Finding {
    Finding(check: "t", rule: rule, message: "m")
}

final class SeverityTests: XCTestCase {

    func testOrderingIsAscending() {
        XCTAssertLessThan(Severity.info, Severity.warning)
        XCTAssertLessThan(Severity.warning, Severity.violation)
    }

    /// Schweregrade stehen in der Policy-Datei — dort muessen sie lesbar sein.
    func testRawValuesAreReadable() {
        XCTAssertEqual(Severity.violation.rawValue, "violation")
        XCTAssertEqual(Severity(rawValue: "warning"), .warning)
    }
}

final class RuleCatalogTests: XCTestCase {

    func testEveryRuleIsResolvable() {
        for rule in RuleCatalog.all {
            XCTAssertEqual(RuleCatalog.rule(rule.id)?.id, rule.id)
        }
    }

    func testRuleIDsAreUnique() {
        let ids = RuleCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Doppelte Regel-ID im Katalog")
    }

    /// Info-Regeln duerfen kein Risiko erzeugen — sonst treibt ein „alles in
    /// Ordnung" den Score nach oben.
    func testInfoRulesCarryNoWeight() {
        for rule in RuleCatalog.all where rule.severity == .info {
            XCTAssertEqual(rule.weight, 0, "\(rule.id) ist info, wiegt aber \(rule.weight)")
        }
    }

    func testWeightsAreWithinRange() {
        for rule in RuleCatalog.all {
            XCTAssertTrue((0...1).contains(rule.weight), "\(rule.id) wiegt \(rule.weight)")
        }
    }

    /// Fail-closed: wer eine Regel ausloest, die nicht im Katalog steht, hat
    /// einen Fehler gemacht — der darf nicht als unauffaellig durchgehen.
    func testUnknownRuleResolvesToViolation() {
        let resolved = RuleCatalog.resolve("XXX-999")
        XCTAssertEqual(resolved.severity, .violation)
        XCTAssertEqual(resolved.weight, 1.0)
    }

    /// Die SEC-Reihe teilt sich die IDs mit der Eingangs-Firewall im AIGateway.
    func testSecretRuleIDsMatchTheGatewayFamily() {
        XCTAssertEqual(RuleCatalog.secretPrivateKey, "SEC-001")
        XCTAssertEqual(RuleCatalog.secretAWSKey, "SEC-002")
    }
}

final class FindingTests: XCTestCase {

    func testSeverityAndWeightComeFromTheCatalog() {
        let f = finding(RuleCatalog.piiIBAN)
        XCTAssertEqual(f.severity, .violation)
        XCTAssertEqual(f.category, .pii)
        XCTAssertEqual(f.weight, RuleCatalog.resolve(RuleCatalog.piiIBAN).weight)
    }
}

final class VerdictTests: XCTestCase {

    func testNoFindingsMeansAllow() {
        XCTAssertEqual(GuardrailReport.verdict(for: [], policy: .standard), .allow)
    }

    func testInfoAloneDoesNotFlag() {
        XCTAssertEqual(GuardrailReport.verdict(for: [finding(RuleCatalog.grounded)],
                                               policy: .standard), .allow)
    }

    func testWarningFlags() {
        XCTAssertEqual(GuardrailReport.verdict(for: [finding(RuleCatalog.unbackedClaim)],
                                               policy: .standard), .flag)
    }

    func testViolationBlocks() {
        XCTAssertEqual(GuardrailReport.verdict(for: [finding(RuleCatalog.noGrounding)],
                                               policy: .standard), .block)
    }

    /// Das Urteil richtet sich nach dem schwersten Befund, nicht nach dem letzten.
    func testWorstFindingDecides() {
        let mixed = [finding(RuleCatalog.grounded), finding(RuleCatalog.noGrounding),
                     finding(RuleCatalog.grounded)]
        XCTAssertEqual(GuardrailReport.verdict(for: mixed, policy: .standard), .block)
    }

    func testStrictPolicyBlocksEarlier() {
        XCTAssertEqual(GuardrailReport.verdict(for: [finding(RuleCatalog.unbackedClaim)],
                                               policy: .strict), .block)
    }

    func testObserveOnlyStillFlagsInfo() {
        XCTAssertEqual(GuardrailReport.verdict(for: [finding(RuleCatalog.grounded)],
                                               policy: .observeOnly), .flag)
    }

    /// Der Beobachtungsbetrieb wird eingesetzt, um die Guardrails
    /// scharfzuschalten, ohne den Betrieb anzuhalten. Blockte er bei
    /// Regelbruch, waere er ununterscheidbar von `.standard`.
    func testObserveOnlyNeverBlocks() {
        let violation = [finding(RuleCatalog.noGrounding)]
        XCTAssertEqual(GuardrailReport.verdict(for: violation, policy: .observeOnly), .flag)
        XCTAssertEqual(GuardrailReport.verdict(for: violation, policy: .standard), .block)

        let report = GuardrailReport.make(findings: violation, policy: .observeOnly)
        XCTAssertEqual(report.verdict, .flag)
        XCTAssertFalse(report.findings.isEmpty, "beobachten heisst melden, nicht schweigen")
        XCTAssertGreaterThan(report.riskScore, 0)
    }

    /// Bestehende Policy-Dateien kennen `blocksOutput` nicht — sie muessen
    /// weiter blocken.
    func testPolicyFileWithoutBlocksOutputStillBlocks() throws {
        let policy = try JSONDecoder().decode(
            GuardrailPolicy.self, from: Data(#"{"blockAt":"violation"}"#.utf8))
        XCTAssertTrue(policy.blocksOutput)
        XCTAssertEqual(GuardrailReport.verdict(for: [finding(RuleCatalog.noGrounding)],
                                               policy: policy), .block)
    }
}

final class RiskScoreTests: XCTestCase {

    /// Additiv: drei mittelschwere Befunde sollen schwerer wiegen als einer.
    func testWeightsAccumulate() {
        let two = [finding(RuleCatalog.unbackedClaim), finding(RuleCatalog.unbackedClaim)]
        XCTAssertEqual(GuardrailReport.riskScore(for: two), 0.40, accuracy: 0.0001)
    }

    func testScoreIsCappedAtOne() {
        let many = Array(repeating: finding(RuleCatalog.piiIBAN), count: 5)
        XCTAssertEqual(GuardrailReport.riskScore(for: many), 1.0)
    }

    func testInfoFindingsDoNotRaiseRisk() {
        XCTAssertEqual(GuardrailReport.riskScore(for: [finding(RuleCatalog.grounded)]), 0)
    }
}

final class ApprovalTests: XCTestCase {

    /// „Low Risk → Auto-Execute, High Risk → Human Approval" aus dem Zielbild.
    func testCleanOutputNeedsNoApproval() {
        let report = GuardrailReport.make(findings: [finding(RuleCatalog.grounded)], policy: .standard)
        XCTAssertEqual(report.verdict, .allow)
        XCTAssertFalse(report.requiresApproval)
    }

    func testFlaggedOutputNeedsApproval() {
        let report = GuardrailReport.make(findings: [finding(RuleCatalog.unbackedClaim)],
                                          policy: .standard)
        XCTAssertEqual(report.verdict, .flag)
        XCTAssertTrue(report.requiresApproval)
    }

    /// Ein blockierter Ausgang geht gar nicht erst weiter — Freigabe ist die
    /// Frage fuer alles, was durchkommt.
    func testBlockedOutputIsNotAnApprovalCase() {
        let report = GuardrailReport.make(findings: [finding(RuleCatalog.noGrounding)],
                                          policy: .standard)
        XCTAssertEqual(report.verdict, .block)
        XCTAssertFalse(report.requiresApproval)
    }

    func testThresholdCanRaiseTheBar() {
        let lenient = GuardrailPolicy(flagAt: .violation, approvalThreshold: 0.9)
        let report = GuardrailReport.make(findings: [finding(RuleCatalog.unbackedClaim)],
                                          policy: lenient)
        XCTAssertEqual(report.verdict, .allow)
        XCTAssertFalse(report.requiresApproval)
    }
}

final class SuppressionTests: XCTestCase {

    private var policy: GuardrailPolicy {
        var p = GuardrailPolicy.standard
        p.suppressedRules = [RuleCatalog.unbackedClaim]
        return p
    }

    func testSuppressedRuleDoesNotAffectTheVerdict() {
        let report = GuardrailReport.make(findings: [finding(RuleCatalog.unbackedClaim)],
                                          policy: policy)
        XCTAssertEqual(report.verdict, .allow)
        XCTAssertEqual(report.riskScore, 0)
    }

    /// Unterdrueckt heisst nicht unsichtbar — der Befund bleibt im Bericht.
    func testSuppressedRuleStaysVisible() {
        let report = GuardrailReport.make(findings: [finding(RuleCatalog.unbackedClaim)],
                                          policy: policy)
        XCTAssertEqual(report.suppressed.map(\.rule), [RuleCatalog.unbackedClaim])
        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertTrue(report.auditLine.contains("suppressed=[GRO-002]"))
    }

    func testSuppressionDoesNotHideOtherRules() {
        let report = GuardrailReport.make(
            findings: [finding(RuleCatalog.unbackedClaim), finding(RuleCatalog.piiIBAN)],
            policy: policy)
        XCTAssertEqual(report.verdict, .block)
        XCTAssertEqual(report.findings.map(\.rule), [RuleCatalog.piiIBAN])
    }
}

final class GuardrailReportTests: XCTestCase {

    func testFindingsCanBeFilteredByCheckAndCategory() {
        let report = GuardrailReport(verdict: .flag, findings: [
            Finding(check: "pii", rule: RuleCatalog.piiMail, message: ""),
            Finding(check: "schema", rule: RuleCatalog.schemaOK, message: ""),
        ])
        XCTAssertEqual(report.findings(from: "pii").map(\.rule), [RuleCatalog.piiMail])
        XCTAssertEqual(report.findings(in: .schema).map(\.rule), [RuleCatalog.schemaOK])
        XCTAssertEqual(report.highestSeverity, .violation)
    }

    func testAuditLineListsSkippedChecks() {
        let report = GuardrailReport(verdict: .allow, findings: [], skippedChecks: ["consistency_llm"])
        XCTAssertTrue(report.auditLine.contains("skipped=[consistency_llm]"))
    }

    func testAuditLineCarriesRiskAndApproval() {
        let report = GuardrailReport.make(findings: [finding(RuleCatalog.unbackedClaim)],
                                          policy: .standard)
        XCTAssertTrue(report.auditLine.contains("risk=0.20"))
        XCTAssertTrue(report.auditLine.contains("approval=true"))
        XCTAssertTrue(report.auditLine.contains("GRO-002"))
    }
}

final class SchemaNodeTests: XCTestCase {

    func testTypeNamesAreStable() {
        XCTAssertEqual(SchemaNode.string().typeName, "string")
        XCTAssertEqual(SchemaNode.array(element: .any).typeName, "array")
        XCTAssertEqual(SchemaNode.object(properties: [:]).typeName, "object")
    }
}

final class CitationTests: XCTestCase {

    func testCitationIsDerivedFromSource() {
        let source = GroundingSource(id: "e1", sourceType: "note", score: 0.5, content: "x")
        let citation = Citation(source: source)
        XCTAssertEqual(citation.id, "e1")
        XCTAssertEqual(citation.origin, .memory)
        XCTAssertEqual(citation.score, 0.5)
    }
}

final class FactTripleTests: XCTestCase {

    func testTripleStringIsReadable() {
        let fact = FactTriple(id: "f1", subject: "Max", predicate: "arbeitet_bei", object: "Firma A")
        XCTAssertEqual(fact.tripleString, "Max arbeitet_bei Firma A")
    }
}
