// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import GuardrailCore

/// Fuehrt die Pruefstufen aus und faellt ein Urteil.
///
/// Reihenfolge ist Absicht: erst die deterministischen Stufen (billig, immer
/// verfuegbar, nachvollziehbar), dann die LLM-Stufen. Blockt bereits eine
/// deterministische Stufe, wird kein Modell mehr befragt — das spart Geld und
/// verhindert, dass ein zu pruefender Ausgang unnoetig ein zweites Mal an ein
/// Modell geht.
public struct GuardrailPipeline: Sendable {

    public let checks: [GuardrailCheck]
    public let asyncChecks: [AsyncGuardrailCheck]
    public let policy: GuardrailPolicy

    public init(checks: [GuardrailCheck],
                asyncChecks: [AsyncGuardrailCheck] = [],
                policy: GuardrailPolicy = .standard) {
        self.checks = checks
        self.asyncChecks = asyncChecks
        self.policy = policy
    }

    /// Voller Satz fuer den Abschluss-Check eines Agent-Turns — alle drei Punkte
    /// der Zielbild-Box: PII/Compliance/Security, Grounding & Citation, Schema.
    public static func standard(grounding: GroundingPolicy = .standard,
                                compliance: CompliancePolicy = .empty,
                                policy: GuardrailPolicy = .standard) -> GuardrailPipeline {
        GuardrailPipeline(
            checks: [
                GroundingCheck(policy: grounding),
                PIICheck(),
                SecretsCheck(),
                ExfiltrationCheck(),
                ComplianceCheck(policy: compliance),
                SchemaCheck(),
                ConsistencyCheck(),
            ],
            asyncChecks: [],
            policy: policy)
    }

    /// Schlanker Satz fuer den Check pro Turn im Agent Loop.
    ///
    /// Enthaelt genau die Stufen, die ohne Belege und ohne Modell sofort
    /// entscheidbar sind — und die, deren Schaden sofort eintritt: ein
    /// abgeflossener Schluessel oder eine gerenderte Abfluss-URL laesst sich am
    /// Ende des Turns nicht mehr zurueckholen. Grounding und Konsistenz gehoeren
    /// dagegen an den Schluss, wenn die Antwort steht.
    public static func lightweight(compliance: CompliancePolicy = .empty,
                                   policy: GuardrailPolicy = .standard) -> GuardrailPipeline {
        GuardrailPipeline(
            checks: [PIICheck(), SecretsCheck(), ExfiltrationCheck(),
                     ComplianceCheck(policy: compliance), SchemaCheck()],
            asyncChecks: [],
            policy: policy)
    }

    // MARK: - Ausfuehrung

    /// Nur die deterministischen Stufen. Synchron, kein Netz, kein Modell.
    public func inspect(_ context: OutputContext) -> GuardrailReport {
        let findings = checks.flatMap { $0.inspect(context) }
        var skipped: [String] = []
        if policy.reportSkippedChecks {
            skipped = asyncChecks.map(\.name)
        }
        var all = findings
        if policy.reportSkippedChecks {
            all += skipped.map {
                Finding(check: $0, rule: RuleCatalog.checkSkipped,
                        message: "Stufe nicht ausgefuehrt (kein Modell uebergeben) — nicht als bestanden werten.",
                        evidence: nil)
            }
        }
        return GuardrailReport.make(findings: all, policy: policy,
                                    citations: citations(for: context),
                                    skippedChecks: skipped)
    }

    /// Deterministische Stufen plus LLM-Stufen.
    ///
    /// Ist `llm` nicht bereit oder blockt schon eine deterministische Stufe,
    /// werden die LLM-Stufen als uebersprungen vermerkt — nie als bestanden.
    public func inspect(_ context: OutputContext, llm: GuardrailLLM?) async -> GuardrailReport {
        var findings = checks.flatMap { $0.inspect(context) }
        var skipped: [String] = []

        let alreadyBlocked = GuardrailReport.verdict(for: findings, policy: policy) == .block
        let ready = await llm?.isReady() ?? false

        if let llm, ready, !alreadyBlocked {
            for check in asyncChecks {
                findings += await check.inspect(context, llm: llm)
            }
        } else {
            skipped = asyncChecks.map(\.name)
            if policy.reportSkippedChecks {
                let reason = alreadyBlocked
                    ? "Bereits deterministisch blockiert — Modell nicht mehr befragt."
                    : "Kein Modell bereit — Stufe nicht ausgefuehrt, nicht als bestanden werten."
                findings += skipped.map {
                    Finding(check: $0, rule: RuleCatalog.checkSkipped,
                            message: reason, evidence: nil)
                }
            }
        }

        return GuardrailReport.make(findings: findings, policy: policy,
                                    citations: citations(for: context),
                                    skippedChecks: skipped)
    }

    // MARK: - Belege

    /// Die Belege, die der Ausgang mitfuehren muss. Kommen aus der
    /// Grounding-Stufe, falls konfiguriert — sonst aus allen Quellen.
    private func citations(for context: OutputContext) -> [Citation] {
        for check in checks {
            if let grounding = check as? GroundingCheck {
                return grounding.citations(for: context)
            }
        }
        return context.sources.map(Citation.init(source:))
    }
}
