import Foundation

public struct JSON {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()

    public static let compactEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func encodeCompact<T: Encodable>(_ value: T) throws -> Data {
        try compactEncoder.encode(value)
    }
}

extension JSONDecoder {
    public static var gda: JSONDecoder { JSON.decoder }
}

extension JSONEncoder {
    public static var gda: JSONEncoder { JSON.encoder }
}
