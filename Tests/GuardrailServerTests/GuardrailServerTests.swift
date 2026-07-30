import XCTest
@testable import GuardrailServer
import Guardrails
import GuardrailCore

// MARK: - Policy-Datei

final class GuardrailConfigTests: XCTestCase {

    /// Eine leere Datei ergibt die Voreinstellung — wer nur einen Wert aendern
    /// will, soll nicht die ganze Konfiguration abschreiben muessen.
    func testEmptyObjectYieldsDefaults() throws {
        let config = try GuardrailConfig.load(Data("{}".utf8))
        XCTAssertEqual(config.policy, .standard)
        XCTAssertEqual(config.checks, GuardrailConfig.CheckName.allCases)
    }

    func testPartialConfigKeepsOtherDefaults() throws {
        let config = try GuardrailConfig.load(Data(#"{"policy":{"approvalThreshold":0.75}}"#.utf8))
        XCTAssertEqual(config.policy.approvalThreshold, 0.75)
        XCTAssertEqual(config.policy.blockAt, .violation)
        XCTAssertEqual(config.grounding.minScore, GroundingPolicy.standard.minScore)
    }

    func testSuppressionsAreRead() throws {
        let config = try GuardrailConfig.load(
            Data(#"{"policy":{"suppressedRules":["GRO-002","PII-001"]}}"#.utf8))
        XCTAssertEqual(config.policy.suppressedRules, [RuleCatalog.unbackedClaim, RuleCatalog.piiPerson])
    }

    /// Fail-closed: eine kaputte Policy-Datei darf nicht stillschweigend zur
    /// Voreinstellung werden.
    func testBrokenFileThrows() {
        XCTAssertThrowsError(try GuardrailConfig.load(Data("kein json".utf8)))
        XCTAssertThrowsError(try GuardrailConfig.load(Data(#"{"policy":{"blockAt":"kaputt"}}"#.utf8)))
    }

    func testRoundTrip() throws {
        var config = GuardrailConfig()
        config.policy.approvalThreshold = 0.5
        config.compliance.forbiddenPatterns = ["garantiert"]
        let decoded = try GuardrailConfig.load(config.encoded())
        XCTAssertEqual(decoded, config)
    }

    // MARK: Pipeline-Bau

    func testCheckListControlsTheStages() {
        var config = GuardrailConfig()
        config.checks = [.pii, .secrets]
        let names = config.pipeline().checks.map(\.name)
        XCTAssertEqual(names, ["pii", "secrets"])
    }

    /// Ohne Modell keine LLM-Stufe — sonst stuende im Bericht dauerhaft ein
    /// „uebersprungen", das niemand abstellen kann.
    func testLLMStageOnlyWithModel() {
        XCTAssertTrue(GuardrailConfig().pipeline(withLLM: false).asyncChecks.isEmpty)
        XCTAssertEqual(GuardrailConfig().pipeline(withLLM: true).asyncChecks.map(\.name),
                       ["consistency_llm"])
    }

    func testLLMStageNeedsConsistencyEnabled() {
        var config = GuardrailConfig()
        config.checks = [.pii]
        XCTAssertTrue(config.pipeline(withLLM: true).asyncChecks.isEmpty)
    }
}

// MARK: - JSON-Schema

final class SchemaJSONTests: XCTestCase {

    func testObjectWithRequiredIsMapped() {
        let json: [String: Any] = [
            "type": "object",
            "properties": ["title": ["type": "string"], "count": ["type": "integer"]],
            "required": ["title"],
        ]
        guard case .object(let properties, let required, let allowAdditional)?
                = SchemaNode.fromJSONSchema(json) else {
            return XCTFail("kein Objekt")
        }
        XCTAssertEqual(properties["title"], .string())
        XCTAssertEqual(properties["count"], .integer)
        XCTAssertEqual(required, ["title"])
        XCTAssertTrue(allowAdditional)
    }

    func testAdditionalPropertiesFalseIsHonoured() {
        let json: [String: Any] = ["type": "object", "properties": [:], "additionalProperties": false]
        guard case .object(_, _, let allowAdditional)? = SchemaNode.fromJSONSchema(json) else {
            return XCTFail("kein Objekt")
        }
        XCTAssertFalse(allowAdditional)
    }

    func testEnumIsMapped() {
        let json: [String: Any] = ["type": "string", "enum": ["low", "high"]]
        XCTAssertEqual(SchemaNode.fromJSONSchema(json), .string(enumValues: ["low", "high"]))
    }

    func testArrayBoundsAreMapped() {
        let json: [String: Any] = ["type": "array", "items": ["type": "string"], "minItems": 1]
        XCTAssertEqual(SchemaNode.fromJSONSchema(json),
                       .array(element: .string(), minItems: 1, maxItems: nil))
    }

    /// Nullable-Typen kommen als Liste — der erste nicht-null Eintrag zaehlt.
    func testTypeListPicksTheNonNullEntry() {
        XCTAssertEqual(SchemaNode.fromJSONSchema(["type": ["string", "null"]]), .string())
    }

    func testPropertiesWithoutTypeAreTreatedAsObject() {
        guard case .object? = SchemaNode.fromJSONSchema(["properties": ["a": ["type": "string"]]]) else {
            return XCTFail("kein Objekt")
        }
    }

    /// Unbekannte Schluesselwoerter duerfen keine Pruefung verhindern — was
    /// nicht abgebildet wird, wird eben nicht geprueft.
    func testUnknownKeywordsDoNotFail() {
        let json: [String: Any] = ["type": "object", "properties": ["a": ["$ref": "#/x"]],
                                   "unevaluatedProperties": false]
        guard case .object(let properties, _, _)? = SchemaNode.fromJSONSchema(json) else {
            return XCTFail("kein Objekt")
        }
        XCTAssertEqual(properties["a"], .any)
    }

    func testEmptySchemaIsNil() {
        XCTAssertNil(SchemaNode.fromJSONSchema([:]))
    }
}

// MARK: - Dienst

final class GuardrailServiceTests: XCTestCase {

    private func inspect(_ json: String,
                         config: GuardrailConfig = GuardrailConfig()) async -> (Int, [String: Any]) {
        let (status, body) = await GuardrailService(config: config).inspect(requestJSON: Data(json.utf8))
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        return (status, object)
    }

    func testMissingOutputIsARequestError() async {
        let (status, body) = await inspect(#"{"query":"x"}"#)
        XCTAssertEqual(status, 400)
        XCTAssertNotNil(body["error"])
    }

    func testNonObjectIsARequestError() async {
        let (status, _) = await inspect("[1,2,3]")
        XCTAssertEqual(status, 400)
    }

    func testGroundedOutputIsAllowed() async {
        let (status, body) = await inspect("""
        {"output":"Der Start ist im Mai.","query":"Wann?",
         "sources":[{"id":"e1","sourceType":"note","content":"Der Start ist im Mai."}]}
        """)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["verdict"] as? String, "allow")
        XCTAssertEqual((body["citations"] as? [[String: Any]])?.count, 1)
    }

    func testFindingsCarryRuleAndCategory() async {
        let (_, body) = await inspect("""
        {"output":"IBAN DE89370400440532013000",
         "sources":[{"id":"e1","sourceType":"note","content":"x"}]}
        """)
        let findings = body["findings"] as? [[String: Any]] ?? []
        XCTAssertTrue(findings.contains { $0["rule"] as? String == "PII-004" })
        XCTAssertTrue(findings.contains { $0["category"] as? String == "pii" })
        XCTAssertEqual(body["verdict"] as? String, "block")
    }

    /// Der Bericht ist die Schnittstelle zu Approval und Audit — kein Feld darf
    /// den geprueften Ausgang tragen.
    func testReportCarriesNoOutputText() async {
        let (_, body) = await inspect("""
        {"output":"Mail an max.mustermann@example.com",
         "sources":[{"id":"e1","sourceType":"note","content":"x"}]}
        """)
        let encoded = String(data: GuardrailService.encode(body), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("max.mustermann"))
        XCTAssertTrue(encoded.contains("PII-002"))
    }

    func testSchemaFromRequestIsApplied() async {
        let (_, body) = await inspect("""
        {"output":"{\\"title\\":\\"Fix\\"}",
         "sources":[{"id":"e1","sourceType":"note","content":"x"}],
         "schema":{"type":"object","properties":{"title":{"type":"string"},
                   "priority":{"type":"string"}},"required":["title","priority"]}}
        """)
        let findings = body["findings"] as? [[String: Any]] ?? []
        XCTAssertTrue(findings.contains { $0["rule"] as? String == "SCH-002" })
    }

    func testApprovalFlagIsExposed() async {
        let (_, body) = await inspect("""
        {"output":"Das Budget liegt bei 4200 Euro.","query":"Wie hoch?",
         "sources":[{"id":"e1","sourceType":"note","content":"Budget besprochen."}]}
        """)
        XCTAssertEqual(body["verdict"] as? String, "flag")
        XCTAssertEqual(body["requiresApproval"] as? Bool, true)
        XCTAssertEqual((body["riskScore"] as? NSNumber)?.doubleValue ?? 0, 0.20, accuracy: 0.0001)
    }

    func testCatalogIsSerialisable() {
        let rules = GuardrailService.encodeCatalog()["rules"] as? [[String: Any]] ?? []
        XCTAssertEqual(rules.count, RuleCatalog.all.count)
        XCTAssertTrue(rules.contains { $0["id"] as? String == "SEC-001" })
    }
}

// MARK: - HTTP-Huelle

final class GuardrailHTTPServiceTests: XCTestCase {

    private let http = GuardrailHTTPService(service: GuardrailService())

    private func request(_ method: String, _ path: String, body: String = "") -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: [:], body: Data(body.utf8))
    }

    private func json(_ body: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    func testHealthReportsThePolicy() async {
        let (status, body) = await http.handle(request("GET", "/health"))
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json(body)["status"] as? String, "ok")
        XCTAssertEqual(json(body)["blockAt"] as? String, "violation")
    }

    func testRulesEndpointReturnsTheCatalog() async {
        let (status, body) = await http.handle(request("GET", "/rules"))
        XCTAssertEqual(status, 200)
        XCTAssertEqual((json(body)["rules"] as? [[String: Any]])?.count, RuleCatalog.all.count)
    }

    func testInspectNeedsPOST() async {
        let (status, _) = await http.handle(request("GET", "/inspect"))
        XCTAssertEqual(status, 405)
    }

    func testUnknownPathIs404() async {
        let (status, _) = await http.handle(request("GET", "/nope"))
        XCTAssertEqual(status, 404)
    }

    /// `/inspect?trace=1` ist derselbe Endpunkt.
    func testQueryStringIsIgnored() async {
        let (status, _) = await http.handle(request("GET", "/health?verbose=1"))
        XCTAssertEqual(status, 200)
    }

    func testInspectRoundTrip() async {
        let (status, body) = await http.handle(request("POST", "/inspect", body: """
        {"output":"Der Start ist im Mai.","query":"Wann?",
         "sources":[{"id":"e1","sourceType":"note","content":"Der Start ist im Mai."}]}
        """))
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json(body)["verdict"] as? String, "allow")
    }
}
