# Standalone-Betrieb

OutputGuardrails läuft ohne Engram, ohne AIGateway und ohne AIRouter — als
Bibliothek, als Kommandozeilenwerkzeug oder als HTTP-Dienst. Es gibt keine
externe Abhängigkeit außer `Foundation` und keinen Netzzugriff außer dem
Server-Socket, den man selbst startet.

## Die drei Zugänge

```
GuardrailCore    Typen, Verträge, Regelkatalog        keine Abhängigkeiten
    ↑
Guardrails       Prüfstufen + Pipeline                 GuardrailCore
    ↑
GuardrailServer  Policy-Datei, JSON-Bericht, HTTP      + Guardrails
    ↑
guardrails       CLI: check · serve · rules · config · selftest
```

`GuardrailService` ist die einzige Stelle, die zwischen JSON und den Kern-Typen
übersetzt. CLI und HTTP sind beides nur Hüllen darum — deshalb kann keine
Semantik-Drift zwischen „per Kommandozeile geprüft" und „per Dienst geprüft"
entstehen.

## Kommandozeile

```bash
swift build -c release
.build/release/guardrails selftest
```

### Prüfen

```bash
guardrails check --input antwort.txt --source treffer1.md --source treffer2.md \
                 --query "Wann startet das Projekt?" --config policy.json
```

Die Exit-Codes sind die eigentliche Schnittstelle — ein CI-Schritt oder ein
Shell-Skript entscheidet damit ohne JSON zu parsen:

| Code | Bedeutung |
|---|---|
| `0` | `allow` — unauffällig |
| `1` | `flag` — auffällig, Freigabe prüfen |
| `2` | `block` — darf nicht raus |
| `64` | Aufruffehler |
| `70` | interner Fehler (z. B. kaputte Policy-Datei) |

```bash
if ! guardrails check --input antwort.txt --source kontext.md --quiet; then
    echo "Ausgang nicht freigegeben"
fi
```

Mit `--json` kommt der vollständige Bericht, mit `--request datei.json` eine
komplette Anfrage im selben Format wie über HTTP.

### Als Dienst

```bash
guardrails serve --port 8790 --config policy.json
```

| Endpunkt | Zweck |
|---|---|
| `POST /inspect` | Ausgang prüfen, Bericht zurück |
| `GET /rules` | Regelkatalog — Selbstauskunft, Grundlage für Suppressions |
| `GET /health` | läuft der Dienst, mit welcher Politik |

Gebunden wird auf `127.0.0.1`. Das ist kein Vorschlag: der Dienst sieht genau
die Inhalte, die nicht abfließen sollen. `--allow-remote` bindet auf alle
Adressen — nur hinter einem Reverse Proxy, der TLS terminiert. Ein eigener
TLS-Stack wäre das größte Risiko im ganzen Baustein und ist deshalb nicht
vorgesehen.

### Anfrage und Bericht

```bash
curl -s -X POST http://127.0.0.1:8790/inspect -d '{
  "output": "Der Start ist im Mai.",
  "query": "Wann startet das Projekt?",
  "sources": [{"id": "e1", "sourceType": "note", "content": "Der Start ist im Mai."}],
  "schema": {"type": "object", "properties": {"titel": {"type": "string"}}, "required": ["titel"]},
  "knownFacts":    [{"id": "k1", "subject": "Max", "predicate": "arbeitet_bei", "object": "Firma A"}],
  "assertedFacts": [{"id": "a1", "subject": "Max", "predicate": "arbeitet_bei", "object": "Firma B"}]
}'
```

Nur `output` ist Pflicht. `schema` nimmt gewöhnliches JSON Schema entgegen
(Teilmenge: `type`, `properties`, `required`, `additionalProperties`, `items`,
`minItems`, `maxItems`, `enum`); unbekannte Schlüsselwörter werden still
ignoriert, statt die Prüfung zu verhindern.

Der Bericht:

```json
{
  "verdict": "flag",
  "riskScore": 0.2,
  "requiresApproval": true,
  "findings": [
    { "check": "grounding", "rule": "GRO-002", "category": "grounding",
      "severity": "warning", "weight": 0.2,
      "message": "Angabe kommt weder im Kontext noch in der Frage vor …",
      "evidence": "4200" }
  ],
  "suppressed": [],
  "citations": [{ "id": "e1", "sourceType": "note", "origin": "memory", "score": 1 }],
  "skippedChecks": [],
  "audit": "verdict=flag risk=0.20 approval=true citations=1 rules=[GRO-900 GRO-002]"
}
```

`verdict` und `requiresApproval` liest die Risk-based-Approval-Stufe,
`riskScore` und die Regel-IDs der Audit-Baustein. **Kein Feld trägt
Ausgangstext** — bei PII und Zugangsdaten steht dort nur die maskierte Form.

## Die Policy-Datei

Der eigentliche Grund für den Standalone-Betrieb: Schwellen, Suppressions und
die Compliance-Regeln der Organisation stehen in einer Datei, nicht im Code. Wer
nachjustiert, ändert JSON und startet neu.

```bash
guardrails config > policy.json     # Voreinstellung als Ausgangspunkt
```

Jedes Feld ist optional — eine Datei mit `{}` ergibt die Voreinstellung, und wer
nur eine Schwelle ändern will, schreibt nur diese.

`blocksOutput` (Vorgabe `true`) deckelt das Urteil bei `flag`: mit `false` meldet
der Dienst weiter alles, blockt aber nie. Das ist der Beobachtungsbetrieb beim
Einführen — über `blockAt` allein wäre er nicht ausdrückbar, weil `Severity` bei
`violation` endet.

```json
{
  "policy": {
    "blockAt": "violation",
    "flagAt": "warning",
    "approvalThreshold": 0.30,
    "reportSkippedChecks": true,
    "blocksOutput": true,
    "suppressedRules": ["GRO-002"]
  },
  "grounding": { "minScore": 0.001, "requireCitations": true, "checkUnbackedClaims": true },
  "pii": { "categories": ["mail", "phone", "iban", "address", "person"],
           "denylist": ["Projekt Nordlicht"] },
  "exfiltration": { "suspiciousPayloadLength": 60, "allowedHosts": ["wiki.example.com"] },
  "compliance": {
    "forbiddenPatterns": ["garantiert risikofrei"],
    "requiredDisclaimers": [
      { "id": "anlageberatung",
        "triggerPatterns": ["Rendite", "Anlage"],
        "satisfiedByPatterns": ["keine Anlageberatung"],
        "message": "Hinweis 'keine Anlageberatung' fehlt." }
    ],
    "maxOutputCharacters": 20000
  },
  "checks": ["grounding", "pii", "secrets", "exfiltration", "compliance", "schema", "consistency"]
}
```

Eine **kaputte** Policy-Datei führt zum Abbruch, nicht zur Voreinstellung: wer
sie schreibt, will etwas anderes als den Default — sonst hätte er sie nicht
geschrieben.

### Suppressions

`suppressedRules` nimmt Regel-IDs aus `guardrails rules`. Unterdrückte Befunde
gehen nicht ins Urteil und nicht in den Risikowert ein, bleiben aber im Bericht
unter `suppressed` sichtbar — unterdrückt heißt nicht unsichtbar.

### Der Feedback-Loop des Zielbilds

„Eval-Daten tunen Router & Guardrails" heißt hier konkret: die Auswertung der
Berichte (Regel-IDs, Risikowerte, Fehlalarmquoten) führt zu geänderten Werten in
dieser Datei — `approvalThreshold` hoch, wenn zu viel zur Freigabe kommt,
einzelne Regeln unterdrückt, wenn sie im eigenen Haus nur Rauschen erzeugen.
Kein Neubau, kein Deployment einer neuen Binärdatei.

## Mit Modell

Die LLM-Stufe (bestätigte Widersprüche) braucht ein Modell. Das Paket bringt
keines mit:

```swift
let service = GuardrailService(config: config, llm: meinModell)  // GuardrailLLM
```

Im Zielbild wird das typischerweise über den AIRouter bedient. Ohne Modell
meldet die Pipeline die Stufe als `skipped` — nie als bestanden.

## Einbetten als Bibliothek

```swift
.package(url: "https://github.com/tste04/OutputGuardrails.git", branch: "main")
```

```swift
import GuardrailCore
import Guardrails

let report = GuardrailPipeline.standard().inspect(
    OutputContext(output: antwort, query: frage, sources: treffer))

switch report.verdict {
case .allow: liefereAus(antwort, belege: report.citations)
case .flag:  zurFreigabe(antwort, risiko: report.riskScore, befunde: report.findings)
case .block: verweigere(grund: report.findings)
}
auditLog.write(report.auditLine)
```
