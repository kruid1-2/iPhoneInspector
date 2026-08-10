import CoreFoundation
import Foundation

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.map(JSONValue.init(any:)))
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init(any:)))
        default:
            self = .string(String(describing: value))
        }
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var doubleValue: Double? {
        guard case .number(let value) = self, value.isFinite else { return nil }
        return value
    }

    public var intValue: Int? {
        guard let value = doubleValue, value.rounded() == value else { return nil }
        return Int(exactly: value)
    }

    public var uint64Value: UInt64? {
        guard let value = doubleValue, value >= 0, value.rounded() == value else { return nil }
        return UInt64(exactly: value)
    }

    public var displayString: String? {
        switch self {
        case .null:
            return nil
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value {
                return String(format: "%.0f", value)
            }
            return String(format: "%.4g", value)
        case .string(let value):
            return value
        case .array, .object:
            return nil
        }
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    func object(_ key: String) -> [String: JSONValue]? { self[key]?.objectValue }
    func array(_ key: String) -> [JSONValue]? { self[key]?.arrayValue }
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    func double(_ key: String) -> Double? { self[key]?.doubleValue }
    func int(_ key: String) -> Int? { self[key]?.intValue }
}
