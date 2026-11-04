import Foundation

/// A small builder for JSON Schema 2020-12. The same schema checks parameters in the registry, makes the options of
/// `llmd` and describes MCP tools, so it only knows what all three need.
public struct JSONSchema: Hashable, Sendable, Codable {
    public var type: String?
    public var description: String?
    public var properties: [String: JSONSchema]?
    /// In the order of the positional parameters of `llmd`.
    public var required: [String]?
    public var enumValues: [String]?
    public var minimum: Double?
    public var maximum: Double?
    public var additionalProperties: Bool?
    private var itemSchema: [JSONSchema]?

    public var items: JSONSchema? { itemSchema?.first }

    enum CodingKeys: String, CodingKey {
        case type, description, properties, required, minimum, maximum, additionalProperties
        case enumValues = "enum"
        case itemSchema = "items"
    }

    public init(type: String? = nil, description: String? = nil) {
        self.type = type
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        properties = try container.decodeIfPresent([String: JSONSchema].self, forKey: .properties)
        required = try container.decodeIfPresent([String].self, forKey: .required)
        enumValues = try container.decodeIfPresent([String].self, forKey: .enumValues)
        minimum = try container.decodeIfPresent(Double.self, forKey: .minimum)
        maximum = try container.decodeIfPresent(Double.self, forKey: .maximum)
        additionalProperties = try container.decodeIfPresent(Bool.self, forKey: .additionalProperties)
        itemSchema = try container.decodeIfPresent(JSONSchema.self, forKey: .itemSchema).map { [$0] }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(properties, forKey: .properties)
        try container.encodeIfPresent(required, forKey: .required)
        try container.encodeIfPresent(enumValues, forKey: .enumValues)
        try container.encodeIfPresent(minimum, forKey: .minimum)
        try container.encodeIfPresent(maximum, forKey: .maximum)
        try container.encodeIfPresent(additionalProperties, forKey: .additionalProperties)
        try container.encodeIfPresent(items, forKey: .itemSchema)
    }

    // MARK: Builders

    public static func string(_ description: String? = nil) -> JSONSchema { JSONSchema(type: "string", description: description) }
    public static func boolean(_ description: String? = nil) -> JSONSchema { JSONSchema(type: "boolean", description: description) }
    public static func any(_ description: String? = nil) -> JSONSchema { JSONSchema(description: description) }

    public static func integer(_ description: String? = nil, minimum: Int? = nil, maximum: Int? = nil) -> JSONSchema {
        var schema = JSONSchema(type: "integer", description: description)
        schema.minimum = minimum.map(Double.init)
        schema.maximum = maximum.map(Double.init)
        return schema
    }

    public static func number(_ description: String? = nil, minimum: Double? = nil, maximum: Double? = nil) -> JSONSchema {
        var schema = JSONSchema(type: "number", description: description)
        schema.minimum = minimum
        schema.maximum = maximum
        return schema
    }

    public static func choice(_ values: [String], _ description: String? = nil) -> JSONSchema {
        var schema = JSONSchema(type: "string", description: description)
        schema.enumValues = values
        return schema
    }

    public static func array(of items: JSONSchema, _ description: String? = nil) -> JSONSchema {
        var schema = JSONSchema(type: "array", description: description)
        schema.itemSchema = [items]
        return schema
    }

    /// An object that takes exactly these properties. Unknown ones are refused: for an agent a typo in a parameter
    /// name must be an error, not a silently ignored instruction.
    public static func object(_ properties: [String: JSONSchema] = [:], required: [String] = [], _ description: String? = nil) -> JSONSchema {
        var schema = JSONSchema(type: "object", description: description)
        schema.properties = properties
        schema.required = required.isEmpty ? nil : required
        schema.additionalProperties = false
        return schema
    }

    /// An object with free keys, for results and nested data.
    public static func freeObject(_ description: String? = nil) -> JSONSchema {
        JSONSchema(type: "object", description: description)
    }

    // MARK: Checking

    /// What is wrong with `value` in German, one line per problem; empty when it is valid.
    public func problems(with value: JSONValue, at path: String = "") -> [String] {
        let place = path.isEmpty ? "Parameter" : "„\(path)“"
        var problems: [String] = []
        switch type {
        case "string":
            guard case .string(let text) = value else { return ["\(place) muss Text sein."] }
            if let enumValues, !enumValues.contains(text) {
                problems.append("\(place) muss eines von \(enumValues.joined(separator: ", ")) sein, nicht „\(text)“.")
            }
        case "boolean":
            guard case .bool = value else { return ["\(place) muss true oder false sein."] }
        case "integer":
            guard let number = value.intValue else { return ["\(place) muss eine ganze Zahl sein."] }
            problems += rangeProblems(Double(number), place: place)
        case "number":
            switch value {
            case .int(let number): problems += rangeProblems(Double(number), place: place)
            case .double(let number): problems += rangeProblems(number, place: place)
            default: return ["\(place) muss eine Zahl sein."]
            }
        case "array":
            guard case .array(let elements) = value else { return ["\(place) muss eine Liste sein."] }
            if let items {
                for (index, element) in elements.enumerated() {
                    problems += items.problems(with: element, at: path.isEmpty ? "[\(index)]" : "\(path)[\(index)]")
                }
            }
        case "object":
            guard case .object(let object) = value else { return ["\(place) muss ein Objekt sein."] }
            for key in required ?? [] where object[key] == nil || object[key] == .null {
                problems.append("Pflichtparameter „\(path.isEmpty ? key : path + "." + key)“ fehlt.")
            }
            for (key, element) in object.sorted(by: { $0.key < $1.key }) {
                let inner = path.isEmpty ? key : path + "." + key
                if let schema = properties?[key] {
                    if element != .null { problems += schema.problems(with: element, at: inner) }
                } else if additionalProperties == false {
                    problems.append("Unbekannter Parameter „\(inner)“.")
                }
            }
        default:
            break
        }
        return problems
    }

    private func rangeProblems(_ number: Double, place: String) -> [String] {
        var problems: [String] = []
        if let minimum, number < minimum { problems.append("\(place) muss mindestens \(Self.format(minimum)) sein.") }
        if let maximum, number > maximum { problems.append("\(place) darf höchstens \(Self.format(maximum)) sein.") }
        return problems
    }

    private static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }

    /// The document for clients that want a complete schema (MCP), with the dialect named.
    public var document: JSONValue {
        var value = (try? JSONValue.encoding(self)) ?? .object([:])
        if case .object(var object) = value {
            object["$schema"] = "https://json-schema.org/draft/2020-12/schema"
            value = .object(object)
        }
        return value
    }
}
