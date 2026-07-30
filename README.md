# OutputGuardrails

Die Prüfschicht **hinter** dem Modell, in Swift: was herauskommt, wird geprüft,
bevor es jemand zu sehen bekommt oder eine Aktion auslöst. Deterministisch,
netzfrei, ohne externe Abhängigkeiten außer `Foundation`.

**Lizenz:** PolyForm Noncommercial 1.0.0 — nichtkommerziell frei, kommerziell
kostenpflichtig (siehe [Lizenz](#lizenz) / [COMMERCIAL.md](COMMERCIAL.md)).

## Einordnung

```
… → Agent Loop 🔁 → [ Output Guardrails ] → Risk-based Approval → Action Layer → …
                       ├── PII • Compliance • Security
                       ├── Grounding & Citation Check
                       └── Schema Validation
```

Dieses Repo implementiert diese eine Box. Agent Loop, Approval und Action Layer
sind nicht Teil davon; die Eingangsseite (Input Firewall, Semantic Cache) liegt
im [AIGateway](https://github.com/tste04/AIGateway).

## Was geprüft wird

| Stufe | Zielbild-Punkt | Prüft | Regel-IDs |
|---|---|---|---|
| `GroundingCheck` | Grounding & Citation Check | Steht der Ausgang auf abrufbaren Belegen? Kommen Zahlen und Namen im Kontext vor? | `GRO-001`, `GRO-002` |
| `PIICheck` | PII | Mail, Telefon, IBAN, Anschrift, Name, eigene Denylist | `PII-001`…`PII-005` |
| `SecretsCheck` | Security | Zugangsdaten: privater Schlüssel, AWS, GitHub, Slack, JWT, `sk-` | `SEC-001`…`SEC-006` |
| `ExfiltrationCheck` | Security | Abflusskanäle (Bild-/Link-URL mit Nutzlast), Injection-Echo, zerstörerische Befehle | `EXF-001`…`EXF-004` |
| `ComplianceCheck` | Compliance | Pflichthinweise, untersagte Formulierungen, Längengrenze — vollständig konfiguriert | `CMP-001`…`CMP-003` |
| `SchemaCheck` | Schema Validation | Hat strukturierter Ausgang die zugesagte Form? | `SCH-001`…`SCH-007` |
| `ConsistencyCheck` | (ergänzend) | Widerspricht eine Behauptung einem bekannten Fakt? | `CON-001` |
| `LLMConsistencyCheck` | (ergänzend) | Bestätigt ein Modell den Widerspruch? | `CON-002`…`CON-004` |

Vollständige Gegenüberstellung mit dem Zielbild — auch was bewusst **nicht** hier
liegt: **[docs/ZIELBILD-ABDECKUNG.md](docs/ZIELBILD-ABDECKUNG.md)**.

## Standalone

Als Bibliothek, als Kommandozeilenwerkzeug oder als HTTP-Dienst — ohne Engram,
ohne AIGateway, ohne AIRouter. Ausführlich in
**[docs/STANDALONE.md](docs/STANDALONE.md)**.

```bash
swift build -c release
.build/release/guardrails selftest

# Prüfen. Exit-Code: 0 allow · 1 flag · 2 block
guardrails check --input antwort.txt --source kontext.md --query "Wann?" --config policy.json

# Als Dienst: POST /inspect · GET /rules · GET /health, gebunden auf 127.0.0.1
guardrails serve --port 8790 --config policy.json
```

Schwellen, Suppressions und die Compliance-Regeln der Organisation stehen in
einer Policy-Datei, nicht im Code (`guardrails config > policy.json`) — das ist
die Andockstelle für den Feedback-Loop des Zielbilds.

## Leitsätze

- **Grounded-or-abstain.** Ein Ausgang ohne tragfähige Belege ist kein
  Formfehler, sondern ein Regelbruch. Lieber keine Antwort als eine geratene.
- **Eine übersprungene Prüfung ist kein bestandener Test.** Steht kein Modell
  bereit, meldet die Pipeline `skipped` — nie stillschweigend „unauffällig".
- **Befunde tragen keinen Klartext.** In Logs und Audit landen Codes, Gewichte
  und maskierte Fundstellen (`ma***@example.com`), nie der geprüfte Inhalt.
- **Deterministisch zuerst.** Erst die billigen, reproduzierbaren Stufen; ein
  bereits geblockter Ausgang kostet kein Modell mehr.
- **Stufen erkennen, die Policy entscheidet.** Eine Prüfstufe nennt nur die
  Regel-ID; Schweregrad und Gewicht stehen im Regelkatalog, die Schwellen in der
  Policy. Schwellen ändern heißt nie, eine Erkennungsregel anzufassen.
- **Regel-IDs sind stabil.** `GRO-001`, `PII-003`, `SEC-001`, … Suppressions,
  Audit und Dashboards binden daran; eine ID zu ändern ist ein Breaking Change.
  Die `SEC`-Reihe teilt die IDs bewusst mit der Eingangs-Firewall im AIGateway.
- **Fehlalarme sind teuer.** Ein Fehlalarm blockiert eine korrekte Antwort.
  Deshalb brauchen die Muster strukturelle Anker statt „viele Ziffern":
  Telefon verlangt `+` oder führende `0`; ein Personenname verlangt eine
  Anrede, einen Feldbezeichner oder einen bekannten Vornamen. Großschreibung
  allein trägt im Deutschen nichts — dort steht jedes Substantiv groß, „Kurzer
  Zwischenschritt" ist keine Person. Eigene Namen ergänzt man über
  `PIICheck(additionalFirstNames:)`.

## Schnellstart

```swift
import GuardrailCore
import Guardrails

let context = OutputContext(
    output: antwortDesModells,
    query: "Wann startet das Projekt?",
    sources: [GroundingSource(id: "e1", sourceType: "note", content: "Start ist im Mai.")])

let report = GuardrailPipeline.standard().inspect(context)

switch report.verdict {
case .allow: liefereAus(antwortDesModells, belege: report.citations)
case .flag:  zurFreigabe(antwortDesModells, risiko: report.riskScore, befunde: report.findings)
case .block: verweigere(grund: report.findings)
}

auditLog.write(report.auditLine)   // enthält bewusst keinen Ausgangstext
```

### Strukturierter Ausgang

```swift
let schema = SchemaNode.object(
    properties: ["title": .string(), "priority": .string(enumValues: ["low", "high"])],
    required: ["title", "priority"])

let report = GuardrailPipeline.standard()
    .inspect(OutputContext(output: modellJSON, expectedSchema: schema))
```

`SchemaCheck` schneidet JSON aus Fließtext und ```json-Zäunen heraus — Modelle
rahmen ihre Antwort gern ein, und das ist ein Formatierungs-, kein Strukturfehler.

### Mit Modell (Widerspruchs-Verifikation)

```swift
let pipeline = GuardrailPipeline(
    checks: [GroundingCheck(), PIICheck(), SchemaCheck(), ConsistencyCheck()],
    asyncChecks: [LLMConsistencyCheck()])

let report = await pipeline.inspect(context, llm: meinModell)  // GuardrailLLM
```

Das Paket bringt kein Modell mit und kennt keinen Anbieter. `GuardrailLLM` ist
die Naht — im Zielbild typischerweise über den
[AIRouter](https://github.com/tste04/AIRouter) bedient.

## Politik

`GuardrailPolicy` entscheidet, ab welchem Gewicht ein Befund markiert oder
blockt:

| Politik | blockt ab | markiert ab | wofür |
|---|---|---|---|
| `.standard` | Regelbruch | Warnung | Normalfall mit Mensch im Spiel |
| `.strict` | Warnung | Info | Ausgänge, die ohne Mensch weitergehen (Auto-Execute) |
| `.observeOnly` | Regelbruch | Info | Beobachtungsbetrieb beim Einführen |

Der Bericht trägt zusätzlich `riskScore` (Summe der Regelgewichte, gedeckelt auf
1.0) und `requiresApproval` — das Signal für die Risk-based-Approval-Stufe
dahinter: `allow` → Auto-Execute, `flag` → Human Approval, `block` → gar nicht
erst weiter.

Fertige Sätze: `GuardrailPipeline.standard()` für den vollen Abschluss-Check,
`.lightweight()` für den Check pro Turn im Agent Loop.

## Aufbau

| Target | Inhalt | Abhängigkeiten |
|---|---|---|
| `GuardrailCore` | Typen und Verträge: `Finding`, `Severity`, `Verdict`, `RuleID`, `RuleCatalog`, `OutputContext`, `SchemaNode`, `GuardrailCheck`, `GuardrailLLM` | keine |
| `Guardrails` | Die Prüfstufen und die Pipeline | `GuardrailCore` |
| `GuardrailServer` | Policy-Datei, JSON-Bericht, HTTP-Dienst | + `Guardrails` |
| `guardrails` | Kommandozeile | alle drei |

## Herkunft

Herausgelöst aus [Engram](https://github.com/rdtste/engram) (Welle 4 der
Zielbild-Zerlegung, siehe Master-Repo `Zielbild`):

- `GroundingCheck` ← `EngramCore/Governance/Grounding.swift` — übernommen wurde
  der **Prüf**-Anteil (Abstain-Schwelle, Belegpflicht, Nachprüfung unbelegter
  Angaben). Der **Synthese**-Anteil bleibt in Engram: Antworten erzeugen ist
  Sache des Orchestrators, Antworten prüfen ist Sache der Guardrails.
- `ConsistencyCheck` ← `EngramCore/Engines/ContradictionDetector.swift` — dort
  prüft die Erkennung das Gedächtnis gegen sich selbst, hier den Ausgang gegen
  bekannte Fakten. Dieselbe Regel: gleiches Subjekt + Prädikat, anderes Objekt.
- `SchemaCheck` und `PIICheck` sind Neubau. Die PII-Erkennung ist über
  gemeinsame Konformanz-Vektoren an AIGateway gebunden, damit Eingangs- und
  Ausgangsseite nicht auseinanderdriften.

## Konformanz

`Tests/GuardrailsTests/Vectors/pii-vectors.txt` ist eine Kopie aus dem
Zielbild-Repo (`Zielbild/conformance/pii-vectors.txt`). AIGateway prüft
dieselben Zeilen gegen seine Eingangs-PII. Jeder neu gefundene Fehlalarm oder
übersehene Fall wird dort ergänzt und wandert in beide Repos.

## Testen

```bash
swift test
```

## Lizenz

PolyForm Noncommercial 1.0.0 — siehe [LICENSE.md](LICENSE.md). Kommerzielle
Nutzung erfordert eine kommerzielle Lizenz, siehe [COMMERCIAL.md](COMMERCIAL.md).
