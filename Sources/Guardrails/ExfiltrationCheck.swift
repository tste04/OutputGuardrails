// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import GuardrailCore

// MARK: - Abflusskanaele im Ausgang (Zielbild: Security)
//
// Die Eingangs-Firewall prueft, was ins Modell geht. Diese Stufe prueft den
// gefaehrlichsten Fall danach: der Ausgang selbst ist der Transportweg.
//
//   • Ein Markdown-Bild rendert der Client automatisch — die URL wird abgerufen,
//     ohne dass jemand klickt. Wer Daten in die URL haengt, hat sie damit
//     verschickt. Das ist der klassische Weg, mit dem eine erfolgreiche
//     Injection ihre Beute nach draussen bringt.
//   • Ein Link mit langer kodierter Nutzlast ist derselbe Weg, nur mit Klick.
//   • Wiederholt der Ausgang die eingeschleusten Anweisungen, ist die Injection
//     durch den Agent Loop gelaufen — der Ausgang darf dann nicht weitergehen.
//   • Ein zerstoererischer Befehl im Ausgang ist harmlos, solange ihn niemand
//     ausfuehrt — und genau das tut der Action Layer dahinter.

/// Findet Abflusskanaele und Injection-Echo im Modell-Ausgang.
public struct ExfiltrationCheck: GuardrailCheck {
    public let name = "exfiltration"

    /// Ab wie vielen Zeichen eine URL-Nutzlast als auffaellig gilt. Kurze
    /// Query-Parameter sind Alltag; ein 80 Zeichen langer Base64-Block ist es nicht.
    public let suspiciousPayloadLength: Int

    /// Hosts, die als Ziel unbedenklich sind (eigene Doku, internes Wiki).
    public let allowedHosts: Set<String>

    public init(suspiciousPayloadLength: Int = 60, allowedHosts: Set<String> = []) {
        self.suspiciousPayloadLength = suspiciousPayloadLength
        self.allowedHosts = allowedHosts
    }

    // MARK: - Muster

    /// Markdown-Bild: `![alt](url)`. Wird beim Rendern automatisch geladen.
    private static let imagePattern = "!\\[[^\\]]*\\]\\(([^)\\s]+)"
    /// Markdown-Link: `[text](url)`.
    private static let linkPattern = "(?<!!)\\[[^\\]]*\\]\\(([^)\\s]+)"
    /// Nackte URL ohne Markdown-Rahmen. Braucht einen Klick, laedt also nicht
    /// von selbst — zaehlt deshalb als Link, nicht als Bild.
    private static let bareURLPattern = "https?://[^\\s<>\"')\\]]+"
    /// HTML-Bild. Wird beim Rendern genauso automatisch geladen wie die
    /// Markdown-Form; viele Oberflaechen zeigen Modell-Ausgaben als HTML an.
    /// Die Attributstrecke ist begrenzt, damit das Muster linear bleibt.
    private static let htmlImagePattern =
        "<img[^>]{0,200}?src\\s*=\\s*[\"']?([^\"'\\s>]+)"

    /// Anweisungs-Echo. Bewusst dieselben Formulierungen wie die
    /// Injection-Konformanz-Vektoren des Zielbilds — was am Eingang als
    /// Injection gilt, gilt im Ausgang als Echo.
    private static let echoPatterns = [
        "ignore\\s+(all\\s+)?previous\\s+instructions",
        "disregard\\s+(all\\s+)?(previous|prior|your)\\s+(instructions|guidelines|rules)",
        "ignoriere\\s+(alle\\s+)?(vorherigen|bisherigen)\\s+anweisungen",
        "vergiss\\s+alles,?\\s+was\\s+dir\\s+(vorher|zuvor)",
        "(you\\s+are\\s+now\\s+in|switch\\s+to)\\s+developer\\s+mode",
        "system[- ]?prompt\\s+(lautet|ist|is|reads)",
    ]

    /// Zerstoererische Befehle. Nur Formen, die ohne Kontext eindeutig sind.
    ///
    /// Die Wurzel-Variante deckt `/`, `/*` und `/ --no-preserve-root` mit ab:
    /// vorher verlangte sie hinter dem Schraegstrich ein Leerzeichen oder das
    /// Zeilenende, womit ausgerechnet `rm -rf /*` durchlief.
    private static let destructivePatterns = [
        "\\brm\\s+-[a-zA-Z]*[rf][a-zA-Z]*\\s+/(?:\\*|\\s|$)",
        "\\brm\\s+-[a-zA-Z]*[rf][a-zA-Z]*\\s+~",
        "\\bDROP\\s+(TABLE|DATABASE)\\b",
        "\\bTRUNCATE\\s+TABLE\\b",
        // `-f` ist die gebraeuchlichere Schreibweise als `--force`.
        "\\bgit\\s+push\\s+(?:--force\\b|--force-with-lease\\b|-f\\b)",
        "\\bmkfs(\\.[a-z0-9]+)?\\b",
        "\\bdd\\s+if=/dev/(?:zero|random|urandom)\\s+of=/dev/[a-z]",
        ":\\(\\)\\s*\\{\\s*:\\|:&\\s*\\}\\s*;\\s*:",
    ]

    // MARK: - Pruefung

    public func inspect(_ context: OutputContext) -> [Finding] {
        var findings: [Finding] = []

        // Alle Fundstellen zuerst einsammeln, dann je Ziel-URL EINEN Befund.
        //
        // Reihenfolge ist Rangfolge: eine Bild-URL steckt auch im nackten
        // URL-Muster, und ein Bild wiegt schwerer, weil es beim Rendern von
        // selbst geladen wird. Ohne die Zusammenfassung meldete dieselbe
        // Adresse bis zu drei Befunde und triebe den Risikowert kuenstlich hoch.
        var byTarget: [String: RuleID] = [:]
        var order: [String] = []

        func note(_ target: String, _ rule: RuleID) {
            guard !isAllowed(target), carriesPayload(target) else { return }
            if byTarget[target] == nil { order.append(target) }
            // Bild schlaegt Link — nie andersherum.
            if byTarget[target] == nil || rule == RuleCatalog.exfiltrationImage {
                byTarget[target] = rule
            }
        }

        for url in Regex.matches(Self.imagePattern, in: context.output) {
            note(Self.url(from: url, prefix: "!["), RuleCatalog.exfiltrationImage)
        }
        for url in Regex.matches(Self.htmlImagePattern, in: context.output,
                                 options: [.caseInsensitive]) {
            note(Self.htmlImageURL(from: url), RuleCatalog.exfiltrationImage)
        }
        for url in Regex.matches(Self.linkPattern, in: context.output) {
            note(Self.url(from: url, prefix: "["), RuleCatalog.exfiltrationLink)
        }
        // Zuletzt die nackten URLs: was schon als Bild oder Link erfasst ist,
        // bleibt dabei — `note` ueberschreibt einen Bild-Befund nicht.
        for url in Regex.matches(Self.bareURLPattern, in: context.output) {
            note(url, RuleCatalog.exfiltrationLink)
        }

        for target in order {
            let rule = byTarget[target] ?? RuleCatalog.exfiltrationLink
            let message = rule == RuleCatalog.exfiltrationImage
                ? "Bild-URL traegt eine Nutzlast und wird beim Rendern automatisch abgerufen — stiller Abfluss."
                : "Link traegt eine auffaellig lange oder kodierte Nutzlast."
            findings.append(Finding(check: name, rule: rule, message: message,
                                    evidence: Self.shorten(target)))
        }

        for pattern in Self.echoPatterns {
            for hit in Regex.matches(pattern, in: context.output, options: [.caseInsensitive]) {
                findings.append(Finding(
                    check: name, rule: RuleCatalog.injectionEcho,
                    message: "Ausgang wiederholt eingeschleuste Anweisungen — Injection ist durch den Agent Loop gelaufen.",
                    evidence: Self.shorten(hit)))
            }
        }

        for pattern in Self.destructivePatterns {
            for hit in Regex.matches(pattern, in: context.output, options: [.caseInsensitive]) {
                findings.append(Finding(
                    check: name, rule: RuleCatalog.destructiveCommand,
                    message: "Zerstoererischer Befehl im Ausgang — vor dem Action Layer pruefen lassen.",
                    evidence: Self.shorten(hit)))
            }
        }
        return findings
    }

    // MARK: - Bewertung einer URL

    /// Traegt die URL Daten ueber die reine Adressierung hinaus? Geprueft wird
    /// die Laenge von Query und Fragment sowie kodierte Bloecke im Pfad — beides
    /// sind die Stellen, an denen Beute mitreist.
    func carriesPayload(_ url: String) -> Bool {
        guard let marker = url.firstIndex(where: { $0 == "?" || $0 == "#" }) else {
            // Kein Query/Fragment: nur ein langer Base64-artiger Pfadabschnitt zaehlt.
            return Regex.hasMatch("/[A-Za-z0-9+/=_-]{\(suspiciousPayloadLength),}", in: url)
        }
        let payload = url[url.index(after: marker)...]
        return payload.count >= suspiciousPayloadLength
            || Regex.hasMatch("[A-Za-z0-9+/=_-]{\(suspiciousPayloadLength),}", in: String(payload))
    }

    func isAllowed(_ url: String) -> Bool {
        guard !allowedHosts.isEmpty, let host = Self.host(of: url) else { return false }
        return allowedHosts.contains(host)
    }

    static func host(of url: String) -> String? {
        guard let range = url.range(of: "://") else { return nil }
        let rest = url[range.upperBound...]
        let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let host = String(rest[rest.startIndex..<end])
        return host.isEmpty ? nil : host.lowercased()
    }

    /// Aus dem Regex-Treffer die reine URL schneiden. Die Muster fangen den
    /// Markdown-Rahmen mit, damit Bild und Link unterscheidbar bleiben.
    private static func url(from match: String, prefix: String) -> String {
        guard let open = match.range(of: "](", options: .backwards) else { return match }
        return String(match[open.upperBound...])
    }

    /// Schaelt die Adresse aus einem `<img …src="…"`-Treffer.
    ///
    /// Gesucht wird das erste `=` NACH dem `src` — nicht das letzte im Treffer.
    /// Das letzte steckt regelmaessig in der URL selbst (`?d=…`), und genau die
    /// Nutzlast will die Stufe ja bewerten.
    private static func htmlImageURL(from match: String) -> String {
        guard let src = match.range(of: "src", options: .caseInsensitive) else { return match }
        let rest = match[src.upperBound...]
        guard let equals = rest.firstIndex(of: "=") else { return match }
        return String(rest[rest.index(after: equals)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }

    /// Befunde tragen keine vollstaendige Abfluss-URL — sonst steht die Beute im
    /// Log, das gerade beweisen soll, dass sie nicht abgeflossen ist.
    private static func shorten(_ text: String) -> String {
        text.count <= 48 ? text : String(text.prefix(48)) + "…"
    }
}
