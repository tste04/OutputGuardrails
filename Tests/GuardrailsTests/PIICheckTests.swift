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

    /// So schreiben Menschen und Banking-Portale eine IBAN auf. Ohne die
    /// Vierergruppen ginge die haeufigste Schreibweise ungeprueft durch.
    func testIBANIsFoundInGroupedNotation() {
        let check = PIICheck()
        XCTAssertEqual(check.detect(in: "Bitte an DE89 3704 0044 0532 0130 00 überweisen.").first?.category,
                       .iban)
        XCTAssertEqual(check.detect(in: "IBAN: AT48 3200 0000 1234 5864").first?.category, .iban)

        let redacted = check.redact("Konto DE89 3704 0044 0532 0130 00.")
        XCTAssertTrue(redacted.contains("[Iban-1]"))
        XCTAssertFalse(redacted.contains("0532"), "kein Rest der IBAN im Text")
    }

    /// Kurze Codes duerfen nicht als IBAN gelten — die Laengenuntergrenze ist
    /// der einzige Schutz gegen Fehlalarme auf Bestell- und Ticketnummern.
    func testShortCodesAreNotIBANs() {
        let check = PIICheck()
        XCTAssertTrue(check.detect(in: "Bestellung AB12 3456 folgt.").isEmpty)
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

    /// Der Kern des Problems im Deutschen: Substantive stehen gross, also sieht
    /// jede Nominalphrase wie ein Name aus. Ohne Anker duerfen diese Ketten
    /// keinen Personenbezug melden — sonst blockiert der Guardrail jeden
    /// zweiten normalen Satz.
    func testGermanNounPhrasesAreNotPeople() {
        let check = PIICheck(categories: [.person])
        for phrase in ["Kurzer Zwischenschritt", "Offene Punkte bleiben",
                       "Technische Schulden wachsen", "Neue Anforderung erfasst",
                       "Interner Bericht liegt vor", "Wichtige Entscheidung steht an"] {
            XCTAssertTrue(check.detect(in: phrase).isEmpty,
                          "Fehlalarm auf Nominalphrase: \(phrase)")
        }
    }

    /// Anrede, Titel und Feldbezeichner tragen den Fund allein — ein Nachname
    /// ohne Vornamen wird nur so erkannt.
    func testTitlesAndLabelsAnchorASingleName() {
        let check = PIICheck(categories: [.person])
        XCTAssertEqual(check.detect(in: "Bitte an Herr Schmidt weiterleiten.").first?.value,
                       "Schmidt")
        XCTAssertEqual(check.detect(in: "Frau Dr. Meier hat unterschrieben.").first?.value,
                       "Meier")
        XCTAssertEqual(check.detect(in: "Ansprechpartner: Weber").first?.value, "Weber")
        // Die Anrede selbst ist kein Name.
        XCTAssertTrue(check.detect(in: "Sehr geehrte Frau, ...").isEmpty)
    }

    /// Die kuratierte Vornamensliste deckt nicht jeden Namen ab. Betreiber
    /// schliessen die Luecke mit ihrem eigenen Verzeichnis statt mit einem
    /// Muster, das jede Nominalphrase blockt.
    func testOperatorCanExtendFirstNames() {
        let plain = PIICheck(categories: [.person])
        XCTAssertTrue(plain.detect(in: "Aiko Tanaka war dabei.").isEmpty)

        let extended = PIICheck(categories: [.person], additionalFirstNames: ["Aiko"])
        XCTAssertEqual(extended.detect(in: "Aiko Tanaka war dabei.").first?.value, "Aiko Tanaka")
    }

    /// Fuer englischsprachige Ausgaenge bleibt die alte, weite Erkennung
    /// waehlbar — mit dem dokumentierten Preis vieler Fehlalarme im Deutschen.
    func testAnyCapitalizedChainModeRestoresTheWideNet() {
        let wide = PIICheck(categories: [.person], personDetection: .anyCapitalizedChain)
        XCTAssertEqual(wide.detect(in: "Kurzer Zwischenschritt").first?.value,
                       "Kurzer Zwischenschritt")
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

    /// Ein Denylist-Treffer ist kein Personenname — "Projekt Nordlicht" ist ein
    /// Vorhaben. Eigene Kategorie, damit Auswertungen ueber Personen-Befunde
    /// nicht von Betreiber-Begriffen verwaessert werden.
    func testDenylistTermCounts() {
        let check = PIICheck(categories: [.mail], denylist: ["Projekt Nordlicht"])
        let matches = check.detect(in: "Wir starten projekt nordlicht im Herbst.")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.category, .custom)
        XCTAssertEqual(matches.first?.category.rule, RuleCatalog.piiCustom)
    }

    /// Die Denylist greift unabhaengig von `categories` — wer einen Begriff
    /// hineinschreibt, hat die Entscheidung schon getroffen.
    func testDenylistRedactionCoversEverySpelling() {
        let check = PIICheck(categories: [.mail], denylist: ["Projekt Nordlicht"])
        for text in ["Projekt Nordlicht startet.", "projekt nordlicht startet.",
                     "PROJEKT NORDLICHT startet.",
                     "Projekt Nordlicht und projekt nordlicht."] {
            XCTAssertFalse(check.redact(text).lowercased().contains("nordlicht"),
                           "Klartext blieb stehen: \(check.redact(text))")
        }
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
