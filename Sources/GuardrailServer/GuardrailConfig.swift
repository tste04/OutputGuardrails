// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import GuardrailCore
import Guardrails

// MARK: - Die Policy-Datei
//
// Der Grund, warum dieser Baustein standalone betreibbar ist: Schwellen,
// Gewichtungen der Entscheidung, Suppressions und die Compliance-Regeln der
// Organisation stehen in einer Datei, nicht im Code. Wer nachjustiert, aendert
// JSON und startet neu — kein Swift, kein Build.
//
// Das ist zugleich die Andockstelle fuer den Feedback-Loop des Zielbilds:
// Eval-Daten fuehren zu geaenderten Schwellen, und die stehen genau hier.

/// Vollstaendige Konfiguration eines Guardrail-Dienstes.
public struct GuardrailConfig: Codable, Sendable, Equatable {

    /// Welche Stufen laufen. Reihenfolge im Bericht folgt dieser Liste.
    public enum CheckName: String, Codable, Sendable, CaseIterable {
        case grounding, pii, secrets, exfiltration, compliance, schema, consistency
    }

    public struct PIIConfig: Codable, Sendable, Equatable {
        public var categories: [PIICategory]
        public var denylist: [String]

        public init(categories: [PIICategory] = PIICategory.allCases, denylist: [String] = []) {
            self.categories = categories
            self.denylist = denylist
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            categories = try c.decodeIfPresent([PIICategory].self, forKey: .categories)
                ?? PIICategory.allCases
            denylist = try c.decodeIfPresent([String].self, forKey: .denylist) ?? []
        }
    }

    public struct ExfiltrationConfig: Codable, Sendable, Equatable {
        public var suspiciousPayloadLength: Int
        public var allowedHosts: [String]

        public init(suspiciousPayloadLength: Int = 60, allowedHosts: [String] = []) {
            self.suspiciousPayloadLength = suspiciousPayloadLength
            self.allowedHosts = allowedHosts
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            suspiciousPayloadLength = try c.decodeIfPresent(Int.self,
                                                            forKey: .suspiciousPayloadLength) ?? 60
            allowedHosts = try c.decodeIfPresent([String].self, forKey: .allowedHosts) ?? []
        }
    }

    public var policy: GuardrailPolicy
    public var grounding: GroundingPolicy
    public var pii: PIIConfig
    public var exfiltration: ExfiltrationConfig
    public var compliance: CompliancePolicy
    public var checks: [CheckName]

    public init(policy: GuardrailPolicy = .standard,
                grounding: GroundingPolicy = .standard,
                pii: PIIConfig = PIIConfig(),
                exfiltration: ExfiltrationConfig = ExfiltrationConfig(),
                compliance: CompliancePolicy = .empty,
                checks: [CheckName] = CheckName.allCases) {
        self.policy = policy
        self.grounding = grounding
        self.pii = pii
        self.exfiltration = exfiltration
        self.compliance = compliance
        self.checks = checks
    }

    /// Jedes Feld ist optional — eine Datei mit `{}` ergibt die Voreinstellung,
    /// und wer nur `approvalThreshold` aendern will, schreibt nur den einen Wert.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policy = try c.decodeIfPresent(GuardrailPolicy.self, forKey: .policy) ?? .standard
        grounding = try c.decodeIfPresent(GroundingPolicy.self, forKey: .grounding) ?? .standard
        pii = try c.decodeIfPresent(PIIConfig.self, forKey: .pii) ?? PIIConfig()
        exfiltration = try c.decodeIfPresent(ExfiltrationConfig.self, forKey: .exfiltration)
            ?? ExfiltrationConfig()
        compliance = try c.decodeIfPresent(CompliancePolicy.self, forKey: .compliance) ?? .empty
        checks = try c.decodeIfPresent([CheckName].self, forKey: .checks) ?? CheckName.allCases
    }

    // MARK: - Laden

    public static func load(contentsOf url: URL) throws -> GuardrailConfig {
        let data = try Data(contentsOf: url)
        return try load(data)
    }

    public static func load(_ data: Data) throws -> GuardrailConfig {
        let config: GuardrailConfig
        do {
            config = try JSONDecoder().decode(GuardrailConfig.self, from: data)
        } catch {
            // Fail-closed: eine kaputte Policy-Datei darf nicht stillschweigend
            // zur Voreinstellung werden. Wer sie schreibt, will etwas anderes
            // als den Default — sonst haette er sie nicht geschrieben.
            throw GuardrailConfigError.invalid(String(describing: error))
        }
        // Syntaktisch gueltiges JSON reicht nicht: ein Regex-Tippfehler in den
        // Compliance-Mustern ergibt eine Datei, die laedt, und eine Regel, die
        // nie greift. Das ist der Fall, den der Betreiber am wenigsten bemerkt.
        let invalid = config.compliance.invalidPatterns()
        guard invalid.isEmpty else {
            throw GuardrailConfigError.invalidPattern(invalid.map { "\($0.field): \($0.pattern)" })
        }
        return config
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    // MARK: - Pipeline bauen

    /// Baut die Pruefkette aus der Konfiguration.
    ///
    /// Die LLM-Stufe wird nur aufgenommen, wenn `consistency` aktiv ist *und*
    /// ein Modell bereitsteht — sonst stuende im Bericht dauerhaft ein
    /// „uebersprungen", das niemand abstellen kann.
    public func pipeline(withLLM hasLLM: Bool = false) -> GuardrailPipeline {
        var stages: [GuardrailCheck] = []
        for check in checks {
            switch check {
            case .grounding:
                stages.append(GroundingCheck(policy: grounding))
            case .pii:
                stages.append(PIICheck(categories: Set(pii.categories), denylist: pii.denylist))
            case .secrets:
                stages.append(SecretsCheck())
            case .exfiltration:
                stages.append(ExfiltrationCheck(
                    suspiciousPayloadLength: exfiltration.suspiciousPayloadLength,
                    allowedHosts: Set(exfiltration.allowedHosts.map { $0.lowercased() })))
            case .compliance:
                stages.append(ComplianceCheck(policy: compliance))
            case .schema:
                stages.append(SchemaCheck())
            case .consistency:
                stages.append(ConsistencyCheck())
            }
        }
        let async: [AsyncGuardrailCheck] =
            (hasLLM && checks.contains(.consistency)) ? [LLMConsistencyCheck()] : []
        return GuardrailPipeline(checks: stages, asyncChecks: async, policy: policy)
    }
}

public enum GuardrailConfigError: Error, CustomStringConvertible {
    case invalid(String)
    /// Muster, die sich nicht uebersetzen lassen — je Eintrag „feld: muster".
    case invalidPattern([String])

    public var description: String {
        switch self {
        case .invalid(let detail):
            return "Policy-Datei nicht lesbar: \(detail)"
        case .invalidPattern(let entries):
            return "Policy-Datei enthaelt nicht uebersetzbare Muster — diese Regeln "
                + "wuerden nie greifen:\n" + entries.map { "  \($0)" }.joined(separator: "\n")
        }
    }
}
