// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import GuardrailCore

// MARK: - JSON Schema → SchemaNode
//
// Wer den Dienst benutzt, hat sein Schema meist schon in JSON-Schema-Form (aus
// der Tool-Definition, aus der API-Beschreibung). Diese Uebersetzung nimmt die
// Teilmenge an, die `SchemaNode` abbildet, und ignoriert den Rest still.
//
// Ignorieren statt Fehlschlagen ist Absicht: ein unbekanntes Schluesselwort in
// einem sonst gueltigen Schema darf keine Pruefung verhindern. Was nicht
// abgebildet wird, wird eben nicht geprueft — und die Stufe behauptet nie, mehr
// geprueft zu haben, als sie kann.
//
// Die Schachtelungstiefe ist dagegen begrenzt. Das Schema kommt beim
// HTTP-Dienst aus dem Request, also von aussen: ein paar Kilobyte
// `{"items":{"items":{...}}}` reichten sonst, um ueber die Rekursion den
// Stack zu sprengen und den ganzen Prozess mitzunehmen — nicht nur die eine
// Anfrage. Jenseits der Grenze wird der Teilbaum zu `.any`, das Schema bleibt
// also nutzbar und nur der zu tiefe Ast ungeprueft.

public extension SchemaNode {

    /// Groesste Schachtelungstiefe, die uebersetzt wird. 64 liegt weit ueber
    /// allem, was von Hand oder aus einer Tool-Definition entsteht, und weit
    /// unter dem, was den Stack gefaehrdet.
    static var maxSchemaDepth: Int { 64 }

    /// Liest ein JSON-Schema-Objekt. `nil`, wenn kein `type` erkennbar ist.
    static func fromJSONSchema(_ dict: [String: Any]) -> SchemaNode? {
        fromJSONSchema(dict, depth: 0)
    }

    private static func fromJSONSchema(_ dict: [String: Any], depth: Int) -> SchemaNode? {
        guard depth < maxSchemaDepth else { return .any }
        // `type` darf auch eine Liste sein (`["string","null"]`) — dann zaehlt
        // der erste nicht-null Eintrag.
        let type: String?
        if let single = dict["type"] as? String {
            type = single
        } else if let list = dict["type"] as? [String] {
            type = list.first { $0 != "null" }
        } else if dict["properties"] != nil {
            type = "object"   // haeufige Kurzform ohne explizites `type`
        } else if dict["items"] != nil {
            type = "array"
        } else {
            type = nil
        }

        switch type {
        case "string":
            let values = (dict["enum"] as? [Any])?.compactMap { $0 as? String }
            return .string(enumValues: (values?.isEmpty ?? true) ? nil : values)
        case "number":
            return .number
        case "integer":
            return .integer
        case "boolean":
            return .boolean
        case "object":
            let raw = dict["properties"] as? [String: Any] ?? [:]
            var properties: [String: SchemaNode] = [:]
            for (key, value) in raw {
                guard let sub = value as? [String: Any] else { continue }
                properties[key] = fromJSONSchema(sub, depth: depth + 1) ?? .any
            }
            let required = (dict["required"] as? [Any])?.compactMap { $0 as? String } ?? []
            // `additionalProperties: false` ist die einzige Form, die wir
            // auswerten; ein Schema-Objekt dort bedeutet fuer uns „erlaubt".
            let allowAdditional = (dict["additionalProperties"] as? Bool) ?? true
            return .object(properties: properties, required: required,
                           allowAdditional: allowAdditional)
        case "array":
            let element = (dict["items"] as? [String: Any])
                .flatMap { fromJSONSchema($0, depth: depth + 1) } ?? .any
            return .array(element: element,
                          minItems: (dict["minItems"] as? NSNumber)?.intValue,
                          maxItems: (dict["maxItems"] as? NSNumber)?.intValue)
        default:
            return dict.isEmpty ? nil : .any
        }
    }
}
