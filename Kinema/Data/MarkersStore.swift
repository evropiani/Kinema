import Foundation
import Observation

/**
 * The intro and credits marks made by hand in the player, per series, for
 * servers that don't find them. Kept on this phone.
 */
@MainActor
@Observable
final class MarkersStore {
    private static let key = "markers.bySeries"

    private(set) var all: [String: SkipMarkers] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([String: SkipMarkers].self, from: data) {
            all = stored
        }
    }

    func markers(_ seriesId: String) -> SkipMarkers? {
        guard let markers = all[seriesId], !markers.isEmpty else { return nil }
        return markers
    }

    func update(_ seriesId: String, _ change: (inout SkipMarkers) -> Void) {
        var markers = all[seriesId] ?? SkipMarkers()
        change(&markers)
        all[seriesId] = markers
        save()
    }

    func clear(_ seriesId: String) {
        all[seriesId] = nil
        save()
    }

    func clearAll() {
        all = [:]
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
