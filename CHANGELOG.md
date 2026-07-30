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

### Hinzugefügt

- **Bearer-Token für den HTTP-Dienst** (`--token`, besser `GUARDRAILS_TOKEN` —
  Argumente stehen in der Prozessliste). Ohne konfiguriertes Token bleibt alles
  wie bisher offen; das ist für Loopback vertretbar. **`--allow-remote` verlangt
  jetzt ein Token** und bricht sonst ab: der Prüfdienst sieht genau die Inhalte,
  die nicht abfließen sollen, und das ohne Anmeldung ins Netz zu hängen darf
  kein Versehen sein können. `GET /health` bleibt ohne Token erreichbar,
  antwortet dann aber nur mit `{"status":"ok"}` — welche Regeln unterdrückt
  sind, ist eine Landkarte der blinden Flecken.
- **`HTTPServer.boundPort`** — macht die Socket-Schicht überhaupt erst testbar
  (Port 0 = freien Port vom System).

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

- **Bestätigungen der 9xx-Reihe hoben das Urteil an.** Die Invariante lautet
  „ein ‚alles in Ordnung' darf niemals Risiko erzeugen" — sie galt für den
  Risikowert, nicht für das Verdikt. Unter `.strict` (flagAt: `info`) machte
  deshalb ausgerechnet der **saubere** Ausgang einen `flag` auf: die Politik
  für Ausgänge, die ohne Menschen weitergehen sollen, verlangte für jeden
  einwandfreien Ausgang eine Freigabe. `OPS-001` („Prüfstufe nicht ausgeführt")
  zählt bewusst nicht dazu und flaggt weiterhin.
- **Eine unterdrückte Regel schaltete die LLM-Stufe ab.** Der Kurzschluss
  „bereits blockiert, Modell sparen" rechnete auf den rohen statt den wirksamen
  Befunden. Eine Suppression genügte, um die Widerspruchsprüfung dauerhaft
  stillzulegen — der Bericht meldete `allow`, weil derselbe Befund später wieder
  herausfiel.

- **Der HTTP-Dienst war gegen langsame und mehrdeutige Anfragen offen.**
  - **Slow-Drip:** das Timeout galt pro `read()`, nicht pro Anfrage — ein Client,
    der alle paar Sekunden ein Byte schickt, band seinen Thread beliebig lange;
    64 solcher Clients legten den Dienst still. Jetzt zusätzlich eine absolute
    Frist für die ganze Anfrage, plus Sende-Timeout gegen langsame Leser.
  - **Request Smuggling:** `Transfer-Encoding` wurde ignoriert und stattdessen
    `Content-Length` geglaubt; ein zweites `Content-Length` überschrieb das
    erste. Beides ergibt jetzt 400.
  - **Fail-open bei der Länge:** ein fehlendes oder unlesbares `Content-Length`
    wurde zu 0 — der Prüfdienst urteilte dann über einen leeren Ausgang, als
    wäre er geprüft worden. Jetzt 400. Angekündigte Überlänge ergibt 413 statt
    400 (`reason(413)` war unerreichbarer Code), und der Rumpf wird auf die
    angekündigte Länge gekürzt, statt bis zu 4 KB Überhang mitzunehmen.

- **Abflusskanäle, die nie geprüft wurden.** `bareURLPattern` war deklariert
  und wurde nirgends benutzt — eine nackte Abfluss-URL lief ungeprüft durch,
  obwohl sie der einfachste Kanal überhaupt ist. HTML-`<img>` fehlte ganz,
  dabei lädt es beim Rendern von selbst. Beide werden jetzt erfasst; mehrfach
  gefundene Adressen ergeben einen Befund statt drei, damit der Risikowert
  nicht künstlich steigt.
- **Zerstörerische Befehle in ihrer gebräuchlichsten Schreibweise.**
  `rm -rf /*` scheiterte an der Leerzeichen-Forderung hinter dem Schrägstrich,
  `git push -f` war gar nicht abgedeckt (nur `--force`). Dazu `dd` auf ein
  Blockgerät.

- **`redact()` ließ Denylist-Treffer im Klartext stehen.** Gefunden wurde
  case-insensitiv, ersetzt case-sensitiv: bei „projekt nordlicht" im Text und
  „Projekt Nordlicht" in der Denylist meldete die Stufe einen Regelbruch und
  gab den Klartext trotzdem heraus. Jede Fundstelle wird jetzt mit ihrer
  Schreibweise aus dem Text erfasst, auch mehrfach im selben Ausgang.
