import Foundation
import Observation

/**
 * Every preference, as one JSON document in UserDefaults. Reads are
 * synchronous (the player needs them without suspending), and every change
 * is published through [settings] and to registered listeners.
 */
@MainActor
@Observable
final class SettingsStore {
    private static let key = "settings.json"

    private(set) var settings: Settings

    @ObservationIgnored private var listeners: [(Settings, Settings) -> Void] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
        } else {
            settings = Settings()
        }
    }

    var current: Settings { settings }

    /** Called with (old, new) after every change. */
    func observe(_ listener: @escaping (Settings, Settings) -> Void) {
        listeners.append(listener)
    }

    func update(_ change: (inout Settings) -> Void) {
        let old = settings
        var next = old
        change(&next)
        if next == old { return }
        settings = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        for listener in listeners { listener(old, next) }
    }

    func replace(_ settings: Settings) {
        update { $0 = settings }
    }

    func reset() {
        let seen = settings.hasSeenWelcome
        update { s in
            s = Settings()
            s.hasSeenWelcome = seen
        }
    }
}
