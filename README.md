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

| Stufe | Prüft | Befund |
|---|---|---|
| `GroundingCheck` | Steht der Ausgang auf abrufbaren Belegen? Kommen Zahlen und Namen im Kontext vor? | `no_grounding` (Regelbruch), `unbacked_claim` (Warnung) |
| `PIICheck` | Personenbezug im Ausgang: Mail, Telefon, IBAN, Adresse, Name, eigene Denylist | `pii_*` (Regelbruch) |
| `SchemaCheck` | Hat strukturierter Ausgang die zugesagte Form? | `invalid_json`, `missing_required`, `type_mismatch`, `enum_mismatch`, … |
| `ConsistencyCheck` | Widerspricht eine Behauptung einem bekannten Fakt? | `contradiction_candidate` (Warnung) |
| `LLMConsistencyCheck` | Bestätigt ein Modell den Widerspruch? | `contradiction_confirmed` (Regelbruch) |

## Leitsätze

- **Grounded-or-abstain.** Ein Ausgang ohne tragfähige Belege ist kein
  Formfehler, sondern ein Regelbruch. Lieber keine Antwort als eine geratene.
- **Eine übersprungene Prüfung ist kein bestandener Test.** Steht kein Modell
  bereit, meldet die Pipeline `skipped` — nie stillschweigend „unauffällig".
- **Befunde tragen keinen Klartext.** In Logs und Audit landen Codes, Gewichte
  und maskierte Fundstellen (`ma***@example.com`), nie der geprüfte Inhalt.
- **Deterministisch zuerst.** Erst die billigen, reproduzierbaren Stufen; ein
  bereits geblockter Ausgang kostet kein Modell mehr.

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
case .flag:  liefereAus(antwortDesModells, belege: report.citations, hinweise: report.findings)
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

Fertige Sätze: `GuardrailPipeline.standard()` für den vollen Abschluss-Check,
`.lightweight()` für den Check pro Turn im Agent Loop.

## Aufbau

| Target | Inhalt | Abhängigkeiten |
|---|---|---|
| `GuardrailCore` | Typen und Verträge: `Finding`, `Severity`, `Verdict`, `OutputContext`, `SchemaNode`, `GuardrailCheck`, `GuardrailLLM` | keine |
| `Guardrails` | Die Prüfstufen und die Pipeline | `GuardrailCore` |

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
