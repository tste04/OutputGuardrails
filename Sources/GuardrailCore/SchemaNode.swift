// Copyright (c) 2026 Tommy Stellmacher
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Beschreibung einer erwarteten JSON-Struktur.
///
/// Bewusst eine kleine, geschlossene Teilmenge von JSON Schema: Typ, Pflichtfelder,
/// Objekt-Eigenschaften, Array-Elemente, Aufzaehlungen. Kein `$ref`, kein
/// `allOf`/`anyOf`, kein Remote-Laden — ein Schema ist ein Wert, kein Programm,
/// und darf nie zu einem Netzzugriff fuehren.
public indirect enum SchemaNode: Sendable, Equatable {
    case string(enumValues: [String]? = nil)
    case number
    case integer
    case boolean
    case object(properties: [String: SchemaNode], required: [String] = [],
                allowAdditional: Bool = true)
    case array(element: SchemaNode, minItems: Int? = nil, maxItems: Int? = nil)
    /// Beliebiger Wert — prueft nur, dass das Feld vorhanden ist.
    case any

    /// Menschlich lesbarer Typname fuer Fehlermeldungen.
    public var typeName: String {
        switch self {
        case .string: return "string"
        case .number: return "number"
        case .integer: return "integer"
        case .boolean: return "boolean"
        case .object: return "object"
        case .array: return "array"
        case .any: return "any"
        }
    }
}
