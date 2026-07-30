// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest
@testable import GuardrailCore

/// Die Regel-IDs, die sich dieses Repo mit der Eingangsseite (AIGateway) teilt.
///
/// Warum das ein eigener Test ist: Eingangs- und Ausgangsseite sind bewusst
/// getrennter Code — geteilt wird nur die *Bedeutung*. Genau die ist einmal
/// auseinandergelaufen, ohne dass irgendetwas widersprochen hat: `PII-001` hiess
/// hier „Mail" und drueben „Person", `PII-003` hier „IBAN" und drueben
/// „Telefon". Eine Suppression oder ein Dashboard auf eine dieser IDs traf damit
/// auf beiden Seiten etwas anderes, und das faellt im Betrieb erst auf, wenn
/// jemand den falschen Befund unterdrueckt hat.
///
/// Dieser Test ist die Gegenprobe. Er kann den anderen Quellbaum nicht lesen —
/// die Zuordnung steht deshalb als Erwartung hier, abgeschrieben aus
/// `AIGateway/Sources/InputFirewall/PII/PseudonymizationPolicy.swift`. Wer eine
/// ID aendert, muss hier vorbei und damit zwangslaeufig auch drueben.
final class RuleCatalogParityTests: XCTestCase {

    /// Bedeutung → ID, so wie das Gateway sie vergibt.
    private let sharedPII: [(meaning: String, id: RuleID)] = [
        ("person", "PII-001"),
        ("mail", "PII-002"),
        ("telefon", "PII-003"),
        ("iban", "PII-004"),
        ("anschrift", "PII-005"),
        // PII-006 ("ort") fuehrt nur das Gateway getrennt.
        ("denylist", "PII-007"),
    ]

    func testPIIRuleIDsMatchTheInputSide() {
        let actual: [(String, RuleID)] = [
            ("person", RuleCatalog.piiPerson),
            ("mail", RuleCatalog.piiMail),
            ("telefon", RuleCatalog.piiPhone),
            ("iban", RuleCatalog.piiIBAN),
            ("anschrift", RuleCatalog.piiAddress),
            ("denylist", RuleCatalog.piiCustom),
        ]
        for (expected, got) in zip(sharedPII, actual) {
            XCTAssertEqual(got.1, expected.id,
                           "\(expected.meaning) muss \(expected.id.rawValue) sein — "
                           + "sonst bedeutet die ID hier etwas anderes als im AIGateway")
        }
    }

    /// `PII-006` ist im Gateway „Ort" (PLZ + Stadt). Hier deckt `piiAddress`
    /// beide Faelle ab, deshalb bleibt die ID frei. Sie mit abweichender
    /// Bedeutung zu vergeben waere schlimmer als die Luecke.
    func testPII006StaysUnassigned() {
        XCTAssertFalse(RuleCatalog.all.contains { $0.id == "PII-006" },
                       "PII-006 gehoert dem Gateway ('Ort') — hier nicht neu belegen")
    }

    /// Die SEC-Reihe war von Anfang an deckungsgleich und muss es bleiben.
    func testSecretRuleIDsAreContiguousAndComplete() {
        let secretIDs = RuleCatalog.all
            .filter { $0.id.rawValue.hasPrefix("SEC-") }
            .map(\.id.rawValue)
            .sorted()
        XCTAssertEqual(secretIDs, (1...9).map { String(format: "SEC-%03d", $0) },
                       "SEC-001…SEC-009 sind mit dem AIGateway abgestimmt")
    }

    /// Jede Regel, die eine Stufe nennen kann, muss im Katalog stehen —
    /// sonst greift fail-closed und ein harmloser Befund wiegt plötzlich voll.
    func testEveryCatalogEntryHasAUniqueID() {
        let ids = RuleCatalog.all.map(\.id.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count, "doppelte Regel-ID im Katalog")
    }
}
