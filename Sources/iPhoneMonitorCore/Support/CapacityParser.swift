import Foundation

public enum CapacityParser {
    public static func bytes(from value: String) -> Int64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let exact = Int64(trimmed) {
            return exact
        }

        let pattern = #"^([0-9]+(?:\.[0-9]+)?)\s*([KMGTPE]?)(?:i?B|B)?$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
            ),
            let numberRange = Range(match.range(at: 1), in: trimmed),
            let number = Double(trimmed[numberRange])
        else { return nil }

        var unit = ""
        if let unitRange = Range(match.range(at: 2), in: trimmed) {
            unit = String(trimmed[unitRange]).uppercased()
        }

        let multiplier: Double
        switch unit {
        case "K": multiplier = 1_024
        case "M": multiplier = 1_024 * 1_024
        case "G": multiplier = 1_024 * 1_024 * 1_024
        case "T": multiplier = 1_024 * 1_024 * 1_024 * 1_024
        case "P": multiplier = pow(1_024, 5)
        case "E": multiplier = pow(1_024, 6)
        default: multiplier = 1
        }

        let result = number * multiplier
        guard result <= Double(Int64.max) else { return nil }
        return Int64(result.rounded())
    }
}
