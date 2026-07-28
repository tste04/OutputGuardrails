// Copyright (c) 2026 Tommy Stellmacher
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE.md).

import Foundation
import GuardrailCore

// MARK: - Schema Validation
//
// Neubau (in Engram gab es keine Entsprechung). Prueft, ob ein strukturierter
// Ausgang wirklich die zugesagte Form hat — bevor ihn der Action Layer in ein
// Ticket, eine Mail oder einen API-Aufruf giesst.
//
// Ein Modell, das „fast" das richtige JSON liefert, ist der Normalfall: fehlende
// Pflichtfelder, Zahl als String, Objekt statt Array. Genau das faengt diese
// Stufe deterministisch ab.

/// Prueft den Ausgang gegen `OutputContext.expectedSchema`.
public struct SchemaCheck: GuardrailCheck {
    public let name = "schema"

    /// Fuehrenden/abschliessenden Fliesstext und ```json-Zaeune tolerieren und den
    /// JSON-Block herausschneiden. Modelle rahmen ihre Antwort gern ein; das ist
    /// ein Formatierungs-, kein Struktur-Fehler.
    public let extractFromProse: Bool

    public init(extractFromProse: Bool = true) {
        self.extractFromProse = extractFromProse
    }

    public func inspect(_ context: OutputContext) -> [Finding] {
        guard let schema = context.expectedSchema else { return [] }

        guard let json = Self.parse(context.output, extractFromProse: extractFromProse) else {
            return [Finding(check: name, severity: .violation, code: "invalid_json",
                            message: "Ausgang ist kein gueltiges JSON, obwohl ein Schema erwartet wird.",
                            evidence: nil)]
        }
        let problems = Self.validate(json, against: schema, path: "$")
        if problems.isEmpty {
            return [Finding(check: name, severity: .info, code: "schema_ok",
                            message: "Ausgang entspricht dem erwarteten Schema.", evidence: nil)]
        }
        return problems.map {
            Finding(check: name, severity: .violation, code: $0.code,
                    message: $0.message, evidence: $0.path)
        }
    }

    // MARK: - Parsen

    static func parse(_ text: String, extractFromProse: Bool) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return json
        }
        guard extractFromProse else { return nil }

        // Groesster Block zwischen erster oeffnender und letzter schliessender
        // Klammer — deckt ```json-Zaeune und Vor-/Nachtext gleichermassen ab.
        for (open, close) in [("{", "}"), ("[", "]")] {
            guard let start = trimmed.range(of: open),
                  let end = trimmed.range(of: close, options: .backwards),
                  start.lowerBound < end.upperBound else { continue }
            let slice = String(trimmed[start.lowerBound..<end.upperBound])
            if let data = slice.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                return json
            }
        }
        return nil
    }

    // MARK: - Validieren

    struct Problem {
        let code: String
        let message: String
        let path: String
    }

    static func validate(_ value: Any, against schema: SchemaNode, path: String) -> [Problem] {
        switch schema {
        case .any:
            return []

        case .string(let enumValues):
            guard let text = value as? String else { return [typeMismatch(path, schema, value)] }
            if let allowed = enumValues, !allowed.contains(text) {
                return [Problem(code: "enum_mismatch",
                                message: "Wert liegt ausserhalb der erlaubten Auswahl (\(allowed.joined(separator: ", "))).",
                                path: path)]
            }
            return []

        case .boolean:
            // In JSON ist `true` eine NSNumber mit Bool-Typ — nur der zaehlt.
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else {
                return [typeMismatch(path, schema, value)]
            }
            return []

        case .integer:
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  Double(number.doubleValue) == number.doubleValue.rounded() else {
                return [typeMismatch(path, schema, value)]
            }
            return []

        case .number:
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return [typeMismatch(path, schema, value)]
            }
            return []

        case .object(let properties, let required, let allowAdditional):
            guard let dict = value as? [String: Any] else { return [typeMismatch(path, schema, value)] }
            var problems: [Problem] = []
            for key in required.sorted() where dict[key] == nil {
                problems.append(Problem(code: "missing_required",
                                        message: "Pflichtfeld '\(key)' fehlt.",
                                        path: "\(path).\(key)"))
            }
            for (key, sub) in properties.sorted(by: { $0.key < $1.key }) {
                guard let child = dict[key] else { continue }
                problems += validate(child, against: sub, path: "\(path).\(key)")
            }
            if !allowAdditional {
                for key in dict.keys.sorted() where properties[key] == nil {
                    problems.append(Problem(code: "unexpected_property",
                                            message: "Feld '\(key)' ist im Schema nicht vorgesehen.",
                                            path: "\(path).\(key)"))
                }
            }
            return problems

        case .array(let element, let minItems, let maxItems):
            guard let items = value as? [Any] else { return [typeMismatch(path, schema, value)] }
            var problems: [Problem] = []
            if let min = minItems, items.count < min {
                problems.append(Problem(code: "too_few_items",
                                        message: "Mindestens \(min) Element(e) erwartet, \(items.count) geliefert.",
                                        path: path))
            }
            if let max = maxItems, items.count > max {
                problems.append(Problem(code: "too_many_items",
                                        message: "Hoechstens \(max) Element(e) erlaubt, \(items.count) geliefert.",
                                        path: path))
            }
            for (index, item) in items.enumerated() {
                problems += validate(item, against: element, path: "\(path)[\(index)]")
            }
            return problems
        }
    }

    private static func typeMismatch(_ path: String, _ schema: SchemaNode, _ value: Any) -> Problem {
        Problem(code: "type_mismatch",
                message: "Erwartet \(schema.typeName), geliefert \(describe(value)).",
                path: path)
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case is String: return "string"
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number"
        case is [Any]: return "array"
        case is [String: Any]: return "object"
        case is NSNull: return "null"
        default: return "unknown"
        }
    }
}
