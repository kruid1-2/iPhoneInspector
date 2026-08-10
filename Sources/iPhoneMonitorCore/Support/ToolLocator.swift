import Foundation

public struct ToolLocator: Sendable {
    private let runner: CommandRunner

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    public func executable(named name: String) async -> String? {
        if name == "devicectl" {
            let result = await runner.run(
                executable: "/usr/bin/xcrun",
                arguments: ["--find", "devicectl"],
                timeout: 4,
                maximumOutputBytes: 64 * 1_024
            )
            if result.succeeded {
                let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }

        var candidates: [String] = [
            "/usr/bin/\(name)",
            "/usr/sbin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent(name).path
            })
        }
        return candidates.first(where: FileManager.default.isExecutableFile)
    }
}
