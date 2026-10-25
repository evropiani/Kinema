import Foundation
import Observation

enum MessageKind {
    case info, success, warning, error
}

struct UiMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let kind: MessageKind
    let long: Bool
}

/** Toast-style messages from anywhere in the app, shown at the bottom of the screen. */
@MainActor
@Observable
final class UiMessages {
    private(set) var current: UiMessage?

    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func show(_ text: String, _ kind: MessageKind = .info, long: Bool = false) {
        let message = UiMessage(text: text, kind: kind, long: long)
        current = message
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: long ? 8_000_000_000 : 4_000_000_000)
            guard !Task.isCancelled, let self, self.current?.id == message.id else { return }
            self.current = nil
        }
    }

    func error(_ text: String) {
        show(text, .error, long: true)
    }

    func success(_ text: String) {
        show(text, .success)
    }

    func dismiss() {
        hideTask?.cancel()
        current = nil
    }
}
