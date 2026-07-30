# Beitragen zu OutputGuardrails

Issues, Ideen und Pull Requests sind willkommen.

## Die eine Regel: die CLA

OutputGuardrails ist **doppelt lizenziert** — nichtkommerziell frei unter PolyForm
Noncommercial, kommerziell kostenpflichtig (siehe [COMMERCIAL.md](COMMERCIAL.md)).
Damit dieses Modell trägt und die Lizenzierung später überhaupt änderbar bleibt,
muss der Maintainer ausreichende Rechte an **allem** Code halten.

Jeder Beitrag setzt deshalb die Zustimmung zur
**[Contributor License Agreement](CLA.md)** voraus. Kurz: das Urheberrecht an
deinem Beitrag bleibt bei dir, und du erteilst dem Maintainer ein
unbefristetes, unwiderrufliches und übertragbares Recht, ihn zu nutzen und unter
beliebigen Bedingungen weiterzulizenzieren.

Die Zustimmung steht je Pull Request in der Beschreibung:

```
Ich habe CLA.md gelesen und stimme ihr für diesen und alle künftigen Beiträge zu.
```

Ohne diese Zeile kann ein PR nicht gemerged werden — das schützt die
Rechtekette, nicht die Laune des Maintainers.

## Praktisches

```bash
swift build              # Swift 5.7+, macOS 12+
swift test               # alles in-process: kein Netz, keine Zugangsdaten
swift test --filter GuardrailsTests                    # ein Target
swift test --filter PIICheckTests                      # eine Klasse
swift test --filter PIICheckTests/testShortCodesAreNotIBANs   # ein Test
```

Es gibt ein ausführbares Target (`guardrails`, siehe
[docs/STANDALONE.md](docs/STANDALONE.md)) und eine CI
([.github/workflows/ci.yml](.github/workflows/ci.yml)). Die CI baut zusätzlich
gegen den Deployment-Floor **macOS 12** und prüft die Exit-Codes der
Kommandozeile — beides sind zugesagte Schnittstellen, keine Nebensache.

Es gibt keinen Linter. Halte dich an den Ton der umliegenden Dateien.

## Harte Invarianten

PRs, die eine davon verletzen, werden unabhängig vom Nutzen abgelehnt. Die
Begründungen stehen bei den Invarianten selbst in
[CLAUDE.md](CLAUDE.md) — dort ausführlicher als hier.

- **`Foundation` ist die einzige Abhängigkeit.** `GuardrailCore` hat auch keine
  internen. Eine Paket-Abhängigkeit hinzuzufügen bricht den Entwurf, nicht bloß
  eine Richtlinie.
- **Stufen erkennen, die Policy entscheidet.** Ein `GuardrailCheck` liefert
  Befunde mit einer Regel-ID und trifft nie eine Block-Entscheidung. Logik der
  Form „ab Gewicht X blocken" darf nicht in eine Stufe wandern — sonst sind
  Schwellen nicht mehr änderbar, ohne eine Erkennungsregel anzufassen.
- **Regel-IDs sind stabil.** `GRO-001`, `PII-004`, `SEC-001`, `EXF-001`,
  `CMP-001`, `SCH-002`, `CON-001`, `OPS-001`. Suppressions, Audit und Dashboards
  binden daran; eine ID zu ändern ist ein Breaking Change und gehört in den
  [CHANGELOG](CHANGELOG.md). Hinzufügen ist erlaubt, `title`/`message` sind
  Anzeigetext und dürfen umformuliert werden.
  Die **`SEC`- und die `PII`-Reihe sind deckungsgleich mit dem
  [AIGateway](https://github.com/tste04/AIGateway)** — wer eine davon ändert,
  muss die Gegenseite mitändern. `RuleCatalogParityTests` hält das fest.
- **Die 9xx-Reihe ist für Bestätigungen reserviert, wiegt 0 und hebt das Urteil
  nicht an.** Ein „alles in Ordnung" darf weder Risiko erzeugen noch einen
  `flag` auslösen.
- **Fail-closed.** Unbekannte Regel-ID → `violation` mit vollem Gewicht. Kaputte
  Policy-Datei → Abbruch, nicht Voreinstellung. Unübersetzbares Muster aus der
  Policy → Abbruch beim Laden, nicht „kein Treffer".
- **Kein Netz, kein Zustand, keine I/O in den Prüfstufen.** Gleicher Kontext →
  gleiche Befunde. Nur so ist ein Guardrail-Ergebnis auditierbar. Wer ein Modell
  braucht, implementiert `AsyncGuardrailCheck`.
- **Befunde tragen keinen Klartext.** `Finding.evidence` enthält Fundstellen,
  bei PII nur die maskierte Form. `GuardrailReport.auditLine` enthält niemals
  den geprüften Ausgang — dafür gibt es einen Test.
- **Eine übersprungene Prüfung ist kein bestandener Test.** Steht kein Modell
  bereit oder wurde deterministisch schon geblockt, wird `skipped` gemeldet.
- **Kein selbstgebautes TLS, keine eigene Krypto.** Der Dienst bindet auf
  Loopback; jenseits davon verlangt er ein Token, und die Strecke sichert der
  Betreiber (Reverse Proxy, WireGuard).
- **Exit-Codes der CLI sind Schnittstelle:** 0 allow · 1 flag · 2 block ·
  64 Aufruffehler · 70 intern. Skripte binden daran.
- **Swift-Tools 5.7.** Keine Regex-Literale, keine `Regex<Output>`-API —
  `NSRegularExpression` über die `Regex`-Hülle. Deployment-Floor macOS 12.

## Fehlalarme sind teuer

Ein Fehlalarm blockiert eine korrekte Antwort. Muster brauchen deshalb
strukturelle Anker statt „viele Ziffern": Telefon verlangt `+` oder führende
`0`, ein Personenname verlangt Anrede, Feldbezeichner oder einen bekannten
Vornamen. Großschreibung allein trägt im Deutschen nichts — dort steht jedes
Substantiv groß.

Wer eine Erkennung erweitert, bringt in demselben PR **beide** Richtungen mit:
den Fall, der jetzt erkannt wird, und den ähnlich aussehenden, der weiterhin
durchgehen muss.

## Konventionen

- Jede Quelldatei beginnt mit `// Copyright (c) 2026 Tommy Stellmacher` und
  `// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0`.
- **Kommentare deutsch, in Quelldateien umlautfrei transliteriert**
  (`Groessen`, `aendern`); Markdown mit echten Umlauten.
- Kommentare begründen **warum**, nicht was.
- Tests sind XCTest, nach Verhalten gruppiert statt eine Klasse je Typ.
- Nebenläufiger Zustand lebt in Actors; alles öffentlich Sichtbare ist
  `Sendable`.
