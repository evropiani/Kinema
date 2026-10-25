import SwiftUI

struct SheetScaffold<Content: View, Buttons: View>: View {
    @Environment(\.kinema) private var theme
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(KFont.headlineSmall.weight(.semibold))
                .foregroundStyle(theme.colors.ink)
                .lineLimit(2)
            content
            HStack(spacing: 16) {
                Spacer()
                buttons
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.elevated.ignoresSafeArea())
        .tint(theme.colors.accent)
    }
}

struct TextButton: View {
    @Environment(\.kinema) private var theme
    let text: String
    var color: Color?
    var enabled = true
    let action: () -> Void

    init(_ text: String, color: Color? = nil, enabled: Bool = true, action: @escaping () -> Void) {
        self.text = text
        self.color = color
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(KFont.labelLarge)
                .foregroundStyle((color ?? theme.colors.accent).opacity(enabled ? 1 : 0.4))
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }
}

struct ToastView: View {
    @Environment(\.kinema) private var theme
    let message: UiMessage

    var body: some View {
        let c = theme.colors
        let color: Color = {
            switch message.kind {
            case .error: return c.danger
            case .warning: return c.warning
            case .success, .info: return c.ink
            }
        }()
        Text(message.text)
            .font(KFont.bodyMedium)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.elevated))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .padding(.horizontal, 12)
            .onTapGesture { AppGraph.shared.messages.dismiss() }
    }
}
