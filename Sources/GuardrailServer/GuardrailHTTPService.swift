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

    public init(service: GuardrailService) {
        self.service = service
    }

    public func handle(_ request: HTTPRequest) async -> (status: Int, body: Data) {
        // Query-Teil abschneiden: `/inspect?trace=1` ist derselbe Endpunkt.
        let path = request.path.components(separatedBy: "?").first ?? request.path

        switch (request.method, path) {
        case ("POST", "/inspect"):
            return await service.inspect(requestJSON: request.body)

        case ("GET", "/rules"):
            return (200, GuardrailService.encode(GuardrailService.encodeCatalog()))

        case ("GET", "/health"):
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
    public func serve(port: UInt16 = 8790, loopbackOnly: Bool = true) throws -> HTTPServer {
        let server = HTTPServer(port: port, loopbackOnly: loopbackOnly) { request in
            await handle(request)
        }
        try server.start()
        return server
    }
}
