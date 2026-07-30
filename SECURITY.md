# Sicherheit

## Schwachstelle melden

Bitte **kein öffentliches Issue** für Sicherheitslücken. Melde sie an
**tstellmacher@me.com** mit „OutputGuardrails Security" im Betreff.

Nimm mit auf, was du hast: betroffene Version oder Commit, Auswirkung, und wenn
möglich die kleinste Eingabe, die das Verhalten zeigt. Eine Bestätigung kommt
innerhalb von 72 Stunden.

## Was dieser Baustein ist — und was nicht

OutputGuardrails prüft Modell-Ausgänge, bevor sie jemand zu sehen bekommt oder
eine Aktion auslösen. Der Dienst sieht damit **genau die Inhalte, die nicht
abfließen sollen**. Das prägt die Sicherheitslage:

- **Erkennung ist heuristisch, nicht vollständig.** PII-, Secret- und
  Abfluss-Muster sind kuratiert und bewusst eng gefasst, weil ein Fehlalarm eine
  korrekte Antwort blockiert. Es gibt keine Zusicherung, dass jeder
  Personenbezug oder jeder Abflusskanal erkannt wird. Der Baustein ergänzt
  Datenminimierung, er ersetzt sie nicht.
- **Ein Guardrail ist kein Ersatz für Governance.** Er ist die letzte Stufe vor
  der Ausgabe, nicht die einzige.

## Betrieb

- **Loopback ist die Voreinstellung und keine Empfehlung, sondern die Grenze.**
  `guardrails serve` bindet auf `127.0.0.1`.
- **`--allow-remote` verlangt ein Token.** Ohne `--token` bzw.
  `GUARDRAILS_TOKEN` bricht der Start ab. Setze das Token über die Umgebung —
  Kommandozeilen-Argumente stehen in der Prozessliste und sind für jeden Nutzer
  der Maschine lesbar.
- **Es gibt kein TLS.** Das Paket hat außer `Foundation` keine Abhängigkeiten,
  und selbstgebaute Krypto wäre schlimmer als keine. Wer den Dienst über die
  Maschine hinaus erreichbar macht, sichert die Strecke selbst ab — Reverse
  Proxy mit TLS, WireGuard, oder ein Netz, dem man das zutraut.
- **`GET /health` bleibt ohne Token erreichbar**, antwortet dann aber nur mit
  `{"status":"ok"}`. Mit Token nennt es die Politik einschließlich der
  unterdrückten Regeln — das ist eine Landkarte der blinden Flecken und gehört
  nicht an jeden, der den Port erreicht.
- **Berichte tragen keinen Klartext.** `Finding.evidence` enthält Fundstellen in
  maskierter Form, `auditLine` niemals den geprüften Ausgang. Wenn dir ein Pfad
  auffällt, auf dem doch Klartext austritt, ist das eine meldenswerte Lücke.

## Grenzen, die bewusst so sind

Diese Punkte sind bekannt und keine Meldung wert — sie stehen hier, damit du
nicht umsonst suchst:

- Kein TLS, keine Nutzerverwaltung, keine Rollen. Ein gemeinsames Token, mehr
  nicht.
- Kein Rate-Limit im Dienst selbst. Verbindungsdeckel und Zeitgrenzen gibt es;
  eine Anfragen-pro-Sekunde-Grenze gehört vor den Dienst.
- Die Erkennungsmuster sind öffentlich. Wer sie liest, kann Formulierungen
  wählen, die sie nicht treffen — das ist bei jeder musterbasierten Erkennung
  so und der Grund, warum sie nur eine Stufe von mehreren ist.

## Unterstützte Versionen

Das Projekt hat noch kein Release. Sicherheitskorrekturen landen auf `main`.
