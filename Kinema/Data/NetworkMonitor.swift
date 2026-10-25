import Foundation
import Network
import Observation

/** Whether we are online, and whether the connection costs money (mobile data, hotspot). */
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var online = true
    private(set) var metered = false

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var listeners: [() -> Void] = []

    var isOnline: Bool { online }
    var isMetered: Bool { metered }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let metered = path.isExpensive || path.isConstrained
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = self.online != online || self.metered != metered
                self.online = online
                self.metered = metered
                if changed { self.listeners.forEach { $0() } }
            }
        }
        monitor.start(queue: DispatchQueue(label: "kinema.network"))
    }

    func observe(_ listener: @escaping () -> Void) {
        listeners.append(listener)
    }
}
