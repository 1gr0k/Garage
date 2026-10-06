import Foundation

func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

func encodedString<T: Encodable>(_ value: T) throws -> String {
    try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
}

func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}
