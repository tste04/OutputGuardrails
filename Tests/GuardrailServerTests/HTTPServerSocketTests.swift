// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest
import GuardrailCore
@testable import GuardrailServer

/// Die Socket- und Parser-Schicht — bisher komplett ungetestet, weil der Server
/// seinen Port nicht preisgab und deshalb nur der Handler direkt aufrufbar war.
/// Genau dort sitzen aber Authentifizierung, Laengenbehandlung und die
/// Schmuggel-Abwehr; alles davon ist nur ueber echte Bytes pruefbar.
final class HTTPServerSocketTests: XCTestCase {

    private let secret = "geheim-geheim-geheim-1234"
    private let body = #"{"output":"Alles in Ordnung.","sources":[{"id":"e1","sourceType":"note","content":"x"}]}"#

    // MARK: Roh-HTTP

    /// Schickt Bytes an den Port und liest die Antwort vollstaendig.
    private func raw(_ port: UInt16, _ bytes: String) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { return nil }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = bytes.withCString { send(fd, $0, strlen($0), 0) }

        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            out.append(contentsOf: chunk[0..<n])
        }
        return out.isEmpty ? nil : String(data: out, encoding: .utf8)
    }

    private func status(_ response: String?) -> Int? {
        let parts = response?.components(separatedBy: "\r\n").first?.components(separatedBy: " ")
        return (parts?.count ?? 0) > 1 ? Int(parts![1]) : nil
    }

    private func withServer(token: String?,
                            _ body: (UInt16) throws -> Void) rethrows {
        let service = GuardrailHTTPService(
            service: GuardrailService(config: GuardrailConfig()), token: token)
        guard let server = try? service.serve(port: 0) else {
            return XCTFail("Server startete nicht")
        }
        defer { server.stop() }
        XCTAssertGreaterThan(server.boundPort, 0)
        try body(server.boundPort)
    }

    private func post(_ headers: String) -> String {
        "POST /inspect HTTP/1.1\r\nHost: 127.0.0.1\r\n\(headers)"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    // MARK: Authentifizierung

    func testTokenIsRequiredWhenConfigured() {
        withServer(token: secret) { port in
            XCTAssertEqual(status(raw(port, post(""))), 401, "ohne Token")
            XCTAssertEqual(status(raw(port, post("Authorization: Bearer falsch\r\n"))), 401)
            XCTAssertEqual(status(raw(port, post("Authorization: Bearer \(secret)\r\n"))), 200)
            // Header-Namen und das Schema sind laut RFC case-insensitiv.
            XCTAssertEqual(status(raw(port, post("authorization: bearer \(secret)\r\n"))), 200)
        }
    }

    /// `/health` bleibt offen, damit ein Container-Health-Check ohne Geheimnis
    /// auskommt — verraet dann aber nichts. Welche Regeln unterdrueckt sind, ist
    /// eine Landkarte der blinden Flecken.
    func testHealthDiscloseNothingWithoutToken() {
        withServer(token: secret) { port in
            let open = raw(port, "GET /health HTTP/1.1\r\nHost: x\r\n\r\n")
            XCTAssertEqual(status(open), 200)
            XCTAssertFalse(open?.contains("suppressedRules") ?? true)

            let authed = raw(port, "GET /health HTTP/1.1\r\nHost: x\r\n"
                             + "Authorization: Bearer \(secret)\r\n\r\n")
            XCTAssertTrue(authed?.contains("suppressedRules") ?? false)
        }
    }

    func testWithoutConfiguredTokenEverythingStaysOpen() {
        withServer(token: nil) { port in
            XCTAssertEqual(status(raw(port, post(""))), 200)
        }
    }

    func testTokenComparisonIsLengthSafe() {
        XCTAssertTrue(GuardrailHTTPService.matches("abc", "abc"))
        XCTAssertFalse(GuardrailHTTPService.matches("abc", "abd"))
        XCTAssertFalse(GuardrailHTTPService.matches("ab", "abc"))
    }

    // MARK: Parser

    private func head(_ extra: String) -> String {
        "POST /inspect HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(secret)\r\n\(extra)"
    }

    /// Transfer-Encoding neben Content-Length ist die klassische Schmuggel-
    /// Vorlage: zwei Vermittler zerlegen den Strom verschieden.
    func testTransferEncodingIsRejected() {
        withServer(token: secret) { port in
            let response = raw(port, head("Transfer-Encoding: chunked\r\n"
                                          + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"))
            XCTAssertEqual(status(response), 400)
        }
    }

    func testConflictingContentLengthIsRejected() {
        withServer(token: secret) { port in
            XCTAssertEqual(status(raw(port, head("Content-Length: 12\r\nContent-Length: 34\r\n\r\n\(body)"))),
                           400)
        }
    }

    /// Fail-closed: frueher wurde ein unlesbares Content-Length zu 0, und der
    /// Dienst urteilte ueber einen leeren Ausgang, als waere er geprueft worden.
    func testUnreadableOrMissingContentLengthIsRejected() {
        withServer(token: secret) { port in
            XCTAssertEqual(status(raw(port, head("Content-Length: abc\r\n\r\n\(body)"))), 400)
            XCTAssertEqual(status(raw(port, head("\r\n\(body)"))), 400)
        }
    }

    /// Angekuendigte Ueberlaenge ist 413, nicht 400 — `reason(413)` war vorher
    /// unerreichbarer Code.
    func testAnnouncedOversizeIsPayloadTooLarge() {
        withServer(token: secret) { port in
            XCTAssertEqual(status(raw(port, head("Content-Length: 99000000\r\n\r\n"))), 413)
        }
    }

    /// Was hinter der angekuendigten Laenge steht, gehoert zur naechsten Anfrage
    /// und darf nicht in diese hineinlaufen.
    func testBodyIsTruncatedToContentLength() {
        withServer(token: secret) { port in
            let short = #"{"output":"kurz"}"#
            let response = raw(port, head("Content-Length: \(short.utf8.count)\r\n\r\n")
                               + short + "MUELL-DAHINTER")
            XCTAssertEqual(status(response), 200)
        }
    }
}
