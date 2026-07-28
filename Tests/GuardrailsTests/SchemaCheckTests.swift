import XCTest
@testable import Guardrails
import GuardrailCore

final class SchemaCheckTests: XCTestCase {

    private let ticketSchema = SchemaNode.object(
        properties: [
            "title": .string(),
            "priority": .string(enumValues: ["low", "high"]),
            "storyPoints": .integer,
            "labels": .array(element: .string(), minItems: 1),
        ],
        required: ["title", "priority"])

    private func report(_ output: String, schema: SchemaNode? = nil) -> [Finding] {
        SchemaCheck().inspect(OutputContext(output: output, expectedSchema: schema ?? ticketSchema))
    }

    func testNoSchemaMeansNoFindings() {
        XCTAssertTrue(SchemaCheck().inspect(OutputContext(output: "beliebiger Text")).isEmpty)
    }

    func testValidObjectPasses() {
        let findings = report("""
        {"title": "Fix", "priority": "high", "storyPoints": 3, "labels": ["bug"]}
        """)
        XCTAssertEqual(findings.map(\.rule), [RuleCatalog.schemaOK])
    }

    func testMissingRequiredFieldIsAViolation() {
        let findings = report(#"{"title": "Fix"}"#)
        XCTAssertEqual(findings.map(\.rule), [RuleCatalog.missingRequired])
        XCTAssertEqual(findings.first?.evidence, "$.priority")
        XCTAssertEqual(findings.first?.severity, .violation)
    }

    func testTypeMismatchIsReportedWithPath() {
        let findings = report(#"{"title": "Fix", "priority": "high", "storyPoints": "drei"}"#)
        XCTAssertEqual(findings.map(\.rule), [RuleCatalog.typeMismatch])
        XCTAssertEqual(findings.first?.evidence, "$.storyPoints")
    }

    func testEnumViolationIsCaught() {
        let findings = report(#"{"title": "Fix", "priority": "urgent"}"#)
        XCTAssertEqual(findings.map(\.rule), [RuleCatalog.enumMismatch])
    }

    /// Ein `true` darf nicht als Zahl durchgehen — in JSON ist es eine NSNumber.
    func testBooleanIsNotAnInteger() {
        let findings = report(#"{"title": "Fix", "priority": "low", "storyPoints": true}"#)
        XCTAssertEqual(findings.map(\.rule), [RuleCatalog.typeMismatch])
    }

    func testFloatIsNotAnInteger() {
        let findings = report(#"{"title": "Fix", "priority": "low", "storyPoints": 2.5}"#)
        XCTAssertEqual(findings.map(\.rule), [RuleCatalog.typeMismatch])
    }

    func testArrayBoundsAreChecked() {
        let findings = report(#"{"title": "Fix", "priority": "low", "labels": []}"#)
        XCTAssertEqual(findings.map(\.rule), [RuleCatalog.tooFewItems])
        XCTAssertEqual(findings.first?.evidence, "$.labels")
    }

    func testNestedArrayElementPathIsPrecise() {
        let findings = report(#"{"title": "Fix", "priority": "low", "labels": ["ok", 7]}"#)
        XCTAssertEqual(findings.first?.evidence, "$.labels[1]")
    }

    func testUnexpectedPropertyOnlyWhenForbidden() {
        let strict = SchemaNode.object(properties: ["a": .string()], required: [], allowAdditional: false)
        XCTAssertEqual(report(#"{"a": "x", "b": "y"}"#, schema: strict).map(\.rule), [RuleCatalog.unexpectedProperty])

        let lenient = SchemaNode.object(properties: ["a": .string()])
        XCTAssertEqual(report(#"{"a": "x", "b": "y"}"#, schema: lenient).map(\.rule), [RuleCatalog.schemaOK])
    }

    /// Modelle rahmen JSON gern in Fliesstext oder ```json-Zaeune — das ist ein
    /// Formatierungs-, kein Strukturfehler.
    func testJSONIsExtractedFromProse() {
        let output = """
        Klar, hier das Ticket:
        ```json
        {"title": "Fix", "priority": "high"}
        ```
        Sag Bescheid, wenn etwas fehlt.
        """
        XCTAssertEqual(report(output).map(\.rule), [RuleCatalog.schemaOK])
    }

    func testExtractionCanBeTurnedOff() {
        let strict = SchemaCheck(extractFromProse: false)
        let findings = strict.inspect(OutputContext(
            output: "Hier: {\"title\": \"Fix\", \"priority\": \"high\"}",
            expectedSchema: ticketSchema))
        XCTAssertEqual(findings.map(\.rule), [RuleCatalog.invalidJSON])
    }

    func testGarbageIsInvalidJSON() {
        XCTAssertEqual(report("Tut mir leid, das kann ich nicht.").map(\.rule), [RuleCatalog.invalidJSON])
    }
}
