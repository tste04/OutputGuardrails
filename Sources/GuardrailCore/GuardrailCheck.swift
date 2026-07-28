// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Eine Pruefstufe hinter dem Modell.
///
/// Deterministisch und synchron: gleicher Kontext → gleiche Befunde, kein Netz,
/// kein Zustand. Das ist die Voraussetzung dafuer, dass ein Guardrail-Ergebnis
/// auditierbar und reproduzierbar ist.
public protocol GuardrailCheck: Sendable {
    /// Stabiler Name, taucht in jedem Befund auf.
    var name: String { get }
    /// Prueft den Ausgang und liefert die Befunde (leer = unauffaellig).
    func inspect(_ context: OutputContext) -> [Finding]
}

/// Eine Pruefstufe, die ein Sprachmodell befragt (z. B. Widerspruchs-Verifikation).
///
/// Getrennt vom deterministischen Protokoll, weil sie fehlschlagen kann und Zeit
/// kostet: die Pipeline fuehrt sie nur aus, wenn ein Modell bereitsteht — und ein
/// Fehlschlag ist nie ein „unauffaellig", sondern bleibt ein offener Befund.
public protocol AsyncGuardrailCheck: Sendable {
    var name: String { get }
    func inspect(_ context: OutputContext, llm: GuardrailLLM) async -> [Finding]
}

/// Naht zum Sprachmodell. Die Guardrails bringen kein Modell mit und kennen
/// keinen Anbieter — wer pruefen laesst, reicht eines herein (im Zielbild
/// typischerweise ueber den AI Router).
public protocol GuardrailLLM: Sendable {
    /// `false` = kein Modell bereit. Die Pipeline ueberspringt dann die
    /// LLM-Stufen und vermerkt das, statt still „bestanden" zu melden.
    func isReady() async -> Bool
    func send(system: String, user: String, maxTokens: Int?) async throws -> String
}
