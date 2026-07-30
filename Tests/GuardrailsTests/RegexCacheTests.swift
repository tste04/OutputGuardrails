// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest
@testable import Guardrails
import GuardrailCore

/// Die Stufen pruefen mit rund fuenfzig festen Mustern pro Ausgang. Ohne
/// Zwischenspeicher wurde jedes davon bei jedem Aufruf neu uebersetzt.
///
/// Ein Zwischenspeicher darf am Ergebnis nichts aendern — genau das steht hier,
/// nicht die Geschwindigkeit. Eine Zeitmessung waere auf fremder Hardware nur
/// eine Fehlerquelle.
final class RegexCacheTests: XCTestCase {

    /// Die Optionen gehoeren in den Schluessel. Waeren sie es nicht, lieferte
    /// der zweite Aufruf das Muster des ersten — mit falschem Ergebnis.
    func testCaseSensitivityIsPartOfTheKey() {
        XCTAssertTrue(Regex.matches("HALLO", in: "hallo welt").isEmpty)
        XCTAssertFalse(Regex.matches("HALLO", in: "hallo welt",
                                     options: [.caseInsensitive]).isEmpty)
        XCTAssertTrue(Regex.matches("HALLO", in: "hallo welt").isEmpty,
                      "das unempfindliche Muster ist im Speicher haengengeblieben")
    }

    func testRepeatedRunsAgreeCompletely() {
        let context = OutputContext(
            output: "Kontakt Herr Schmidt, max.mustermann@example.com, "
                + "DE89 3704 0044 0532 0130 00.",
            query: "Wer?",
            sources: [GroundingSource(id: "e1", sourceType: "note", title: "",
                                      content: "Ein Kontakt liegt vor.")])
        let pipeline = GuardrailPipeline.standard()

        let first = pipeline.inspect(context)
        let second = pipeline.inspect(context)

        XCTAssertEqual(first.verdict, second.verdict)
        XCTAssertEqual(first.findings.map(\.rule), second.findings.map(\.rule))
        XCTAssertEqual(first.riskScore, second.riskScore)
    }

    /// Der Speicher wird aus mehreren Verbindungs-Threads zugleich benutzt.
    func testConcurrentUseIsSafe() {
        let group = DispatchGroup()
        for index in 0..<50 {
            DispatchQueue.global().async(group: group) {
                _ = Regex.matches("muster-\(index % 7)", in: "muster-3 und muster-5")
                _ = Regex.hasMatch("MUSTER", in: "muster", options: [.caseInsensitive])
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    }
}
