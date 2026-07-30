// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Sprachliche Hilfen, die mehrere Pruefstufen teilen.
///
/// Beide Stufen, die nach Namen suchen (PII im Ausgang, unbelegte Namensketten
/// beim Grounding), stolpern ueber dieselbe Eigenheit des Deutschen: Substantive
/// stehen gross, und am Satzanfang steht ein grossgeschriebener Artikel davor.
/// „Der Projektplan" und „Das Meeting" sehen damit exakt aus wie „Anna Beispiel".
/// Die Liste hier ist der gemeinsame Filter — einmal gepflegt, nicht zweimal.
enum GermanText {

    /// Woerter, die eine grossgeschriebene Kette anfuehren koennen, ohne dass sie
    /// zum Namen gehoeren.
    static let sentenceStarters: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem",
        "einer", "eines", "im", "am", "in", "an", "auf", "bei", "mit", "für", "von",
        "vor", "zum", "zur", "nach", "über", "unter", "und", "aber", "oder", "als",
        "wenn", "weil", "dann", "also", "auch", "nur", "noch", "schon", "sehr",
        "mehr", "hier", "dort", "heute", "morgen", "gestern", "bitte", "danke",
        "wie", "was", "wer", "wo", "warum", "wir", "ich", "sie", "er", "es", "du",
        "ihr", "unser", "unsere", "ihre", "sein", "seine", "kein", "keine", "alle",
        "jede", "jeder", "jedes", "diese", "dieser", "dieses", "doch", "nicht",
        "the", "this", "these", "that", "our", "your", "their", "his", "her",
    ]

    /// Entfernt fuehrende Satzanfangs-Woerter aus einer grossgeschriebenen Kette.
    ///
    /// Liefert `nil`, wenn danach weniger als zwei Woerter uebrig bleiben — eine
    /// Kette aus einem Wort ist im Deutschen kein Namenssignal, sondern ein
    /// Substantiv.
    static func strippedNameChain(_ chain: String) -> String? {
        var words = chain.split(separator: " ").map(String.init)
        while let first = words.first, sentenceStarters.contains(first.lowercased()) {
            words.removeFirst()
        }
        guard words.count >= 2 else { return nil }
        return words.joined(separator: " ")
    }

    // MARK: - Personen-Anker
    //
    // Warum es die Liste unten gibt: „zwei grossgeschriebene Woerter" ist im
    // Deutschen KEIN Namenssignal. Substantive stehen gross, also sieht jede
    // Nominalphrase wie ein Name aus — „Kurzer Zwischenschritt", „Offene
    // Punkte", „Technische Schulden". Der Filter ueber `sentenceStarters` faengt
    // nur den Artikel am Satzanfang; alles andere blieb ein Fehlalarm, und ein
    // Fehlalarm blockiert hier eine korrekte Antwort.
    //
    // Deshalb braucht ein Personen-Fund einen *Anker*: eine Anrede, einen Titel,
    // ein Label („Name:") oder einen bekannten Vornamen. Der Preis ist ehrlich
    // benannt: ein Nachname ohne jeden Anker („Stroustrup erklaerte …") wird
    // nicht erkannt. Betreiber schliessen diese Luecke ueber
    // `PIICheck(additionalFirstNames:)` (Mitarbeiterverzeichnis) oder die
    // Denylist — nicht ueber ein Muster, das jede deutsche Nominalphrase blockt.

    /// Anreden und Titel, nach denen ein Eigenname folgt. Ohne Punkt notiert —
    /// `isAnchorWord` normalisiert „Dr." und „Dr" auf dieselbe Form.
    static let personTitles: Set<String> = [
        "herr", "herrn", "frau", "hr", "fr", "dr", "prof", "dipl", "mr",
        "mrs", "ms", "miss", "sir", "madam",
    ]

    /// Feldbezeichner, hinter denen ein Eigenname steht.
    static let nameLabels: Set<String> = [
        "name", "vorname", "nachname", "kontakt", "absender", "empfaenger",
        "empfänger", "ansprechpartner", "sachbearbeiter", "betreuer", "gez",
        "unterzeichner", "teilnehmer", "verfasser", "autor",
    ]

    /// Ob ein Wort eine Anrede, ein Titel oder ein Feldbezeichner ist.
    /// Nachgestellte Satzzeichen („Dr.", „Name:") gehoeren nicht zum Wort.
    static func isAnchorWord(_ word: String) -> Bool {
        let bare = word.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".:,;"))
        return personTitles.contains(bare) || nameLabels.contains(bare)
    }

    /// Gebraeuchliche Vornamen als Anker. Bewusst eine kuratierte Liste und kein
    /// Muster: ein Vorname ist ein geschlossenes Vokabular, eine Nominalphrase
    /// nicht. Erweiterbar ueber `PIICheck(additionalFirstNames:)`.
    static let commonFirstNames: Set<String> = [
        // deutschsprachig, haeufig
        "alexander", "andrea", "andreas", "anja", "anke", "anna", "annette",
        "anton", "barbara", "bernd", "birgit", "bjoern", "carmen", "christian",
        "christine", "christoph", "claudia", "daniel", "daniela", "david",
        "dennis", "dieter", "dirk", "dominik", "doris", "elena", "elisabeth",
        "elke", "emma", "erika", "ernst", "eva", "felix", "florian", "frank",
        "franziska", "friedrich", "gabriele", "georg", "gerhard", "greta",
        "guenter", "hannah", "hans", "heike", "heinrich", "heinz", "helga",
        "helmut", "henrik", "holger", "ingrid", "jan", "jana", "jens", "jessica",
        "joachim", "johanna", "johannes", "jonas", "josef", "julia", "julian",
        "juergen", "karin", "karl", "katharina", "katrin", "kerstin", "klaus",
        "kurt", "lara", "laura", "lena", "leon", "lisa", "lukas", "manfred",
        "manuela", "marc", "marco", "maria", "marie", "mario", "marion",
        "markus", "martin", "martina", "mathias", "matthias", "max", "maximilian",
        "melanie", "michael", "michaela", "monika", "nadine", "nico", "nicole",
        "niklas", "nina", "norbert", "oliver", "otto", "patrick", "paul",
        "peter", "petra", "philipp", "rainer", "ralf", "rebecca", "reiner",
        "renate", "rene", "richard", "robert", "roland", "rolf", "rudolf",
        "sabine", "sandra", "sarah", "sebastian", "silke", "simon", "simone",
        "sonja", "sophie", "stefan", "stefanie", "steffen", "stephan", "susanne",
        "sven", "tanja", "thomas", "thorsten", "tim", "tobias", "tommy", "torsten",
        "udo", "ulrich", "ulrike", "ursula", "uwe", "vanessa", "verena", "volker",
        "walter", "werner", "wolfgang", "yvonne",
        // international, haeufig in Firmenkontexten
        "adam", "alice", "amir", "ana", "andrew", "angela", "anne", "carlos",
        "charlotte", "chen", "chris", "diego", "elena", "emily", "emma", "erik",
        "george", "grace", "hannah", "helen", "henry", "hugo", "irina", "isabel",
        "james", "jane", "jean", "john", "jose", "juan", "kate", "kevin", "li",
        "linda", "louis", "lucas", "luis", "marco", "maria", "mark", "mary",
        "mehmet", "michel", "mohammed", "nina", "olga", "oscar", "pablo", "paolo",
        "pierre", "rachel", "raj", "robert", "sam", "sofia", "sophia", "steven",
        "susan", "tom", "victor", "wang", "wei", "william", "yuki", "zhang",
    ]

    /// Ergebnis der Personen-Pruefung einer grossgeschriebenen Kette.
    ///
    /// - Parameters:
    ///   - chain: die gefundene Kette, z. B. „Herr Schmidt" oder „Erika Musterfrau".
    ///   - extraFirstNames: zusaetzliche Vornamen des Betreibers (klein geschrieben).
    /// - Returns: der Eigenname ohne Anrede/Titel/Label, oder `nil`, wenn die
    ///   Kette keinen Personen-Anker traegt.
    static func anchoredPersonName(_ chain: String,
                                   extraFirstNames: Set<String> = []) -> String? {
        var words = chain.split(separator: " ").map(String.init)

        // Satzanfaenge zuerst: „Der Anna Beispiel" → „Anna Beispiel".
        while let first = words.first, sentenceStarters.contains(first.lowercased()) {
            words.removeFirst()
        }

        // Anrede, Titel oder Label vorn? Dann ist schon EIN folgendes Wort ein
        // Eigenname — „Herr Schmidt" braucht keinen Vornamen.
        var hadAnchorPrefix = false
        while let first = words.first, isAnchorWord(first) {
            words.removeFirst()
            hadAnchorPrefix = true
        }
        guard let first = words.first else { return nil }
        if hadAnchorPrefix { return words.joined(separator: " ") }

        // Ohne Anrede traegt nur ein bekannter Vorname die Kette — und dann
        // braucht es mindestens Vor- und Nachname.
        let key = first.lowercased()
        guard commonFirstNames.contains(key) || extraFirstNames.contains(key) else { return nil }
        guard words.count >= 2 else { return nil }
        return words.joined(separator: " ")
    }
}
