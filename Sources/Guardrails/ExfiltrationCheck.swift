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
    /// Nackte URL ohne Markdown-Rahmen.
    private static let bareURLPattern = "https?://[^\\s<>\"]+"

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
    private static let destructivePatterns = [
        "\\brm\\s+-[a-zA-Z]*[rf][a-zA-Z]*\\s+/(?:\\s|$)",
        "\\brm\\s+-[a-zA-Z]*[rf][a-zA-Z]*\\s+~",
        "\\bDROP\\s+(TABLE|DATABASE)\\b",
        "\\bTRUNCATE\\s+TABLE\\b",
        "\\bgit\\s+push\\s+--force\\b",
        "\\bmkfs(\\.[a-z0-9]+)?\\b",
        ":\\(\\)\\s*\\{\\s*:\\|:&\\s*\\}\\s*;\\s*:",
    ]

    // MARK: - Pruefung

    public func inspect(_ context: OutputContext) -> [Finding] {
        var findings: [Finding] = []

        for url in Regex.matches(Self.imagePattern, in: context.output) {
            let target = Self.url(from: url, prefix: "![")
            guard !isAllowed(target), carriesPayload(target) else { continue }
            findings.append(Finding(
                check: name, rule: RuleCatalog.exfiltrationImage,
                message: "Bild-URL traegt eine Nutzlast und wird beim Rendern automatisch abgerufen — stiller Abfluss.",
                evidence: Self.shorten(target)))
        }

        for url in Regex.matches(Self.linkPattern, in: context.output) {
            let target = Self.url(from: url, prefix: "[")
            guard !isAllowed(target), carriesPayload(target) else { continue }
            findings.append(Finding(
                check: name, rule: RuleCatalog.exfiltrationLink,
                message: "Link traegt eine auffaellig lange oder kodierte Nutzlast.",
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

    /// Befunde tragen keine vollstaendige Abfluss-URL — sonst steht die Beute im
    /// Log, das gerade beweisen soll, dass sie nicht abgeflossen ist.
    private static func shorten(_ text: String) -> String {
        text.count <= 48 ? text : String(text.prefix(48)) + "…"
    }
}
