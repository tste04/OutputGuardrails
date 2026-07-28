import XCTest
@testable import Guardrails
import GuardrailCore

final class SecretsCheckTests: XCTestCase {

    private let check = SecretsCheck()

    private func rules(_ text: String) -> [RuleID] {
        check.inspect(OutputContext(output: text)).map(\.rule)
    }

    func testPrivateKeyBlockIsFound() {
        XCTAssertEqual(rules("-----BEGIN RSA PRIVATE KEY-----\nMIIE..."),
                       [RuleCatalog.secretPrivateKey])
    }

    func testAWSKeyIsFound() {
        XCTAssertEqual(rules("Key: AKIAIOSFODNN7EXAMPLE"), [RuleCatalog.secretAWSKey])
    }

    func testGitHubTokenIsFound() {
        XCTAssertEqual(rules("token ghp_" + String(repeating: "a", count: 36)),
                       [RuleCatalog.secretGitHubToken])
    }

    func testSlackTokenIsFound() {
        XCTAssertEqual(rules("xoxb-1234567890-abcdefghij"), [RuleCatalog.secretSlackToken])
    }

    func testJWTIsFound() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1g"
        XCTAssertEqual(rules("Bearer \(jwt)"), [RuleCatalog.secretJWT])
    }

    func testAPIKeyIsFound() {
        XCTAssertEqual(rules("sk-abcdefghijklmnopqrstuvwxyz012345"), [RuleCatalog.secretAPIKey])
    }

    /// Bewusst nur Formate mit strukturellem Anker: ein Base64-Block oder eine
    /// lange Kennung in einer legitimen Antwort ist kein Vorfall.
    func testHighEntropyTextAloneIsNotASecret() {
        XCTAssertTrue(rules("Pruefsumme: 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b").isEmpty)
        XCTAssertTrue(rules("Basis64: TWFubiBpc3QgZWluIEJlaXNwaWVs").isEmpty)
        XCTAssertTrue(rules("Auftrag AKIA-1234 wurde erteilt.").isEmpty)
    }

    func testEachFindingIsReportedOnce() {
        let text = "AKIAIOSFODNN7EXAMPLE und nochmal AKIAIOSFODNN7EXAMPLE"
        XCTAssertEqual(rules(text).count, 1)
    }

    /// Der Klarwert darf nicht im Befund stehen — sonst steht der Schluessel
    /// anschliessend im Log statt in der Antwort.
    func testEvidenceIsMasked() {
        let finding = check.inspect(OutputContext(output: "AKIAIOSFODNN7EXAMPLE")).first
        XCTAssertNotNil(finding?.evidence)
        XCTAssertFalse(finding?.evidence?.contains("AKIAIOSFODNN7EXAMPLE") ?? true)
        XCTAssertTrue(finding?.evidence?.hasPrefix("AKIAIO") ?? false)
    }

    func testSecretsAreViolations() {
        let finding = check.inspect(OutputContext(output: "sk-abcdefghijklmnopqrstuvwxyz012345")).first
        XCTAssertEqual(finding?.severity, .violation)
        XCTAssertEqual(finding?.category, .secret)
    }
}
