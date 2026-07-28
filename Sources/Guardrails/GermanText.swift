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
}
