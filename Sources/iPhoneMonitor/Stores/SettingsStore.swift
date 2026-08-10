import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let autoDetection = "autoDetection"
        static let detectionInterval = "detectionInterval"
        static let showFullIdentifiers = "showFullIdentifiers"
        static let retentionDays = "retentionDays"
        static let keepImportedCopies = "keepImportedCopies"
        static let demoMode = "demoMode"
    }

    private let defaults: UserDefaults

    @Published var autoDetection: Bool {
        didSet { defaults.set(autoDetection, forKey: Key.autoDetection) }
    }
    @Published var detectionInterval: Double {
        didSet {
            let normalized = min(max(detectionInterval, 3), 60)
            if normalized != detectionInterval {
                detectionInterval = normalized
            } else {
                defaults.set(normalized, forKey: Key.detectionInterval)
            }
        }
    }
    @Published var showFullIdentifiers: Bool {
        didSet { defaults.set(showFullIdentifiers, forKey: Key.showFullIdentifiers) }
    }
    @Published var retentionDays: Int {
        didSet {
            let normalized = min(max(retentionDays, 1), 365)
            if normalized != retentionDays {
                retentionDays = normalized
            } else {
                defaults.set(normalized, forKey: Key.retentionDays)
            }
        }
    }
    @Published var keepImportedCopies: Bool {
        didSet { defaults.set(keepImportedCopies, forKey: Key.keepImportedCopies) }
    }
    @Published var demoMode: Bool {
        didSet { defaults.set(demoMode, forKey: Key.demoMode) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.autoDetection: true,
            Key.detectionInterval: 8.0,
            Key.showFullIdentifiers: false,
            Key.retentionDays: 30,
            Key.keepImportedCopies: false,
            Key.demoMode: false
        ])
        autoDetection = defaults.bool(forKey: Key.autoDetection)
        detectionInterval = defaults.double(forKey: Key.detectionInterval)
        showFullIdentifiers = defaults.bool(forKey: Key.showFullIdentifiers)
        retentionDays = defaults.integer(forKey: Key.retentionDays)
        keepImportedCopies = defaults.bool(forKey: Key.keepImportedCopies)
        demoMode = defaults.bool(forKey: Key.demoMode)
    }
}
