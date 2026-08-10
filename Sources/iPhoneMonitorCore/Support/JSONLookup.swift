import Foundation

enum JSONLookup {
    static func dictionaries(in value: Any, underKey key: String? = nil) -> [[String: Any]] {
        if let dictionary = value as? [String: Any] {
            if let key, let nested = dictionary[key] {
                return dictionaries(in: nested)
            }
            return [dictionary] + dictionary.values.flatMap {
                dictionaries(in: $0, underKey: key)
            }
        }
        if let array = value as? [Any] {
            return array.flatMap { dictionaries(in: $0, underKey: key) }
        }
        return []
    }

    static func firstValue(
        in dictionary: [String: Any],
        keys: [String]
    ) -> Any? {
        let normalized = Set(keys.map(normalize))
        if let direct = dictionary.first(where: { normalized.contains(normalize($0.key)) }) {
            return direct.value
        }
        for value in dictionary.values {
            if let nested = value as? [String: Any],
               let match = firstValue(in: nested, keys: keys) {
                return match
            }
        }
        return nil
    }

    static func string(in dictionary: [String: Any], keys: [String]) -> String? {
        guard let value = firstValue(in: dictionary, keys: keys) else { return nil }
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func bool(in dictionary: [String: Any], keys: [String]) -> Bool? {
        guard let value = firstValue(in: dictionary, keys: keys) else { return nil }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch normalize(text) {
            case "true", "yes", "enabled", "paired", "1": return true
            case "false", "no", "disabled", "unpaired", "0": return false
            default: return nil
            }
        }
        return nil
    }

    static func flattenedText(_ value: Any) -> String {
        if let dictionary = value as? [String: Any] {
            return dictionary.map { "\($0.key) \(flattenedText($0.value))" }.joined(separator: " ")
        }
        if let array = value as? [Any] {
            return array.map(flattenedText).joined(separator: " ")
        }
        return String(describing: value)
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}
