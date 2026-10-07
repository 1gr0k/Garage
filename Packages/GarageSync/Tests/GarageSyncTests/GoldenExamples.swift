import Foundation

/// Semantic JSON value: equality ignores formatting and key order.
enum JSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    init(data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

/// Reads the golden examples (```json golden=<name> blocks) from `docs/api.md`.
enum GoldenExamples {
    static let documentURL: URL = {
        // …/Packages/GarageSync/Tests/GarageSyncTests/GoldenExamples.swift → repository root
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("docs/api.md")
    }()

    static func load() throws -> [String: Data] {
        let text = try String(contentsOf: documentURL, encoding: .utf8)
        var examples: [String: Data] = [:]
        var name: String?
        var body: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let current = name {
                if line.hasPrefix("```") {
                    guard examples[current] == nil else { throw GoldenError.duplicate(current) }
                    examples[current] = Data(body.joined(separator: "\n").utf8)
                    name = nil
                    body = []
                } else {
                    body.append(line)
                }
            } else if line.hasPrefix("```json golden=") {
                name = String(line.dropFirst("```json golden=".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if let name { throw GoldenError.unterminated(name) }
        return examples
    }

    static func data(_ name: String) throws -> Data {
        guard let data = try load()[name] else {
            throw GoldenError.missing(name)
        }
        return data
    }
}

enum GoldenError: Error {
    case missing(String)
    case duplicate(String)
    case unterminated(String)
}
