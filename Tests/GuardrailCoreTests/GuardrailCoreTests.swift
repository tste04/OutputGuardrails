import XCTest
@testable import GuardrailCore

final class SeverityTests: XCTestCase {

    func testOrderingIsAscending() {
        XCTAssertLessThan(Severity.info, Severity.warning)
        XCTAssertLessThan(Severity.warning, Severity.violation)
    }
}

final class VerdictTests: XCTestCase {

    private func finding(_ severity: Severity) -> Finding {
        Finding(check: "t", severity: severity, code: "c", message: "m")
    }

    func testNoFindingsMeansAllow() {
        XCTAssertEqual(GuardrailReport.verdict(for: [], policy: .standard), .allow)
    }

    func testInfoAloneDoesNotFlag() {
        XCTAssertEqual(GuardrailReport.verdict(for: [finding(.info)], policy: .standard), .allow)
    }

    func testWarningFlags() {
        XCTAssertEqual(GuardrailReport.verdict(for: [finding(.warning)], policy: .standard), .flag)
    }

    func testViolationBlocks() {
        XCTAssertEqual(GuardrailReport.verdict(for: [finding(.violation)], policy: .standard), .block)
    }

    /// Das Urteil richtet sich nach dem schwersten Befund, nicht nach dem letzten.
    func testWorstFindingDecides() {
        let mixed = [finding(.info), finding(.violation), finding(.info)]
        XCTAssertEqual(GuardrailReport.verdict(for: mixed, policy: .standard), .block)
    }

    func testStrictPolicyBlocksEarlier() {
        XCTAssertEqual(GuardrailReport.verdict(for: [finding(.warning)], policy: .strict), .block)
    }

    func testObserveOnlyStillFlagsInfo() {
        XCTAssertEqual(GuardrailReport.verdict(for: [finding(.info)], policy: .observeOnly), .flag)
    }
}

final class GuardrailReportTests: XCTestCase {

    func testFindingsCanBeFilteredByCheck() {
        let report = GuardrailReport(verdict: .flag, findings: [
            Finding(check: "pii", severity: .violation, code: "a", message: ""),
            Finding(check: "schema", severity: .info, code: "b", message: ""),
        ])
        XCTAssertEqual(report.findings(from: "pii").map(\.code), ["a"])
        XCTAssertEqual(report.highestSeverity, .violation)
    }

    func testAuditLineListsSkippedChecks() {
        let report = GuardrailReport(verdict: .allow, findings: [], skippedChecks: ["consistency_llm"])
        XCTAssertTrue(report.auditLine.contains("skipped=[consistency_llm]"))
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
