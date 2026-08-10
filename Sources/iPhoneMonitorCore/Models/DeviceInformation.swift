import Foundation

public enum DeviceConnectionState: String, Codable, CaseIterable, Sendable {
    case connecting
    case readable
    case locked
    case untrusted
    case readLimited
    case disconnected
    case toolUnavailable
    case readFailed

    public var label: String {
        switch self {
        case .connecting: return "正在连接"
        case .readable: return "已连接且可以读取"
        case .locked: return "已连接但未解锁"
        case .untrusted: return "已连接但尚未信任"
        case .readLimited: return "已连接，读取范围有限"
        case .disconnected: return "连接已中断"
        case .toolUnavailable: return "设备工具不可用"
        case .readFailed: return "读取失败"
        }
    }
}

public struct DeviceInformation: Codable, Hashable, Sendable {
    public var name: DataValue<String>
    public var productType: DataValue<String>
    public var marketingName: DataValue<String>
    public var systemVersion: DataValue<String>
    public var buildVersion: DataValue<String>
    public var serialNumber: DataValue<String>
    public var udid: DataValue<String>
    public var ecid: DataValue<String>
    public var architecture: DataValue<String>
    public var paired: DataValue<Bool>
    public var passcodeProtected: DataValue<Bool>
    public var findMyEnabled: DataValue<Bool>

    public init(
        name: DataValue<String> = .missing(.notReturned),
        productType: DataValue<String> = .missing(.notReturned),
        marketingName: DataValue<String> = .missing(.notReturned),
        systemVersion: DataValue<String> = .missing(.notReturned),
        buildVersion: DataValue<String> = .missing(.notReturned),
        serialNumber: DataValue<String> = .missing(.notReturned),
        udid: DataValue<String> = .missing(.notReturned),
        ecid: DataValue<String> = .missing(.notReturned),
        architecture: DataValue<String> = .missing(.notReturned),
        paired: DataValue<Bool> = .missing(.notReturned),
        passcodeProtected: DataValue<Bool> = .missing(.notReturned),
        findMyEnabled: DataValue<Bool> = .missing(.notSupported)
    ) {
        self.name = name
        self.productType = productType
        self.marketingName = marketingName
        self.systemVersion = systemVersion
        self.buildVersion = buildVersion
        self.serialNumber = serialNumber
        self.udid = udid
        self.ecid = ecid
        self.architecture = architecture
        self.paired = paired
        self.passcodeProtected = passcodeProtected
        self.findMyEnabled = findMyEnabled
    }

    public mutating func markValuesStale() {
        name = name.markedStale()
        productType = productType.markedStale()
        marketingName = marketingName.markedStale()
        systemVersion = systemVersion.markedStale()
        buildVersion = buildVersion.markedStale()
        serialNumber = serialNumber.markedStale()
        udid = udid.markedStale()
        ecid = ecid.markedStale()
        architecture = architecture.markedStale()
        paired = paired.markedStale()
        passcodeProtected = passcodeProtected.markedStale()
        findMyEnabled = findMyEnabled.markedStale()
    }
}

public struct ConnectedDevice: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var information: DeviceInformation
    public var connectionType: String
    public var connectionState: DeviceConnectionState
    public var statusDetail: String?
    public var sources: [String]
    public var lastSuccessfulRead: Date?
    public var isDemoData: Bool

    public init(
        id: String,
        information: DeviceInformation,
        connectionType: String,
        connectionState: DeviceConnectionState,
        statusDetail: String? = nil,
        sources: [String],
        lastSuccessfulRead: Date? = nil,
        isDemoData: Bool = false
    ) {
        self.id = id
        self.information = information
        self.connectionType = connectionType
        self.connectionState = connectionState
        self.statusDetail = statusDetail
        self.sources = sources
        self.lastSuccessfulRead = lastSuccessfulRead
        self.isDemoData = isDemoData
    }

    public var displayName: String {
        information.name.value ?? information.marketingName.value ?? "iPhone"
    }

    public var modelName: String {
        information.marketingName.value
            ?? information.productType.value.map(DeviceModelMapper.marketingName)
            ?? "iPhone"
    }

    public mutating func markDisconnected() {
        connectionState = .disconnected
        information.markValuesStale()
    }
}

public struct ProviderDevice: Codable, Hashable, Sendable {
    public var identifier: String
    public var name: String?
    public var productType: String?
    public var marketingName: String?
    public var systemVersion: String?
    public var buildVersion: String?
    public var serialNumber: String?
    public var udid: String?
    public var ecid: String?
    public var architecture: String?
    public var connectionType: String?
    public var paired: Bool?
    public var passcodeProtected: Bool?
    public var findMyEnabled: Bool?
    public var state: DeviceConnectionState
    public var statusDetail: String?
    public var source: String
    public var priority: Int

    public init(
        identifier: String,
        name: String? = nil,
        productType: String? = nil,
        marketingName: String? = nil,
        systemVersion: String? = nil,
        buildVersion: String? = nil,
        serialNumber: String? = nil,
        udid: String? = nil,
        ecid: String? = nil,
        architecture: String? = nil,
        connectionType: String? = nil,
        paired: Bool? = nil,
        passcodeProtected: Bool? = nil,
        findMyEnabled: Bool? = nil,
        state: DeviceConnectionState,
        statusDetail: String? = nil,
        source: String,
        priority: Int
    ) {
        self.identifier = identifier
        self.name = name
        self.productType = productType
        self.marketingName = marketingName
        self.systemVersion = systemVersion
        self.buildVersion = buildVersion
        self.serialNumber = serialNumber
        self.udid = udid
        self.ecid = ecid
        self.architecture = architecture
        self.connectionType = connectionType
        self.paired = paired
        self.passcodeProtected = passcodeProtected
        self.findMyEnabled = findMyEnabled
        self.state = state
        self.statusDetail = statusDetail
        self.source = source
        self.priority = priority
    }
}
