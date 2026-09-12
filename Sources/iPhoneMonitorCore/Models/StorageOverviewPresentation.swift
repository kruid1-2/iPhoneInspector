import Foundation

public struct StorageOverviewPresentation: Equatable, Sendable {
    public enum PrimaryValue: Equatable, Sendable {
        case userAvailable(Int64)
        case settingsRequired
    }

    public let primaryValue: PrimaryValue
    public let hardFreeBytes: Int64?
    public let usageFraction: Double?

    public static func resolve(_ storage: StorageInformation) -> Self {
        Self(
            primaryValue: storage.availableBytes.value
                .map(PrimaryValue.userAvailable)
                ?? .settingsRequired,
            hardFreeBytes: storage.hardFreeBytes.value,
            usageFraction: storage.usageFraction
        )
    }
}
