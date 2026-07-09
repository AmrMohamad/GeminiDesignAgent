import Foundation

enum DecodingDefaults {
    static let generatedConfidence = 0.7
    static let storedConfidence = 1.0
}

extension KeyedDecodingContainer {
    func decodeGeneratedConfidence(forKey key: Key) throws -> Double {
        try decodeIfPresent(Double.self, forKey: key) ?? DecodingDefaults.generatedConfidence
    }

    func decodeStoredConfidence(forKey key: Key) throws -> Double {
        try decodeIfPresent(Double.self, forKey: key) ?? DecodingDefaults.storedConfidence
    }
}
