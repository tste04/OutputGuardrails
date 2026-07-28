import XCTest
@testable import Guardrails
import GuardrailCore

/// Die Konformanz-Vektoren stammen aus dem Zielbild-Repo
/// (`Zielbild/conformance/pii-vectors.txt`) und liegen hier als Kopie im
/// Test-Bundle. AIGateway prueft dieselben Zeilen gegen seine Eingangs-PII —
/// so kann die Erkennungs-Semantik zwischen den Bausteinen nicht driften.
/// Weicht diese Kopie vom Zielbild-Repo ab, schlaegt dort `make conformance` an.
final class PIIConformanceTests: XCTestCase {

    private func loadVectors() throws -> [(expectation: String, text: String)] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Vectors/pii-vectors", withExtension: "txt"),
                                "Vektor-Datei fehlt im Test-Bundle")
        let content = try String(contentsOf: url, encoding: .utf8)
        return content.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#"), !line.isEmpty else { return nil }
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }

    func testConformanceVectors() throws {
        let check = PIICheck()
        let vectors = try loadVectors()
        XCTAssertFalse(vectors.isEmpty, "Vektoren wurden nicht geladen")

        for vector in vectors {
            let matches = check.detect(in: vector.text)
            switch vector.expectation {
            case "hit":
                XCTAssertFalse(matches.isEmpty,
                               "Erwartet PII-Treffer, aber nichts gefunden: \(vector.text)")
            case "pass":
                XCTAssertTrue(matches.isEmpty,
                              "Fehlalarm \(matches.map(\.category.rawValue)) in: \(vector.text)")
            default:
                XCTFail("Unbekannte Erwartung '\(vector.expectation)'")
            }
        }
    }
}

final class PIICheckTests: XCTestCase {

    func testCategoriesAreIdentifiedIndividually() {
        let check = PIICheck()
        XCTAssertEqual(check.detect(in: "mail: a.b@example.com").first?.category, .mail)
        XCTAssertEqual(check.detect(in: "DE89370400440532013000").first?.category, .iban)
        XCTAssertEqual(check.detect(in: "+49 170 1234567").first?.category, .phone)
    }

    /// Der Grund fuer die strukturellen Anker in den Mustern: eine IP-Adresse,
    /// eine Belegnummer und eine Uhrzeit sind keine Personendaten.
    func testStructuralAnchorsPreventFalsePositives() {
        let check = PIICheck()
        XCTAssertTrue(check.detect(in: "Server 127.0.0.1 Port 8787").isEmpty)
        XCTAssertTrue(check.detect(in: "Beleg ORD-2026-0042 vom 14.30 Uhr").isEmpty)
        XCTAssertTrue(check.detect(in: "Der Server läuft stabil.").isEmpty)
    }

    func testSentenceStartersAreNotTreatedAsNames() {
        let check = PIICheck(categories: [.person])
        XCTAssertTrue(check.detect(in: "Das Meeting ist am Dienstag.").isEmpty)
        XCTAssertTrue(check.detect(in: "Die Bestellnummer fehlt.").isEmpty)
        XCTAssertEqual(check.detect(in: "Erika Musterfrau kommt später.").first?.category, .person)
    }

    /// Abkuerzungen und Codes sind keine Menschen: die Namenskette verlangt
    /// Grossbuchstabe + Kleinbuchstaben je Wort, sonst meldet „Beleg ORD" eine Person.
    func testAllCapsTokensAreNotNames() {
        let check = PIICheck(categories: [.person])
        XCTAssertTrue(check.detect(in: "Beleg ORD liegt vor.").isEmpty)
        XCTAssertTrue(check.detect(in: "Ticket ABC-12 ist offen.").isEmpty)
    }

    func testLeadingArticleIsStrippedFromNameChain() {
        let check = PIICheck(categories: [.person])
        // „Der" faellt weg → „Anna Beispiel" bleibt als Fund.
        XCTAssertEqual(check.detect(in: "Der Anna Beispiel hat zugesagt.").first?.value, "Anna Beispiel")
        // Nach dem Streichen bleibt ein Wort → keine Kette.
        XCTAssertTrue(check.detect(in: "Das Meeting läuft.").isEmpty)
    }

    func testDenylistTermCounts() {
        let check = PIICheck(categories: [.mail], denylist: ["Projekt Nordlicht"])
        let matches = check.detect(in: "Wir starten projekt nordlicht im Herbst.")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.category, .person)
    }

    /// Befunde wandern in Logs und Audit — dort darf der Klarwert nicht stehen.
    func testEvidenceIsMaskedNotClearText() {
        let check = PIICheck()
        let context = OutputContext(output: "Schreib an max.mustermann@example.com")
        let findings = check.inspect(context)
        XCTAssertEqual(findings.count, 1)
        let evidence = try? XCTUnwrap(findings.first?.evidence)
        XCTAssertNotNil(evidence)
        XCTAssertFalse(evidence?.contains("max.mustermann") ?? true,
                       "Klarwert darf nicht im Befund stehen")
        XCTAssertTrue(evidence?.hasSuffix("@example.com") ?? false)
    }

    func testRedactReplacesEveryFinding() {
        let check = PIICheck()
        let redacted = check.redact("Mail a.b@example.com, IBAN DE89370400440532013000")
        XCTAssertFalse(redacted.contains("a.b@example.com"))
        XCTAssertFalse(redacted.contains("DE89370400440532013000"))
        XCTAssertTrue(redacted.contains("[Mail-1]"))
        XCTAssertTrue(redacted.contains("[Iban-1]"))
    }

    func testPIIInOutputIsAViolation() {
        let check = PIICheck()
        let findings = check.inspect(OutputContext(output: "IBAN DE89370400440532013000"))
        XCTAssertEqual(findings.first?.severity, .violation)
    }
}
