import Foundation
import OSLog

public enum AppLogger {
    public static let subsystem = "com.local.iPhoneInspector"
    public static let command = Logger(subsystem: subsystem, category: "Command")
    public static let device = Logger(subsystem: subsystem, category: "Device")
    public static let diagnostics = Logger(subsystem: subsystem, category: "Diagnostics")
    public static let risk = Logger(subsystem: subsystem, category: "Risk")
    public static let performance = Logger(subsystem: subsystem, category: "Performance")

    public static func maskedIdentifier(_ value: String) -> String {
        guard value.count > 10 else { return "••••" }
        return "\(value.prefix(4))••••\(value.suffix(4))"
    }

    public static func redactedDiagnostic(_ value: String) -> String {
        var result = String(value.prefix(800))
        let patterns = [
            #"[A-Fa-f0-9]{8}-[A-Fa-f0-9-]{16,}"#,
            #"[A-Fa-f0-9]{20,}"#,
            #"\b[A-Z0-9]{12,}\b"#,
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            #"\+?[0-9][0-9 ()-]{7,}[0-9]"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "<redacted>"
            )
        }
        return result
    }
}
