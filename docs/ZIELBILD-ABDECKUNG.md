# Zielbild-Abdeckung

Was die Box „Output Guardrails" im KI-Zielbild verlangt und wo es in diesem Repo
steht. Diese Tabelle ist die Antwort auf die Frage „ist der Baustein
vollständig?" — und benennt ehrlich, was bewusst nicht hier liegt.

```
  ▼ Output Guardrails
      ├── PII • Compliance • Security
      ├── Grounding & Citation Check
      └── Schema Validation
```

## Die drei Punkte der Box

| Zielbild-Punkt | Umsetzung | Regel-IDs | Herkunft |
|---|---|---|---|
| **PII** | `PIICheck` — Mail, Telefon, IBAN, Anschrift, Name, Betreiber-Denylist | `PII-001`…`PII-005` | Neubau, an `conformance/pii-vectors.txt` gebunden |
| **Compliance** | `ComplianceCheck` — Pflichthinweise, untersagte Formulierungen, Längengrenze | `CMP-001`…`CMP-003` | Neubau, vollständig richtliniengesteuert |
| **Security** | `SecretsCheck` (Zugangsdaten) + `ExfiltrationCheck` (Abflusskanäle, Injection-Echo, zerstörerische Befehle) | `SEC-001`…`SEC-006`, `EXF-001`…`EXF-004` | Neubau; SEC-IDs deckungsgleich mit AIGateway |
| **Grounding & Citation Check** | `GroundingCheck` — Abstain-Schwelle, Belegpflicht, Nachprüfung unbelegter Angaben | `GRO-001`, `GRO-002`, `GRO-900` | Engram `Governance/Grounding.swift` |
| **Schema Validation** | `SchemaCheck` — JSON-Teilmenge mit Pfadangabe im Befund | `SCH-001`…`SCH-007`, `SCH-900` | Neubau |

Ergänzend, nicht aus der Box, aber aus Engram mitgebracht:

| Ergänzung | Umsetzung | Regel-IDs | Herkunft |
|---|---|---|---|
| Widerspruchsprüfung | `ConsistencyCheck` (deterministisch) + `LLMConsistencyCheck` (bestätigt) | `CON-001`…`CON-004` | Engram `Engines/ContradictionDetector.swift` |

Ein Test hält das fest: `harness`/`GuardrailPipelineTests` prüfen, dass ein
Ausgang mit je einem Verstoß pro Kategorie in **jeder** Kategorie außer
`operational` einen Befund erzeugt.

## Die Nachbarn im Zielbild

Der Baustein steht zwischen Agent Loop und Risk-based Approval. Was er dafür
liefert:

| Nachbar | Was er braucht | Was der Bericht liefert |
|---|---|---|
| **Agent Loop** — „Lightweight Checks pro Turn, voller Check am Ende" | zwei unterschiedlich teure Sätze | `GuardrailPipeline.lightweight()` und `.standard()` |
| **Risk-based Approval** — „Low Risk → Auto-Execute, High Risk → Human Approval" | ein Risikosignal, keine Prosa | `verdict`, `riskScore` (0…1), `requiresApproval` |
| **Action Layer** | Gewissheit über die Struktur | `SchemaCheck` vor der Ausführung |
| **Audit • Metrics • FinOps • Evaluation** | maschinenlesbare, stabile Kennungen ohne Nutzinhalt | `auditLine` und der JSON-Bericht mit `RuleID`s |
| **Feedback Loop** — „Eval-Daten tunen Router & Guardrails" | Schwellen ohne Neubau änderbar | Policy-Datei: `blockAt`, `flagAt`, `approvalThreshold`, `suppressedRules` |

Der Schnitt beim `lightweight()`-Satz folgt dem, was sich nicht zurückholen
lässt: PII, Zugangsdaten, Abfluss-URLs und Schema werden **pro Turn** geprüft —
eine gerenderte Bild-URL ist am Ende des Turns längst abgerufen. Grounding und
Konsistenz gehören ans Ende, wenn die Antwort steht.

## Was bewusst nicht hier liegt

| Nicht hier | Warum | Wo stattdessen |
|---|---|---|
| Antwort-Synthese (`GroundedSynthesizer`) | Antworten erzeugen ist Sache des Orchestrators, prüfen Sache der Guardrails | engram |
| Eingangs-PII mit Round-Trip | Maskierung vor dem Modell, Klarwerte auf dem Rückweg | AIGateway |
| Rate-Limiting pro Client | Mengenbegrenzung am Eingang, nicht hinter dem Modell | AIGateway / Policy Engine |
| Ingest-Gate (Novelty, Themendichte) | entscheidet über Aufnahme ins Gedächtnis, nicht über Ausgänge | engram (`EpistemicGate`) |
| Die Freigabe-Entscheidung selbst | die Guardrails liefern das Signal, nicht die Entscheidung | RiskBasedApproval (Welle 7) |
| Ein Sprachmodell | der Baustein bringt keines mit und kennt keinen Anbieter | über `GuardrailLLM`, im Zielbild via AIRouter |

## Offene Punkte

- **Malware** taucht im Zielbild nur an der Eingangs-Box auf (Input Firewall).
  Für Ausgänge gibt es hier kein Gegenstück — Anhänge erzeugt der Action Layer,
  nicht das Modell. Wenn das später anders ist, gehört die Prüfung hierher.
- **Compliance liefert keine Beispielregeln mit.** Das ist Absicht: eine
  mitgelieferte Liste würde als „das reicht dann wohl" missverstanden. Ohne
  Konfiguration meldet die Stufe nichts.
- Die Konformanz-Vektoren decken bislang nur PII ab. Injection-Echo (`EXF-003`)
  sollte gegen dieselben Vektoren laufen wie die Eingangs-Erkennung im
  AIGateway — offen im Zielbild-Repo als `injection-vectors.txt`-Kopie.
