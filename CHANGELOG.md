# Changelog

Alle nennenswerten Änderungen an OutputGuardrails. Format lose nach
[Keep a Changelog](https://keepachangelog.com/de/1.1.0/).

Es gibt bisher **kein Release und keinen Tag** — die Brüche unten sind deshalb
folgenlos für Bestandsnutzer und werden jetzt gemacht, solange sie billig sind.

## Unveröffentlicht

### Breaking

- **PII-Regel-IDs neu vergeben, deckungsgleich mit AIGateway.** Dieselbe ID
  bedeutete auf Eingangs- und Ausgangsseite Verschiedenes — eine Suppression
  oder ein Dashboard auf `PII-003` traf hier IBANs, im Gateway Telefonnummern.

  | Bedeutung | vorher | jetzt |
  |---|---|---|
  | Personenname | `PII-005` | `PII-001` |
  | Mailadresse | `PII-001` | `PII-002` |
  | Telefonnummer | `PII-002` | `PII-003` |
  | IBAN | `PII-003` | `PII-004` |
  | Anschrift | `PII-004` | `PII-005` |
  | Betreiber-Denylist | `PII-005` (als Person) | `PII-007` (neu) |

  `PII-006` („Ort") bleibt unbelegt: das Gateway führt PLZ + Stadt getrennt,
  hier deckt die Anschrift beide Fälle ab. Eine ID mit abweichender Bedeutung
  zu vergeben wäre schlimmer als die Lücke. `RuleCatalogParityTests` hält die
  Zuordnung fest.

  **Migration:** Policy-Dateien mit `suppressedRules` auf `PII-*` und
  Dashboards, die auf diese IDs filtern, müssen nach obiger Tabelle umgestellt
  werden.

- **Denylist-Treffer sind eigene Kategorie `custom`, nicht mehr `person`.**
  „Projekt Nordlicht" ist ein Vorhaben, kein Mensch; die Vermischung machte
  Personen-Befunde in Auswertungen unbrauchbar. Die Kategorie lässt sich nicht
  über `categories` abwählen — wer einen Begriff in die Denylist schreibt, hat
  die Entscheidung schon getroffen.

### Behoben

- **Fail-closed hergestellt, wo die Prüfschicht still nach offen fiel.**
  - Ein **nicht übersetzbares Regex-Muster** aus der Policy-Datei bedeutete
    „kein Treffer": die untersagte Formulierung war nicht untersagt, der
    Pflichthinweis wurde nie ausgelöst — ohne jede Meldung. `GuardrailConfig.load`
    prüft die Compliance-Muster jetzt beim Laden und bricht mit dem Feldnamen ab.
    Muster im Code melden sich über `assertionFailure`, ein Test lässt jede
    Stufe einmal laufen.
  - **JSON-Schema wurde unbegrenzt rekursiv geparst.** Beim HTTP-Dienst kommt
    das Schema aus dem Request: ein paar Kilobyte `{"items":{"items":…}}`
    genügten, um den Stack zu sprengen und den ganzen Prozess mitzunehmen.
    Tiefe jetzt auf 64 begrenzt, darüber wird der Teilbaum `.any`.
  - **Die CLI ignorierte vertippte Flags.** `--configg` oder `--config=x` wurde
    nicht gefunden, `loadConfig()` fiel auf die Voreinstellung zurück — geprüft
    wurde mit der Standardpolitik statt mit der des Betreibers, Exit 0.
    Unbekannte Argumente führen jetzt zu Exit 64 mit der Liste der erlaubten.
    Ebenso `--port`: ein ungültiger Wert fiel still auf 8790 zurück.

- **`redact()` ließ Denylist-Treffer im Klartext stehen.** Gefunden wurde
  case-insensitiv, ersetzt case-sensitiv: bei „projekt nordlicht" im Text und
  „Projekt Nordlicht" in der Denylist meldete die Stufe einen Regelbruch und
  gab den Klartext trotzdem heraus. Jede Fundstelle wird jetzt mit ihrer
  Schreibweise aus dem Text erfasst, auch mehrfach im selben Ausgang.
