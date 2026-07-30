// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import GuardrailCore
import Guardrails
import GuardrailServer

// MARK: - guardrails — die Kommandozeile
//
// Der Standalone-Zugang. Vier Befehle, und die Exit-Codes sind die eigentliche
// Schnittstelle: `check` liefert 0/1/2 fuer allow/flag/block, damit ein
// CI-Schritt oder ein Shell-Skript ohne JSON-Parsen entscheiden kann.
//
//   0  allow        Ausgang ist unauffaellig
//   1  flag         Ausgang ist auffaellig (Freigabe pruefen)
//   2  block        Ausgang darf nicht raus
//  64  Aufruffehler (wie sysexits EX_USAGE)
//  70  interner Fehler

let usage = """
guardrails — Pruefschicht hinter dem Modell (Zielbild-Baustein Output Guardrails)

BEFEHLE
  check      Einen Ausgang pruefen
  serve      Als HTTP-Dienst laufen (loopback)
  rules      Regelkatalog ausgeben
  selftest   Eingebaute Selbstpruefung
  config     Voreinstellung als Policy-Datei ausgeben

check [OPTIONEN]
  --input <datei>     Zu pruefender Ausgang. Fehlt die Angabe: stdin.
  --query <text>      Die Frage, die zum Ausgang gefuehrt hat.
  --source <datei>    Beleg (mehrfach angebbar). Dateiname wird zur Beleg-ID.
  --schema <datei>    Erwartetes JSON-Schema.
  --request <datei>   Komplette Anfrage als JSON (statt der Einzeloptionen).
  --config <datei>    Policy-Datei.
  --json              Vollen Bericht als JSON ausgeben.
  --quiet             Nur den Exit-Code setzen.

serve [OPTIONEN]
  --port <n>          Port (Default 8790).
  --config <datei>    Policy-Datei.
  --token <geheim>    Bearer-Token, das Aufrufer mitschicken muessen.
                      Besser ueber GUARDRAILS_TOKEN — Argumente stehen in der
                      Prozessliste. Mindestens 16 Zeichen.
  --allow-remote      Nicht nur an 127.0.0.1 binden. Verlangt ein Token und
                      gehoert hinter einen Reverse Proxy (es gibt kein TLS).

EXIT-CODES
  0 allow · 1 flag · 2 block · 64 Aufruffehler · 70 interner Fehler
"""

// MARK: - Argumente

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(64)
}
args.removeFirst()

func value(_ flag: String) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func values(_ flag: String) -> [String] {
    var found: [String] = []
    for (index, arg) in args.enumerated() where arg == flag && index + 1 < args.count {
        found.append(args[index + 1])
    }
    return found
}

func has(_ flag: String) -> Bool { args.contains(flag) }

func fail(_ message: String, code: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data("guardrails: \(message)\n".utf8))
    exit(code)
}

// MARK: - Argumente pruefen
//
// Warum das sein muss: `value(_:)` sucht das Flag per Gleichheit. Ein
// vertipptes `--configg` oder ein `--config=policy.json` wird dabei einfach
// nicht gefunden — und `loadConfig()` faellt auf die Voreinstellung zurueck.
// Der Aufruf prueft dann mit der Standardpolitik statt mit der des Betreibers
// und meldet Exit 0. Genau die Sorte Fehler, die niemand bemerkt, weil alles
// nach Erfolg aussieht. In einem Repo mit Fail-closed als Invariante ist das
// die falsche Voreinstellung.

/// Flags je Kommando: die mit Wert und die ohne.
let knownFlags: [String: (withValue: Set<String>, boolean: Set<String>)] = [
    "check": (["--config", "--input", "--request", "--query", "--schema", "--source"],
              ["--json", "--quiet"]),
    "serve": (["--config", "--port", "--token"], ["--allow-remote"]),
    "rules": (["--config"], ["--json"]),
    "config": (["--config"], []),
    "selftest": (["--config"], []),
]

func validateFlags(for command: String) {
    guard let known = knownFlags[command] else { return }
    var index = 0
    while index < args.count {
        let arg = args[index]
        guard arg.hasPrefix("-") else { index += 1; continue }

        if let equals = arg.firstIndex(of: "="), arg.hasPrefix("--") {
            let name = String(arg[arg.startIndex..<equals])
            let hint = known.withValue.contains(name)
                ? " — dieses Werkzeug erwartet '\(name) <wert>' mit Leerzeichen"
                : ""
            fail("unbekanntes Argument '\(arg)'\(hint)")
        }
        if known.withValue.contains(arg) {
            guard index + 1 < args.count else { fail("'\(arg)' erwartet einen Wert") }
            index += 2                      // Wert ueberspringen, er darf wie ein Flag aussehen
            continue
        }
        guard known.boolean.contains(arg) else {
            let all = known.withValue.union(known.boolean).sorted().joined(separator: " ")
            fail("unbekanntes Argument '\(arg)' fuer '\(command)'. Erlaubt: \(all)")
        }
        index += 1
    }
}

func loadConfig() -> GuardrailConfig {
    guard let path = value("--config") else { return GuardrailConfig() }
    do {
        return try GuardrailConfig.load(contentsOf: URL(fileURLWithPath: path))
    } catch {
        // Fail-closed: lieber gar nicht pruefen als mit der falschen Politik.
        fail("\(error)", code: 70)
    }
}

func readText(_ path: String) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("Datei nicht lesbar: \(path)")
    }
    return text
}

func readStdin() -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Wartet auf ein async-Ergebnis. `main.swift` ist ein Top-Level-Skript ohne
/// async-Kontext; ein Semaphor ist hier ehrlicher als ein verwaister Task.
func awaitResult<T>(_ operation: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task {
        box.value = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

func exitCode(for verdict: Verdict) -> Int32 {
    switch verdict {
    case .allow: return 0
    case .flag: return 1
    case .block: return 2
    }
}

// MARK: - check

func runCheck() -> Never {
    let config = loadConfig()
    let service = GuardrailService(config: config)

    let context: OutputContext
    if let requestPath = value("--request") {
        guard let data = FileManager.default.contents(atPath: requestPath) else {
            fail("Anfrage-Datei nicht lesbar: \(requestPath)")
        }
        do { context = try GuardrailService.decodeRequest(data) }
        catch { fail("\(error)") }
    } else {
        let output = value("--input").map(readText) ?? readStdin()
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("Kein Ausgang uebergeben (--input, --request oder stdin).")
        }
        let sources = values("--source").map { path -> GroundingSource in
            GroundingSource(id: URL(fileURLWithPath: path).lastPathComponent,
                            sourceType: "file", title: "", content: readText(path))
        }
        var schema: SchemaNode?
        if let schemaPath = value("--schema") {
            guard let data = FileManager.default.contents(atPath: schemaPath),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let node = SchemaNode.fromJSONSchema(dict) else {
                fail("Schema-Datei nicht lesbar oder nicht abbildbar: \(schemaPath)")
            }
            schema = node
        }
        context = OutputContext(output: output, query: value("--query") ?? "",
                                sources: sources, expectedSchema: schema)
    }

    let report = awaitResult { await service.inspect(context) }

    if has("--json") {
        let data = GuardrailService.encode(GuardrailService.encodeReport(report))
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else if !has("--quiet") {
        print("verdict: \(report.verdict.rawValue)")
        print("risk:    \(String(format: "%.2f", report.riskScore))")
        print("freigabe noetig: \(report.requiresApproval ? "ja" : "nein")")
        if !report.citations.isEmpty {
            print("belege:  \(report.citations.map(\.id).joined(separator: ", "))")
        }
        for finding in report.findings {
            let evidence = finding.evidence.map { " [\($0)]" } ?? ""
            print("  \(finding.rule) \(finding.severity.rawValue.uppercased()) \(finding.message)\(evidence)")
        }
        for finding in report.suppressed {
            print("  \(finding.rule) unterdrueckt: \(finding.message)")
        }
        if !report.skippedChecks.isEmpty {
            print("  uebersprungen: \(report.skippedChecks.joined(separator: ", "))")
        }
    }
    exit(exitCode(for: report.verdict))
}

// MARK: - serve

func runServe() -> Never {
    let config = loadConfig()
    // Kein stiller Rueckfall: wer '--port 87900' tippt, bekaeme sonst 8790 und
    // haette einen Dienst auf einem Port, den er nicht gemeint hat.
    let port: UInt16
    if let raw = value("--port") {
        guard let parsed = UInt16(raw), parsed > 0 else {
            fail("'--port \(raw)' ist keine gueltige Portnummer (1…65535)")
        }
        port = parsed
    } else {
        port = 8790
    }
    let loopbackOnly = !has("--allow-remote")

    // Token aus dem Flag oder der Umgebung. Die Umgebung ist der bessere Weg:
    // ein Argument steht in der Prozessliste und damit fuer jeden Nutzer der
    // Maschine lesbar da.
    let token = value("--token") ?? ProcessInfo.processInfo.environment["GUARDRAILS_TOKEN"]

    // Fail-closed an der Stelle, an der es am meisten zaehlt: dieser Dienst
    // sieht genau die Inhalte, die nicht abfliessen sollen. Ihn ohne jede
    // Anmeldung ins Netz zu haengen, darf kein Versehen sein koennen — bisher
    // genuegte dafuer ein Flag und es blieb bei einer Warnzeile.
    if !loopbackOnly, token == nil {
        fail("""
        '--allow-remote' ohne Token. Der Pruefdienst sieht die Inhalte, die \
        nicht abfliessen sollen — er darf nicht ohne Anmeldung im Netz stehen.
          Token setzen: GUARDRAILS_TOKEN=... guardrails serve --allow-remote
          Es gibt kein TLS: die Strecke zusaetzlich absichern (Reverse Proxy, WireGuard).
        """)
    }
    if let token, token.count < 16 {
        fail("Token ist zu kurz (mindestens 16 Zeichen).")
    }

    let http = GuardrailHTTPService(service: GuardrailService(config: config), token: token)

    let server: HTTPServer
    do {
        server = try http.serve(port: port, loopbackOnly: loopbackOnly)
    } catch {
        fail("\(error)", code: 70)
    }
    // Referenz halten: ohne sie endet der Dienst, sobald der Aufruf zurueckkehrt.
    withExtendedLifetime(server) {}
    let host = loopbackOnly ? "127.0.0.1" : "0.0.0.0"
    print("guardrails hoert auf http://\(host):\(port)")
    print("  POST /inspect · GET /rules · GET /health")
    print(token == nil
          ? "  ohne Token — nur auf Loopback vertretbar"
          : "  Bearer-Token verlangt (ausser GET /health)")
    if !loopbackOnly {
        print("  WARNUNG: nicht auf Loopback gebunden und ohne TLS — nur hinter einem Reverse Proxy betreiben.")
    }
    // Der Server laeuft in eigenen Threads; der Hauptthread haelt den Prozess.
    while true { Thread.sleep(forTimeInterval: 3600) }
}

// MARK: - rules / config / selftest

func runRules() -> Never {
    if has("--json") {
        let data = GuardrailService.encode(GuardrailService.encodeCatalog())
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        for rule in RuleCatalog.all {
            let weight = String(format: "%.2f", rule.weight)
            print("\(rule.id)  \(rule.category.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0))"
                  + "\(rule.severity.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))"
                  + "\(weight)  \(rule.title)")
        }
    }
    exit(0)
}

func runConfig() -> Never {
    do {
        let data = try GuardrailConfig().encoded()
        print(String(data: data, encoding: .utf8) ?? "{}")
        exit(0)
    } catch {
        fail("\(error)", code: 70)
    }
}

/// Selbstpruefung ohne Testrahmen: belegt, dass die Kette im gebauten Binary
/// wirklich greift — nuetzlich nach der Installation und in Umgebungen, in
/// denen keine Swift-Toolchain steht.
func runSelftest() -> Never {
    var failures: [String] = []
    func expect(_ condition: Bool, _ label: String) {
        if !condition { failures.append(label) }
    }

    let service = GuardrailService()
    let source = GroundingSource(id: "e1", sourceType: "note", content: "Der Start ist im Mai.")

    let clean = awaitResult {
        await service.inspect(OutputContext(output: "Der Start ist im Mai.", query: "Wann?",
                                            sources: [source]))
    }
    expect(clean.verdict == .allow, "belegter Ausgang muesste allow sein, ist \(clean.verdict)")

    let pii = awaitResult {
        await service.inspect(OutputContext(output: "IBAN DE89370400440532013000",
                                            query: "?", sources: [source]))
    }
    expect(pii.verdict == .block, "PII muesste blocken")
    expect(!pii.auditLine.contains("DE8937"), "Audit-Zeile darf keinen Klartext tragen")

    let secret = awaitResult {
        await service.inspect(OutputContext(output: "key: sk-abcdefghijklmnopqrstuvwxyz012345",
                                            query: "?", sources: [source]))
    }
    expect(secret.findings.contains { $0.rule == RuleCatalog.secretAPIKey }, "SEC-006 muesste greifen")

    let ungrounded = awaitResult {
        await service.inspect(OutputContext(output: "Behauptung ohne Beleg.", query: "?"))
    }
    expect(ungrounded.verdict == .block, "ohne Beleg muesste blocken")

    if failures.isEmpty {
        print("selftest: alle Pruefungen bestanden (\(RuleCatalog.all.count) Regeln im Katalog)")
        exit(0)
    }
    for failure in failures { print("selftest FEHLER: \(failure)") }
    exit(70)
}

// MARK: - Verteiler

validateFlags(for: command)

switch command {
case "check": runCheck()
case "serve": runServe()
case "rules": runRules()
case "config": runConfig()
case "selftest": runSelftest()
case "--help", "-h", "help":
    print(usage)
    exit(0)
default:
    fail("unbekannter Befehl '\(command)'. `guardrails --help` zeigt die Uebersicht.")
}
