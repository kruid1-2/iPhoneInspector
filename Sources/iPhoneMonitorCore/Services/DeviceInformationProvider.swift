import Foundation

public protocol DeviceInformationProvider: Sendable {
    var name: String { get }
    var priority: Int { get }
    var isHeavyweight: Bool { get }

    func isAvailable() async -> Bool
    func fetchDevices() async throws -> [ProviderDevice]
}

public enum DeviceProviderError: LocalizedError, Sendable {
    case toolUnavailable(String)
    case commandFailed(provider: String, detail: String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .toolUnavailable(let name):
            return "\(name) 不可用"
        case .commandFailed(let provider, let detail):
            return "\(provider) 读取失败：\(detail)"
        case .invalidOutput(let provider):
            return "\(provider) 返回了无法识别的数据"
        }
    }
}

public struct DeviceProviderStatus: Codable, Hashable, Sendable {
    public var name: String
    public var available: Bool
    public var succeeded: Bool
    public var detail: String

    public init(name: String, available: Bool, succeeded: Bool, detail: String) {
        self.name = name
        self.available = available
        self.succeeded = succeeded
        self.detail = detail
    }
}

public struct DeviceDiscoveryResult: Codable, Hashable, Sendable {
    public var devices: [ConnectedDevice]
    public var providers: [DeviceProviderStatus]
    public var refreshedAt: Date

    public init(
        devices: [ConnectedDevice],
        providers: [DeviceProviderStatus],
        refreshedAt: Date = Date()
    ) {
        self.devices = devices
        self.providers = providers
        self.refreshedAt = refreshedAt
    }
}
