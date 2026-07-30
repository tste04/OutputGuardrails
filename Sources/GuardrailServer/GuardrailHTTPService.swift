// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import GuardrailCore

/// Die HTTP-Huelle um `GuardrailService`. Drei Endpunkte, mehr braucht ein
/// Pruefdienst nicht.
///
/// - `POST /inspect` — Ausgang pruefen, Bericht zurueck.
/// - `GET  /rules`   — Regelkatalog (Selbstauskunft; Grundlage fuer Suppressions).
/// - `GET  /health`  — laeuft der Dienst, mit welcher Politik.
public struct GuardrailHTTPService: Sendable {

    public let service: GuardrailService
    /// Gemeinsames Geheimnis. `nil` = keine Authentifizierung (Loopback-Betrieb).
    ///
    /// Es gibt kein TLS und keine Nutzerverwaltung — beides waere Krypto-
    /// Eigenbau in einem Paket ohne Abhaengigkeiten. Ein Bearer-Token ist das,
    /// was sich ehrlich halten laesst: es schuetzt gegen jeden, der nicht
    /// mitlesen kann, und der Leitfaden sagt klar, dass die Strecke fremd
    /// gesichert werden muss.
    public let token: String?

    public init(service: GuardrailService, token: String? = nil) {
        self.service = service
        self.token = token
    }

    /// Zeitkonstanter Vergleich — ein Token, das sich Zeichen fuer Zeichen
    /// erraten laesst, ist keines.
    static func matches(_ provided: String, _ expected: String) -> Bool {
        let a = Array(provided.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in a.indices { diff |= a[index] ^ b[index] }
        return diff == 0
    }

    /// `true`, wenn die Anfrage das Geheimnis mitbringt (oder keines noetig ist).
    func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let token else { return true }
        guard let header = request.headers["authorization"] else { return false }
        let prefix = "bearer "
        guard header.lowercased().hasPrefix(prefix) else { return false }
        return Self.matches(String(header.dropFirst(prefix.count)), token)
    }

    public func handle(_ request: HTTPRequest) async -> (status: Int, body: Data) {
        // Query-Teil abschneiden: `/inspect?trace=1` ist derselbe Endpunkt.
        let path = request.path.components(separatedBy: "?").first ?? request.path

        // `/health` bleibt offen, damit ein Starter oder ein Container-Health-
        // Check ohne Geheimnis auskommt. Es verraet nichts ueber geprueften
        // Inhalt — die Politik-Details wandern hinter die Anmeldung.
        guard path == "/health" || isAuthorized(request) else {
            return (401, GuardrailService.encode(["error": "Bearer-Token fehlt oder passt nicht"]))
        }

        switch (request.method, path) {
        case ("POST", "/inspect"):
            return await service.inspect(requestJSON: request.body)

        case ("GET", "/rules"):
            return (200, GuardrailService.encode(GuardrailService.encodeCatalog()))

        case ("GET", "/health"):
            // Ohne Anmeldung nur die Lebendmeldung. Welche Regeln unterdrueckt
            // sind, ist eine Landkarte der blinden Flecken — die gehoert nicht
            // an jeden, der den Port erreicht.
            guard isAuthorized(request) else {
                return (200, GuardrailService.encode(["status": "ok"]))
            }
            return (200, GuardrailService.encode([
                "status": "ok",
                "checks": service.config.checks.map(\.rawValue),
                "blockAt": service.config.policy.blockAt.rawValue,
                "flagAt": service.config.policy.flagAt.rawValue,
                "approvalThreshold": service.config.policy.approvalThreshold,
                "suppressedRules": service.config.policy.suppressedRules.map(\.rawValue).sorted(),
            ]))

        case ("GET", "/inspect"), ("PUT", "/inspect"), ("DELETE", "/inspect"):
            return (405, GuardrailService.encode(["error": "POST verwenden"]))

        default:
            return (404, GuardrailService.encode(["error": "unbekannter Endpunkt \(path)"]))
        }
    }

    /// Startet den Server. Loopback ist der Default und keine Empfehlung: der
    /// Dienst sieht genau die Inhalte, die nicht abfliessen sollen.
    ///
    /// Ausserhalb von Loopback ist ein Token Pflicht — siehe `serve` unten.
    public func serve(port: UInt16 = 8790, loopbackOnly: Bool = true) throws -> HTTPServer {
        let server = HTTPServer(port: port, loopbackOnly: loopbackOnly) { request in
            await handle(request)
        }
        try server.start()
        return server
    }
}
