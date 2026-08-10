import Foundation

public struct PerformanceHelperLocation: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case bundleResources
        case projectDirectory
        case developmentOverride
    }

    public let executableURL: URL
    public let workingDirectoryURL: URL
    public let source: Source

    public init(executableURL: URL, workingDirectoryURL: URL, source: Source) {
        self.executableURL = executableURL
        self.workingDirectoryURL = workingDirectoryURL
        self.source = source
    }
}

public enum PerformanceHelperLocatorError: LocalizedError, Equatable, Sendable {
    case notFound(searched: [String])
    case notExecutable(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let searched):
            return "未找到 Performance Helper。已检查：\(searched.joined(separator: "、"))"
        case .notExecutable(let path):
            return "Performance Helper 不可执行：\(path)"
        }
    }
}

public protocol PerformanceHelperLocating: Sendable {
    func locate() throws -> PerformanceHelperLocation
}

public struct PerformanceHelperLocator: PerformanceHelperLocating, Sendable {
    public let bundleURL: URL
    public let currentDirectoryURL: URL
    public let developmentOverrideURL: URL?

    public init(
        bundleURL: URL = Bundle.main.bundleURL,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        developmentOverrideURL: URL? = ProcessInfo.processInfo.environment["IPHONE_INSPECTOR_HELPER_PATH"]
            .map { URL(fileURLWithPath: $0) }
    ) {
        self.bundleURL = bundleURL
        self.currentDirectoryURL = currentDirectoryURL
        self.developmentOverrideURL = developmentOverrideURL
    }

    public func locate() throws -> PerformanceHelperLocation {
        var searched: [String] = []

        if let resources = Bundle(url: bundleURL)?.resourceURL {
            for relative in ["PerformanceHelper/run_helper.sh", ".performance-tools/helper/run_helper.sh"] {
                let candidate = resources.appendingPathComponent(relative)
                searched.append(candidate.path)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return try validate(candidate, source: .bundleResources)
                }
            }
        }

        var roots: [URL] = []
        if let root = Self.projectRoot(startingAt: bundleURL) { roots.append(root) }
        if let root = Self.projectRoot(startingAt: currentDirectoryURL), !roots.contains(root) { roots.append(root) }
        for root in roots {
            let candidate = root.appendingPathComponent(".performance-tools/helper/run_helper.sh")
            searched.append(candidate.path)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try validate(candidate, source: .projectDirectory)
            }
        }

        if let developmentOverrideURL {
            let candidate = Self.scriptURL(from: developmentOverrideURL)
            searched.append(candidate.path)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try validate(candidate, source: .developmentOverride)
            }
        }

        throw PerformanceHelperLocatorError.notFound(searched: searched)
    }

    private func validate(_ script: URL, source: PerformanceHelperLocation.Source) throws -> PerformanceHelperLocation {
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw PerformanceHelperLocatorError.notExecutable(script.path)
        }
        return PerformanceHelperLocation(
            executableURL: script,
            workingDirectoryURL: script.deletingLastPathComponent(),
            source: source
        )
    }

    private static func scriptURL(from value: URL) -> URL {
        if value.lastPathComponent == "run_helper.sh" { return value }
        if value.lastPathComponent == "helper" { return value.appendingPathComponent("run_helper.sh") }
        return value.appendingPathComponent(".performance-tools/helper/run_helper.sh")
    }

    private static func projectRoot(startingAt url: URL) -> URL? {
        var candidate = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        for _ in 0..<10 {
            let package = candidate.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: package.path) { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }
        return nil
    }
}
