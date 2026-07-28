# CLAUDE.md — Arbeitsregeln für dieses Repo

OutputGuardrails ist der Zielbild-Baustein „Output Guardrails" — die Prüfschicht
hinter dem Modell. Herausgelöst aus Engram (Welle 4), orchestriert vom
Master-Repo `Zielbild`.

## Commit-Identität — verbindlich, ohne Ausnahme

**Jeder Commit wird als `tste04 <tstellmacher@me.com>` autorisiert — Autor *und*
Committer.**

- Niemals `--author` setzen, niemals `GIT_AUTHOR_*`/`GIT_COMMITTER_*` überschreiben.
- Niemals als `Claude <noreply@anthropic.com>` committen.
- **Keine `Co-Authored-By:`-Zeile** in Commit-Messages. Die Standardregel
  „Commits mit Co-Authored-By beenden" gilt hier **nicht**.
- Prüfen vor dem ersten Commit einer Sitzung:
  ```
  git config user.name && git config user.email
  ```
- Verifizieren nach dem Commit:
  ```
  git log -1 --format='A:%an <%ae>  C:%cn <%ce>'
  ```

## Aufbau

```
GuardrailCore    Typen, Verträge, Regelkatalog.   KEINE Abhängigkeiten, auch keine internen.
    ↑
Guardrails       Prüfstufen + Pipeline.
    ↑
GuardrailServer  Policy-Datei, JSON-Bericht, HTTP.
    ↑
GuardrailsCLI    Kommandozeile (Produkt heißt `guardrails`; das Target heißt anders,
                 weil macOS-Dateisysteme case-insensitiv sind).
```

Eine neue Prüfstufe erweitert `Guardrails` und trägt ihre Regeln in
`RuleCatalog` ein — nicht in `GuardrailCore` selbst.

## Der tragende Vertrag: Stufen erkennen, Policy entscheidet

Ein `GuardrailCheck` liefert `Finding`s mit einer **Regel-ID** und trifft nie
eine Block-Entscheidung. Schweregrad und Gewicht stehen im `RuleCatalog`, das
Urteil bildet `GuardrailReport.make(findings:policy:)`. Logik der Form „ab X
blocken" darf nicht in eine Stufe wandern — sonst lassen sich Schwellen nicht
mehr ändern, ohne eine Erkennungsregel anzufassen, und der Feedback-Loop des
Zielbilds bricht.

## Harte Invarianten

- **Keine externen Abhängigkeiten.** Nur `Foundation`. `GuardrailCore` hat auch
  keine internen.
- **Regel-IDs sind stabil.** `GRO-001`, `PII-003`, `SEC-001`, `EXF-001`,
  `CMP-001`, `SCH-002`, `CON-001`, `OPS-001`. Suppressions, Audit und Dashboards
  binden daran; eine ID zu ändern ist ein Breaking Change, Hinzufügen ist
  erlaubt. `title`/`message` sind Anzeigetext und dürfen umformuliert werden.
  Die `SEC`-Reihe ist absichtlich deckungsgleich mit AIGateway.
- **Die 9xx-Reihe ist für Info-Befunde reserviert und wiegt 0.** Ein „alles in
  Ordnung" darf niemals Risiko erzeugen — dafür gibt es einen Test.
- **Fail-closed.** Unbekannte Regel-ID → `violation` mit vollem Gewicht. Kaputte
  Policy-Datei → Abbruch, nicht Voreinstellung.
- **Policy-Felder sind einzeln optional.** Wer nur eine Schwelle ändert, schreibt
  nur diese; nicht genannte Felder behalten die Voreinstellung. Deshalb hat jede
  Konfigurationsstruktur ein eigenes `init(from:)`.
- **Kein TLS im Server, kein Krypto-Eigenbau.** Loopback ist Default, nicht
  Empfehlung: der Dienst sieht genau die Inhalte, die nicht abfließen sollen.
- **Kein Netz, kein Zustand, keine I/O in den Prüfstufen.** Gleicher Kontext →
  gleiche Befunde. Das ist die Voraussetzung dafür, dass ein Guardrail-Ergebnis
  auditierbar ist. Wer ein Modell braucht, implementiert `AsyncGuardrailCheck`.
- **Befunde tragen keinen Klartext.** `Finding.evidence` enthält Fundstellen,
  bei PII nur die maskierte Form. `GuardrailReport.auditLine` darf niemals den
  geprüften Ausgang enthalten — dafür gibt es einen Test.
- **Eine übersprungene Prüfung ist kein bestandener Test.** Steht kein Modell
  bereit oder wurde deterministisch schon geblockt, wird `skipped` gemeldet, nie
  stillschweigend „unauffällig".
- **Swift-Tools 5.7** (Xcode 14, Intel Mac). Keine Regex-Literale, keine
  `Regex<Output>`-API — `NSRegularExpression` über die `Regex`-Hülle.
- **Exit-Codes der CLI sind Schnittstelle:** 0 allow · 1 flag · 2 block · 64
  Aufruffehler · 70 intern. Skripte binden daran.
- **Konformanz-Vektoren nicht einseitig ändern.** `Tests/GuardrailsTests/Vectors/`
  ist eine Kopie aus `Zielbild/conformance/`. Neue Fälle gehören zuerst dorthin,
  damit AIGateway sie erbt.

## Fehlalarme sind teuer

Ein Fehlalarm blockiert eine korrekte Antwort. Deshalb brauchen die Muster
strukturelle Anker statt „viele Ziffern": Telefon verlangt `+` oder führende `0`
(sonst treffen IP-Adressen und Belegnummern), Adresse verlangt Straßen-Suffix
plus Hausnummer, Namensketten verlangen Großbuchstabe + Kleinbuchstaben je Wort
und filtern führende Artikel über `GermanText.sentenceStarters` — sonst meldet
„Das Meeting" eine Person und „Beleg ORD" auch.

## Konventionen

- Jede Datei beginnt mit `// Copyright (c) 2026 Tommy Stellmacher` und
  `// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0`.
- **Kommentare deutsch, in Quelldateien umlautfrei transliteriert**
  (`Groessen`, `aendern`); Markdown unter `docs/` und im README mit echten
  Umlauten.
- Kommentare begründen **warum**, nicht was.
- Tests sind XCTest, nach Verhalten gruppiert, nicht eine Klasse je Typ.

## Nach jeder Änderung an Prüf-Semantik

```
cd ../Zielbild && make parity
```

Und wenn eine Funktion aus Engram hier ankommt: die Inventar-Zeile in
`Zielbild/inventar/inventar.tsv` umziehen (`repo`/`pfad` ändern, `status` auf
`umgezogen`) — Zeilen werden nie gelöscht.
