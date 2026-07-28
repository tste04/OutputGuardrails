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

## Harte Invarianten

- **Keine externen Abhängigkeiten.** Nur `Foundation`. `GuardrailCore` hat auch
  keine internen.
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

## Nach jeder Änderung an Prüf-Semantik

```
cd ../Zielbild && make parity
```

Und wenn eine Funktion aus Engram hier ankommt: die Inventar-Zeile in
`Zielbild/inventar/inventar.tsv` umziehen (`repo`/`pfad` ändern, `status` auf
`umgezogen`) — Zeilen werden nie gelöscht.
