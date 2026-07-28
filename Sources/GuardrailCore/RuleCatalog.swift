// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

// MARK: - Der Regelkatalog
//
// Eine Stelle, an der jede Regel mit Kategorie, Schweregrad und Gewicht steht.
// Die Pruefstufen nennen nur noch die ID; was ein Treffer wiegt, entscheidet
// dieser Katalog, und wie daraus ein Urteil wird, entscheidet die Policy.
//
// IDs sind stabil und werden nur ergaenzt, nie umbenannt oder wiederverwendet.
// Die 9xx-Reihe jeder Familie ist reserviert fuer Info-Befunde (Gewicht 0),
// damit ein „alles in Ordnung" nie versehentlich Risiko erzeugt.

public enum RuleCatalog {

    // MARK: Grounding & Citation (GRO)

    public static let noGrounding: RuleID = "GRO-001"
    public static let unbackedClaim: RuleID = "GRO-002"
    public static let grounded: RuleID = "GRO-900"

    // MARK: PII (PII)

    public static let piiMail: RuleID = "PII-001"
    public static let piiPhone: RuleID = "PII-002"
    public static let piiIBAN: RuleID = "PII-003"
    public static let piiAddress: RuleID = "PII-004"
    public static let piiPerson: RuleID = "PII-005"

    // MARK: Zugangsdaten (SEC) — IDs bewusst deckungsgleich mit AIGateway

    public static let secretPrivateKey: RuleID = "SEC-001"
    public static let secretAWSKey: RuleID = "SEC-002"
    public static let secretGitHubToken: RuleID = "SEC-003"
    public static let secretSlackToken: RuleID = "SEC-004"
    public static let secretJWT: RuleID = "SEC-005"
    public static let secretAPIKey: RuleID = "SEC-006"

    // MARK: Abfluss und Echo (EXF)

    public static let exfiltrationImage: RuleID = "EXF-001"
    public static let exfiltrationLink: RuleID = "EXF-002"
    public static let injectionEcho: RuleID = "EXF-003"
    public static let destructiveCommand: RuleID = "EXF-004"

    // MARK: Compliance (CMP)

    public static let missingDisclaimer: RuleID = "CMP-001"
    public static let forbiddenTerm: RuleID = "CMP-002"
    public static let outputTooLong: RuleID = "CMP-003"

    // MARK: Schema (SCH)

    public static let invalidJSON: RuleID = "SCH-001"
    public static let missingRequired: RuleID = "SCH-002"
    public static let typeMismatch: RuleID = "SCH-003"
    public static let enumMismatch: RuleID = "SCH-004"
    public static let tooFewItems: RuleID = "SCH-005"
    public static let tooManyItems: RuleID = "SCH-006"
    public static let unexpectedProperty: RuleID = "SCH-007"
    public static let schemaOK: RuleID = "SCH-900"

    // MARK: Konsistenz (CON)

    public static let contradictionCandidate: RuleID = "CON-001"
    public static let contradictionConfirmed: RuleID = "CON-002"
    public static let verificationFailed: RuleID = "CON-003"
    public static let unverifiable: RuleID = "CON-004"

    // MARK: Betrieb (OPS)

    public static let checkSkipped: RuleID = "OPS-001"

    // MARK: - Katalog

    public static let all: [Rule] = [
        // Grounding: ohne Beleg ist der Ausgang wertlos — hoechstes Einzelgewicht.
        Rule(id: noGrounding, category: .grounding, severity: .violation, weight: 1.0,
             title: "Ausgang steht auf keinem tragfaehigen Beleg"),
        Rule(id: unbackedClaim, category: .grounding, severity: .warning, weight: 0.20,
             title: "Angabe kommt weder im Kontext noch in der Frage vor"),
        Rule(id: grounded, category: .grounding, severity: .info, weight: 0,
             title: "Ausgang steht auf Belegen"),

        // PII: jeder Fund ist ein Regelbruch, aber ein behebbarer (redigieren).
        Rule(id: piiMail, category: .pii, severity: .violation, weight: 0.50,
             title: "Mailadresse im Ausgang"),
        Rule(id: piiPhone, category: .pii, severity: .violation, weight: 0.50,
             title: "Telefonnummer im Ausgang"),
        Rule(id: piiIBAN, category: .pii, severity: .violation, weight: 0.70,
             title: "IBAN im Ausgang"),
        Rule(id: piiAddress, category: .pii, severity: .violation, weight: 0.50,
             title: "Anschrift im Ausgang"),
        Rule(id: piiPerson, category: .pii, severity: .violation, weight: 0.40,
             title: "Personenname im Ausgang"),

        // Zugangsdaten: nichts davon darf je einen Ausgang verlassen.
        Rule(id: secretPrivateKey, category: .secret, severity: .violation, weight: 1.0,
             title: "Privater Schluessel im Ausgang"),
        Rule(id: secretAWSKey, category: .secret, severity: .violation, weight: 1.0,
             title: "AWS-Access-Key-ID im Ausgang"),
        Rule(id: secretGitHubToken, category: .secret, severity: .violation, weight: 1.0,
             title: "GitHub-Token im Ausgang"),
        Rule(id: secretSlackToken, category: .secret, severity: .violation, weight: 1.0,
             title: "Slack-Token im Ausgang"),
        Rule(id: secretJWT, category: .secret, severity: .violation, weight: 0.70,
             title: "JWT im Ausgang"),
        Rule(id: secretAPIKey, category: .secret, severity: .violation, weight: 0.90,
             title: "API-Schluessel im Ausgang"),

        // Abfluss: der Ausgang selbst wird zum Transportmittel.
        Rule(id: exfiltrationImage, category: .exfiltration, severity: .violation, weight: 1.0,
             title: "Bild-URL mit angehaengten Daten (stiller Abfluss beim Rendern)"),
        Rule(id: exfiltrationLink, category: .exfiltration, severity: .warning, weight: 0.40,
             title: "Link mit auffaellig langer oder kodierter Nutzlast"),
        Rule(id: injectionEcho, category: .exfiltration, severity: .violation, weight: 0.80,
             title: "Ausgang wiederholt eingeschleuste Anweisungen"),
        Rule(id: destructiveCommand, category: .exfiltration, severity: .warning, weight: 0.50,
             title: "Zerstoererischer Befehl im Ausgang"),

        // Compliance: was die Organisation vorgibt, nicht was technisch faellt.
        Rule(id: missingDisclaimer, category: .compliance, severity: .violation, weight: 0.60,
             title: "Vorgeschriebener Hinweis fehlt"),
        Rule(id: forbiddenTerm, category: .compliance, severity: .violation, weight: 0.60,
             title: "Untersagte Formulierung im Ausgang"),
        Rule(id: outputTooLong, category: .compliance, severity: .warning, weight: 0.20,
             title: "Ausgang ueberschreitet die zulaessige Laenge"),

        // Schema: eine gebrochene Strukturzusage bricht den Action Layer dahinter.
        Rule(id: invalidJSON, category: .schema, severity: .violation, weight: 1.0,
             title: "Ausgang ist kein gueltiges JSON"),
        Rule(id: missingRequired, category: .schema, severity: .violation, weight: 0.80,
             title: "Pflichtfeld fehlt"),
        Rule(id: typeMismatch, category: .schema, severity: .violation, weight: 0.80,
             title: "Feldtyp weicht vom Schema ab"),
        Rule(id: enumMismatch, category: .schema, severity: .violation, weight: 0.60,
             title: "Wert ausserhalb der erlaubten Auswahl"),
        Rule(id: tooFewItems, category: .schema, severity: .violation, weight: 0.50,
             title: "Zu wenige Elemente"),
        Rule(id: tooManyItems, category: .schema, severity: .violation, weight: 0.50,
             title: "Zu viele Elemente"),
        Rule(id: unexpectedProperty, category: .schema, severity: .violation, weight: 0.40,
             title: "Feld im Schema nicht vorgesehen"),
        Rule(id: schemaOK, category: .schema, severity: .info, weight: 0,
             title: "Ausgang entspricht dem Schema"),

        // Konsistenz: deterministisch erkannt wiegt weniger als bestaetigt.
        Rule(id: contradictionCandidate, category: .consistency, severity: .warning, weight: 0.30,
             title: "Behauptung widerspricht einem bekannten Fakt (unverifiziert)"),
        Rule(id: contradictionConfirmed, category: .consistency, severity: .violation, weight: 0.90,
             title: "Bestaetigter Widerspruch"),
        Rule(id: verificationFailed, category: .consistency, severity: .warning, weight: 0.20,
             title: "Verifikation fehlgeschlagen — Kandidat bleibt offen"),
        Rule(id: unverifiable, category: .consistency, severity: .warning, weight: 0.20,
             title: "Modell-Antwort nicht auswertbar — Kandidat bleibt offen"),

        // Betrieb: eine uebersprungene Stufe ist kein bestandener Test, aber auch
        // kein Regelbruch — sie muss sichtbar sein, nicht blockend.
        Rule(id: checkSkipped, category: .operational, severity: .info, weight: 0,
             title: "Pruefstufe nicht ausgefuehrt"),
    ]

    private static let index: [RuleID: Rule] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }()

    public static func rule(_ id: RuleID) -> Rule? { index[id] }

    /// Fail-closed: eine unbekannte ID gilt als Regelbruch mit vollem Gewicht.
    /// Wer eine Regel ausloest, die nicht im Katalog steht, hat einen Fehler
    /// gemacht — der darf nicht als „unauffaellig" durchgehen.
    public static func resolve(_ id: RuleID) -> Rule {
        index[id] ?? Rule(id: id, category: .operational, severity: .violation, weight: 1.0,
                          title: "Unbekannte Regel \(id)")
    }
}
